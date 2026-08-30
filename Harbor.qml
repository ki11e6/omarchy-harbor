import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "answers.js" as Answers

Item {
  id: root

  property var shell: null
  property var manifest: null

  property bool opened: false
  property string filterText: ""
  property int selectedIndex: 0
  property bool cursorActive: false
  property var ports: []
  // "unknown" until a probe completes; nothing may claim a port is free
  // outside "ok" — a failed probe must never render as an empty (all-free)
  // machine.
  property string probeState: "unknown"   // "unknown" | "ok" | "failed"
  // Below this, a port can be free and still refuse an unprivileged bind.
  // Supplied by the probe (it reads the sysctl); 1024 is the fallback.
  property int unprivilegedPortStart: 1024
  // Set by ctrl+k; a second ctrl+k on the same still-alive process escalates
  // to SIGKILL. Keyed on pid AND starttime so a recycled PID cannot inherit
  // the armed escalation.
  property string lastKilledKey: ""
  // Kill outcome: "" | "terminating" | "freed" | "survived".
  property string killState: ""
  property string killPort: ""
  property int verifyAttempt: 0
  // Why the last ctrl+k did nothing. A silent no-op is the worst outcome in
  // a tool used under time pressure.
  property string refusalText: ""

  // The filter doubles as a question when it is exactly a port number.
  readonly property int queriedPort: Answers.queriedPortOf(root.filterText)

  // The answer line. Kill outcomes take precedence; otherwise empty outside
  // probeState "ok" — never claim a port is free on a failed or pending
  // probe; a suggestion is a free-claim too. ("is now free" rests on the
  // port-scoped ss check, not on the probe, so it carries its own evidence.)
  readonly property string bannerText: {
    if (root.refusalText) return root.refusalText
    if (root.killState === "freed") return root.killPort + " is now free"
    if (root.killState === "survived") return "still listening — ctrl+k again to force"
    if (root.probeState !== "ok" || root.queriedPort === 0) return ""
    if (!Answers.portInUse(root.ports, root.queriedPort)) {
      var caveat = root.queriedPort < root.unprivilegedPortStart
        ? " · needs root or CAP_NET_BIND_SERVICE" : ""
      return root.queriedPort + " is free" + caveat
    }
    var next = Answers.nextFreePort(root.ports, root.queriedPort, root.unprivilegedPortStart)
    return next > 0 ? next + " is free" : ""
  }

  // Shares the [menu] surface tokens — themes that style the menu also style Harbor.
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding
  property int headerHeight: Math.max(Style.space(34), Style.font.title + Style.spacing.controlPaddingY * 2)
  property int contentSpacing: Style.spacing.md
  // Two text lines per row: identity above, context below.
  property int rowHeight: Math.max(Style.space(52), Style.font.body + Style.font.caption + Style.spacing.md * 2 + Style.space(2))
  property int cardWidth: Math.min(Style.space(520), panel.width - Style.gapsOut * 2)
  property int cardHeight: Math.min(Style.space(420), panel.height - Style.gapsOut * 2)

  function sourceDir() {
    return (root.manifest && root.manifest.__sourceDir) || ""
  }

  function open(payloadJson) {
    root.opened = true
    root.filterText = ""
    root.selectedIndex = 0
    root.cursorActive = true
    root.lastKilledKey = ""
    root.clearKillFeedback()
    root.disarmPointer()
    root.refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function disarmPointer() {
    pointerGate.reset()
  }

  function selectFromPointer(index, item, mouse) {
    if (!pointerGate.moved(item, mouse)) return
    root.cursorActive = true
    root.selectedIndex = index
  }

  function close() {
    root.opened = false
    root.clearKillFeedback()
  }

  function dismiss() {
    root.opened = false
    root.clearKillFeedback()
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "io.github.ki11e6.harbor")
  }

  // A stale "3000 is now free" banner must not outlive its query.
  function clearKillFeedback() {
    root.killState = ""
    root.killPort = ""
    root.refusalText = ""
    root.verifyAttempt = 0
    verifyTimer.stop()
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  function refresh() {
    root.probeState = "unknown"
    listProc.running = false
    listProc.running = true
    probeWatchdog.restart()
  }

  function loadPorts(raw) {
    probeWatchdog.stop()
    var parsed = null
    try { parsed = JSON.parse(raw || "") } catch (e) { parsed = null }
    var ok = parsed !== null && parsed.ok === true && Array.isArray(parsed.ports)
    root.probeState = ok ? "ok" : "failed"
    root.ports = ok ? parsed.ports : []
    var floor = ok ? parseInt(parsed.unprivilegedPortStart, 10) : NaN
    root.unprivilegedPortStart = isFinite(floor) && floor >= 0 ? floor : 1024
    root.disarmPointer()
    if (root.lastKilledKey) {
      var alive = false
      for (var i = 0; i < root.ports.length; i++)
        if (root.ports[i].pid + ":" + root.ports[i].starttime === root.lastKilledKey) alive = true
      if (!alive) root.lastKilledKey = ""
    }
    root.rebuildDisplay()
  }

  function matches(row, needle) {
    if (!needle) return true
    // Full cwd stays in the haystack even though the row shows only its
    // basename — directory-name filtering must keep working. uid/starttime
    // are deliberately excluded: all-digit strings that would make numeric
    // port queries match every row the user owns.
    var hay = (row.port + " " + row.process + " " + row.pid + " " + row.cwd + " " + row.scope + " " + row.address).toLowerCase()
    return hay.indexOf(needle) !== -1
  }

  function rebuildDisplay() {
    var needle = root.filterText.toLowerCase()
    displayModel.clear()
    for (var i = 0; i < root.ports.length; i++) {
      var row = root.ports[i]
      if (root.matches(row, needle))
        displayModel.append({
          port: String(row.port || ""), process: String(row.process || ""),
          pid: String(row.pid || ""), cwd: String(row.cwd || ""),
          scope: String(row.scope || ""), address: String(row.address || ""),
          uid: String(row.uid || ""), starttime: String(row.starttime || "")
        })
    }
    if (displayModel.count === 0) root.selectedIndex = 0
    else if (root.selectedIndex >= displayModel.count) root.selectedIndex = displayModel.count - 1
    else if (root.selectedIndex < 0) root.selectedIndex = 0
    Qt.callLater(function() {
      if (displayModel.count > 0) resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
    })
  }

  function select(delta) {
    if (displayModel.count === 0) return
    root.disarmPointer()
    if (!root.cursorActive) {
      root.cursorActive = true
      root.selectedIndex = delta < 0 ? displayModel.count - 1 : 0
    } else {
      root.selectedIndex = (root.selectedIndex + delta + displayModel.count) % displayModel.count
    }
    resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
  }

  function setFilter(nextFilter) {
    root.filterText = nextFilter
    root.selectedIndex = 0
    root.clearKillFeedback()
    root.disarmPointer()
    root.rebuildDisplay()
  }

  function openSelected() {
    if (root.selectedIndex < 0 || root.selectedIndex >= displayModel.count) return
    var row = displayModel.get(root.selectedIndex)
    root.dismiss()
    Quickshell.execDetached(["xdg-open", "http://localhost:" + row.port])
  }

  function copySelected() {
    if (root.selectedIndex < 0 || root.selectedIndex >= displayModel.count) return
    var row = displayModel.get(root.selectedIndex)
    root.dismiss()
    Quickshell.execDetached(["wl-copy", "localhost:" + row.port])
  }

  function killSelected() {
    if (root.selectedIndex < 0 || root.selectedIndex >= displayModel.count) return
    var row = displayModel.get(root.selectedIndex)
    root.refusalText = ""
    // Killing docker-proxy is worse than refusing: dockerd either restarts
    // it or the container keeps the port. Heuristic — misses rootless
    // Docker/Podman — so nothing else branches on it.
    if (row.process === "docker-proxy") {
      root.refusalText = "container port — docker stop frees this"
      return
    }
    if (!/^[0-9]+$/.test(row.pid)) {
      root.refusalText = "owned by another user — needs sudo"
      return
    }
    if (!/^[0-9]+$/.test(row.uid) || !/^[0-9]+$/.test(row.starttime)) {
      root.refusalText = "process identity unreadable — ctrl+r to refresh"
      return
    }
    if (!/^[0-9]+$/.test(row.port)) return
    var key = row.pid + ":" + row.starttime
    var signal = (key === root.lastKilledKey) ? "KILL" : "TERM"
    root.lastKilledKey = key
    root.killPort = row.port
    root.killState = "terminating"
    root.verifyAttempt = 0
    // The helper re-checks pid+uid+starttime against live /proc before
    // signaling; everything travels as argv, never interpolated.
    killProc.command = ["bash", root.sourceDir() + "/kill-port.sh",
                        row.pid, row.uid, row.starttime, signal]
    killProc.running = true
  }

  ListModel { id: displayModel }

  PointerMoveGate {
    id: pointerGate
    referenceItem: card
  }

  Process {
    id: listProc
    command: ["bash", root.sourceDir() + "/list-ports.sh"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.loadPorts(text)
    }
    // The script itself always exits 0; a non-zero code means bash never ran
    // it, so no trustworthy payload exists.
    onExited: function(exitCode) {
      if (exitCode !== 0) root.probeState = "failed"
    }
  }

  // A probe that hangs (e.g. a cwd readlink stuck on a dead mount) must land
  // in "failed", not leave the overlay waiting forever. Single-shot by
  // design: a stuck D-state child may survive running=false, and re-arming
  // would loop.
  Timer {
    id: probeWatchdog
    interval: 4000
    onTriggered: {
      listProc.running = false
      root.probeState = "failed"
      root.ports = []
      root.rebuildDisplay()
    }
  }

  Process {
    id: killProc
    // Verify the outcome whether or not the helper signaled: if it refused
    // because the process already vanished, the port is likely free and the
    // banner should say so.
    onExited: {
      root.verifyAttempt = 0
      verifyTimer.interval = 300
      verifyTimer.restart()
    }
  }

  // The verification question is "is the port free", not "is the process
  // gone" — a process can die while something else takes the port, and can
  // survive having closed its socket. Port-scoped ss checks at ~300ms/1s/3s;
  // never the full probe (which grows a /proc walk in later phases). One
  // full refresh once the sequence resolves.
  Timer {
    id: verifyTimer
    onTriggered: {
      root.verifyAttempt += 1
      checkProc.running = false
      checkProc.running = true
    }
  }

  Process {
    id: checkProc
    command: ["sh", "-c", "ss -Htln \"sport = :$1\"", "harbor-verify", root.killPort]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyVerify(text)
    }
  }

  function applyVerify(out) {
    if (root.killState !== "terminating") return
    if (String(out || "").trim() === "") {
      root.killState = "freed"
      root.refresh()
      return
    }
    if (root.verifyAttempt === 1) { verifyTimer.interval = 700; verifyTimer.restart(); return }
    if (root.verifyAttempt === 2) { verifyTimer.interval = 2000; verifyTimer.restart(); return }
    root.killState = "survived"
    root.refresh()
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "harbor"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            if (root.filterText) root.setFilter("")
            else root.dismiss()
            event.accepted = true
          } else if (event.key === Qt.Key_Up || (event.key === Qt.Key_P && (event.modifiers & Qt.ControlModifier))) {
            root.select(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_Down || (event.key === Qt.Key_N && (event.modifiers & Qt.ControlModifier))) {
            root.select(1)
            event.accepted = true
          } else if (event.key === Qt.Key_K && (event.modifiers & Qt.ControlModifier)) {
            root.killSelected()
            event.accepted = true
          } else if (event.key === Qt.Key_Y && (event.modifiers & Qt.ControlModifier)) {
            root.copySelected()
            event.accepted = true
          } else if (event.key === Qt.Key_R && (event.modifiers & Qt.ControlModifier)) {
            root.refresh()
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.openSelected()
            event.accepted = true
          } else if (Util.editsFilter(event, root.filterText)) {
            root.setFilter(Util.editedFilter(event, root.filterText))
            event.accepted = true
          } else if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127) {
            root.setFilter(root.filterText + event.text)
            event.accepted = true
          }
        }
      }

      Column {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: root.contentSpacing

        Rectangle {
          width: parent.width
          height: root.headerHeight
          radius: root.cornerRadius
          color: "transparent"

          Text {
            anchors.left: parent.left
            anchors.right: hint.left
            anchors.rightMargin: Style.spacing.md
            anchors.verticalCenter: parent.verticalCenter
            text: root.filterText || "Filter ports…"
            color: root.foreground
            opacity: root.filterText ? 1 : 0.58
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            elide: Text.ElideRight
          }

          Text {
            id: hint
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: "enter open · ctrl+k kill · ctrl+r refresh · esc close"
            color: root.foreground
            opacity: 0.45
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        // The answer slot: "N is free", the next-free suggestion, and (in
        // later phases) kill outcomes and refusal explanations.
        Text {
          id: banner
          visible: root.bannerText !== ""
          width: parent.width
          text: root.bannerText
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
          elide: Text.ElideRight
        }

        Item {
          width: parent.width
          height: parent.height - root.headerHeight - root.contentSpacing
            - (banner.visible ? banner.height + root.contentSpacing : 0)

          ListView {
            id: resultList
            anchors.fill: parent
            model: displayModel
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            delegate: Rectangle {
              id: rowItem
              required property int index
              required property string port
              required property string process
              required property string pid
              required property string cwd
              required property string scope
              required property string address
              required property string uid
              required property string starttime

              readonly property bool hasCursor: root.cursorActive && index === root.selectedIndex
              readonly property bool terminating: root.killState === "terminating"
                && rowItem.pid + ":" + rowItem.starttime === root.lastKilledKey

              // "localhost" and "all interfaces" say it best; for a single
              // interface the literal address is the informative thing.
              readonly property string scopeLabel: scope === "local" ? "localhost"
                                                 : scope === "any" ? "all interfaces"
                                                 : address
              // Project slot: cwd basename until the marker walk (Phase 6)
              // replaces it with the checkout name.
              readonly property string project: {
                if (!cwd || cwd === "-" || cwd === "/") return ""
                var parts = cwd.split("/")
                return parts[parts.length - 1]
              }
              // Empty segments collapse so no separator dangles.
              readonly property string contextLine: {
                var parts = [rowItem.scopeLabel]
                if (rowItem.project) parts.push(rowItem.project)
                if (rowItem.pid !== "?") parts.push("pid " + rowItem.pid)
                if (rowItem.process === "docker-proxy") parts.push("container — docker stop frees this")
                return parts.join(" · ")
              }

              width: resultList.width
              height: root.rowHeight
              radius: root.cornerRadius
              color: rowItem.hasCursor ? root.selectedBackground : "transparent"
              opacity: rowItem.terminating ? 0.55 : 1

              Column {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: Style.spacing.md
                anchors.rightMargin: Style.spacing.md
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)

                Row {
                  width: parent.width
                  spacing: Style.spacing.md

                  Text {
                    id: portText
                    text: rowItem.port
                    color: rowItem.hasCursor ? root.selectedText : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                  }

                  Text {
                    width: parent.width - portText.width - Style.spacing.md
                    text: rowItem.process
                    color: rowItem.hasCursor ? root.selectedText : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    elide: Text.ElideRight
                  }
                }

                Text {
                  width: parent.width
                  text: rowItem.contextLine
                  color: rowItem.hasCursor ? root.selectedText : root.foreground
                  opacity: 0.65
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onPositionChanged: function(mouse) {
                  root.selectFromPointer(rowItem.index, rowItem, mouse)
                }
                onClicked: {
                  root.cursorActive = true
                  root.selectedIndex = rowItem.index
                  root.openSelected()
                }
              }
            }
          }

          Column {
            // Explicit width: an unsized Column whose children bind to
            // parent.width resolves to zero and gets culled (built-in
            // overlays share this bug).
            width: parent.width
            anchors.centerIn: parent
            spacing: Style.space(8)
            // The banner already answers a port query; a "No ports match"
            // block under a "3000 is free" line would muddy the answer.
            visible: displayModel.count === 0 && root.bannerText === ""

            Text {
              text: "󰛳"
              color: root.selectedText
              opacity: 0.8
              font.family: root.fontFamily
              font.pixelSize: Style.font.displayLarge
              horizontalAlignment: Text.AlignHCenter
              width: parent.width
            }

            Text {
              text: root.probeState === "failed" ? "Couldn't read the socket table. Is iproute2 installed?"
                  : root.probeState === "unknown" ? "Reading listening sockets…"
                  : root.filterText ? "No ports match “" + root.filterText + "”"
                  : "Nothing is listening on localhost"
              color: root.foreground
              opacity: 0.7
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              horizontalAlignment: Text.AlignHCenter
              width: parent.width
            }
          }
        }
      }
    }
  }
}
