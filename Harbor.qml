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
  // Ports held in a bind-refusing state that is not LISTEN — an outbound
  // connection pinned to a source port owns it completely while appearing in
  // no listener table. Bare numbers: these have no holder Harbor can show,
  // they only make "is it free" answerable.
  property var occupiedPorts: []
  // "unknown" until a probe completes; nothing may claim a port is free
  // outside "ok" — a failed probe must never render as an empty (all-free)
  // machine.
  property string probeState: "unknown"   // "unknown" | "ok" | "failed"
  // True when bash never ran the probe (bad path, missing script) — a
  // different failure from the probe running and reporting ok:false.
  property bool probeLaunchFailed: false
  // Set by the watchdog before it kills a hung probe, so the exit that kill
  // produces is not mistaken for a launch failure.
  property bool probeTimedOut: false
  // A refresh requested while a probe is in flight. Restarting a running
  // Process delivers the killed run's partial output and exit AFTER the new
  // run has started, where they read as this refresh's answer — so the
  // in-flight run is left to finish, its result discarded, and run again.
  property bool probeQueued: false
  // Below this, a port can be free and still refuse an unprivileged bind.
  // Supplied by the probe (it reads the sysctl); 1024 is the fallback.
  property int unprivilegedPortStart: 1024
  // The kernel's outbound source-port range. 0/0 means the probe could not
  // read it, and an unread range asserts nothing.
  property int ephemeralStart: 0
  property int ephemeralEnd: 0
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

  // Both halves of the probe unioned once, so the banner asks a set instead of
  // rescanning the row table twice.
  readonly property var occupancy: Answers.occupancy(root.ports, root.occupiedPorts)

  // The answer — the hero of the overlay. {headline, detail, tone} or null.
  // Kill outcomes take precedence; otherwise null outside probeState "ok" —
  // never claim a port is free on a failed or pending probe; a suggestion is
  // a free-claim too. ("is now free" rests on the port-scoped ss check, not
  // on the probe, so it carries its own evidence.) Tones: "good" news in
  // accent, "warn" in urgent, "plain" in foreground.
  readonly property var banner: {
    if (root.refusalText) {
      var cut = root.refusalText.indexOf(" — ")
      return cut > 0
        ? { headline: root.refusalText.substring(0, cut), detail: root.refusalText.substring(cut + 3), tone: "warn" }
        : { headline: root.refusalText, detail: "", tone: "warn" }
    }
    // The verify sequence runs for up to ~3s; without this the answer zone
    // keeps showing the pre-kill answer and only the dimmed row says anything
    // happened.
    if (root.killState === "terminating")
      return { headline: root.killPort + " terminating…", detail: "", tone: "plain" }
    if (root.killState === "freed")
      return { headline: root.killPort + " is now free", detail: "", tone: "good" }
    if (root.killState === "survived")
      return { headline: root.killPort + " still listening", detail: "ctrl+k again to force", tone: "warn" }
    if (root.probeState !== "ok" || root.queriedPort === 0) return null
    if (!Answers.portInUse(root.occupancy, root.queriedPort)) {
      return { headline: root.queriedPort + " is free",
               detail: root.queriedPort < root.unprivilegedPortStart
                 ? "needs root or CAP_NET_BIND_SERVICE"
                 : Answers.inEphemeralRange(root.queriedPort, root.ephemeralStart, root.ephemeralEnd)
                   ? "in the kernel's outbound port range — a connection can claim it"
                   : "",
               tone: "good" }
    }
    var next = Answers.nextFreePort(root.occupancy, root.queriedPort, root.unprivilegedPortStart,
                                    root.ephemeralStart, root.ephemeralEnd)
    return { headline: next > 0
               ? root.queriedPort + " is taken — " + next + " is free"
               : root.queriedPort + " is taken",
             detail: "", tone: "plain" }
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
  property int contentSpacing: Style.spacing.md
  // Two text lines per row: identity above, context below.
  property int rowHeight: Math.max(Style.space(52), Style.font.body + Style.font.caption + Style.spacing.md * 2 + Style.space(2))
  property int cardWidth: Math.min(Style.space(520), panel.width - Style.gapsOut * 2)
  // The card shrinks to its answer: "8080 is free" is a compact card, a long
  // browse is a tall one. Heights come from the model, not laid-out items,
  // so there is no binding cycle with the list area.
  readonly property int cardMaxHeight: Math.min(Style.space(420), panel.height - Style.gapsOut * 2)
  readonly property int listContentHeight: displayModel.count > 0
    ? displayModel.count * root.rowHeight
    : (root.banner !== null ? 0 : Style.space(150))
  property int cardHeight: {
    var content = queryLine.height + root.contentSpacing
      + (root.banner !== null ? bannerBlock.height + root.contentSpacing : 0)
      + root.listContentHeight + root.contentSpacing
      + footerBlock.height
      + card.contentTopInset + card.contentBottomInset
      + root.contentMargin * 2
    return Math.min(root.cardMaxHeight, Math.max(Style.space(120), content))
  }

  // Derived from this file's own URL, not the manifest: the host hands
  // third-party plugins a sanitized manifest with __sourceDir stripped.
  function sourceDir() {
    return Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "").replace(/\/$/, "")
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
    root.probeLaunchFailed = false
    root.probeTimedOut = false
    if (listProc.running) {
      root.probeQueued = true
      return
    }
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
    root.occupiedPorts = ok && Array.isArray(parsed.occupied) ? parsed.occupied : []
    var floor = ok ? parseInt(parsed.unprivilegedPortStart, 10) : NaN
    root.unprivilegedPortStart = isFinite(floor) && floor >= 0 ? floor : 1024
    // Both ends or neither: a half-read range would caveat and steer against a
    // boundary the kernel never stated.
    var es = ok ? parseInt(parsed.ephemeralStart, 10) : NaN
    var ee = ok ? parseInt(parsed.ephemeralEnd, 10) : NaN
    var rangeOk = isFinite(es) && isFinite(ee) && es > 0 && ee >= es
    root.ephemeralStart = rangeOk ? es : 0
    root.ephemeralEnd = rangeOk ? ee : 0
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
          uid: String(row.uid || ""), starttime: String(row.starttime || ""),
          project: String(row.project || "")
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

  // Exec BEFORE dismiss in both actions: dismiss() unloads this plugin (no
  // keepLoaded), and a detached spawn queued after the unload no longer
  // survives it on current shells — the 2026-08-20 verification of the
  // opposite order does not hold anymore.
  function openSelected() {
    if (root.selectedIndex < 0 || root.selectedIndex >= displayModel.count) return
    var row = displayModel.get(root.selectedIndex)
    Quickshell.execDetached(["xdg-open", "http://" + Answers.hostFor(row) + ":" + row.port])
    root.dismiss()
  }

  function copySelected() {
    if (root.selectedIndex < 0 || root.selectedIndex >= displayModel.count) return
    var row = displayModel.get(root.selectedIndex)
    // Argv-style detached wl-copy dies silently under execDetached here; the
    // shell's own plugins pipe through a shell instead (network Panel.qml:450,
    // tailscale Service.qml:109). Follow the proven pattern.
    var text = Answers.hostFor(row) + ":" + row.port
    Quickshell.execDetached(["bash", "-c", "printf %s " + Util.shellQuote(text) + " | wl-copy"])
    root.dismiss()
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
    // A verification already in flight belongs to a previous row; its result
    // must not be attributed to this one.
    verifyTimer.stop()
    checkProc.running = false
    // The helper re-checks pid+uid+starttime against live /proc before
    // signaling; everything travels as argv, never interpolated.
    killProc.command = ["bash", root.sourceDir() + "/kill-port.sh",
                        row.pid, row.uid, row.starttime, signal]
    killProc.running = true
  }

  ListModel { id: displayModel }

  // Footer key hint: a bordered keycap and its label. Children reference the
  // component root by id, not parent chains — wrapper insertion must not be
  // able to silently rebind them.
  component Keycap: Row {
    id: cap
    property string keys: ""
    property string label: ""
    spacing: Style.space(5)

    Rectangle {
      anchors.verticalCenter: parent.verticalCenter
      width: capText.implicitWidth + Style.space(10)
      height: capText.implicitHeight + Style.space(4)
      radius: Style.space(3)
      color: "transparent"
      border.width: Math.max(1, Style.space(1))
      border.color: root.foreground
      opacity: 0.4

      Text {
        id: capText
        anchors.centerIn: parent
        text: cap.keys
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    Text {
      anchors.verticalCenter: parent.verticalCenter
      text: cap.label
      color: root.foreground
      opacity: 0.55
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  PointerMoveGate {
    id: pointerGate
    referenceItem: card
  }

  Process {
    id: listProc
    command: ["bash", root.sourceDir() + "/list-ports.sh"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (!root.probeQueued) root.loadPorts(text)
    }
    // The script itself always exits 0; a non-zero code means bash never ran
    // it, so no trustworthy payload exists.
    onExited: function(exitCode) {
      if (root.probeQueued) {
        root.probeQueued = false
        root.refresh()
        return
      }
      if (exitCode !== 0) {
        if (!root.probeTimedOut) root.probeLaunchFailed = true
        root.probeState = "failed"
      }
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
      root.probeTimedOut = true
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
    // Deliberately -l, unlike the occupancy probe's -a: killing a listener
    // leaves its accepted connections in TIME-WAIT on the same port, and -a
    // would read those as "still listening" and report a successful kill as a
    // survivor. The question here is whether the listener let go.
    command: ["sh", "-c", "ss -Htln \"sport = :$1\"", "harbor-verify", root.killPort]
    stdout: StdioCollector { id: checkOut; waitForEnd: true }
    // Exit code, exit status and stdout together: a failed ss and a free port
    // both print nothing, and "freed" is a free-claim — it needs evidence, not
    // silence.
    onExited: function(exitCode, exitStatus) {
      root.applyVerify(exitCode, exitStatus, String(checkOut.text || ""))
    }
  }

  function applyVerify(exitCode, exitStatus, out) {
    if (root.killState !== "terminating") return
    // No check has been launched for this kill yet, so this exit belongs to
    // the one killSelected cancelled — Quickshell delivers it after the new
    // kill has already set "terminating", and it would mark that kill
    // survived before it was ever verified.
    if (root.verifyAttempt === 0) return
    if (exitCode !== 0 || exitStatus !== 0) {
      // ss itself failed — evidence for neither outcome. "survived" is the
      // safe claim: it never asserts a port is free without proof.
      root.killState = "survived"
      root.refresh()
      return
    }
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
      Behavior on height { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
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
            // A refusal must not outlive the remedy it prescribes ("ctrl+r to
            // refresh"). Outcome banners (freed/survived) deliberately survive
            // a manual refresh — they are still true. Not cleared inside
            // refresh() itself: applyVerify sets the outcome and then
            // refreshes, and would wipe its own banner.
            root.refusalText = ""
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

        Row {
          id: queryLine
          width: parent.width
          height: Math.max(Style.space(30), Style.font.heading + Style.spacing.controlPaddingY * 2)
          spacing: Style.space(8)

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "❯"
            color: Color.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            font.bold: true
          }

          Text {
            id: queryText
            anchors.verticalCenter: parent.verticalCenter
            width: Math.min(implicitWidth, parent.width - Style.space(40))
            text: root.filterText
            visible: root.filterText !== ""
            // Qt's AutoText parses tag-shaped input as rich text; every
            // dynamic string here is user- or process-controlled, so pin
            // plain text. (Defence in depth: comm is 15 bytes and paths
            // can't contain "/", so a working <img> is hard to build — and
            // this does not cover bidi/zero-width spoofing.)
            textFormat: Text.PlainText
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            elide: Text.ElideLeft
          }

          Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: Math.max(2, Style.space(2))
            height: Style.font.heading
            color: Color.accent
            SequentialAnimation on opacity {
              loops: Animation.Infinite
              NumberAnimation { from: 1; to: 1; duration: 560 }
              NumberAnimation { from: 0; to: 0; duration: 360 }
            }
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            visible: root.filterText === ""
            text: "type a port to check, or filter"
            color: root.foreground
            opacity: 0.4
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            elide: Text.ElideRight
          }
        }

        // The answer zone — the hero. Free/freed in accent, refusals and
        // survivors in urgent, "taken" neutral.
        Column {
          id: bannerBlock
          visible: root.banner !== null
          width: parent.width
          spacing: Style.space(4)
          topPadding: Style.space(8)
          bottomPadding: Style.space(8)

          Text {
            width: parent.width
            text: root.banner ? root.banner.headline : ""
            textFormat: Text.PlainText
            color: root.banner === null ? root.foreground
                 : root.banner.tone === "good" ? Color.accent
                 : root.banner.tone === "warn" ? Color.urgent
                 : root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
            font.bold: true
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
          }

          Text {
            width: parent.width
            visible: root.banner !== null && root.banner.detail !== ""
            text: root.banner && root.banner.detail ? root.banner.detail : ""
            textFormat: Text.PlainText
            color: root.foreground
            opacity: 0.6
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
          }
        }

        Item {
          width: parent.width
          height: parent.height - queryLine.height - root.contentSpacing
            - (bannerBlock.visible ? bannerBlock.height + root.contentSpacing : 0)
            - footerBlock.height - root.contentSpacing

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
              required property string project

              readonly property bool hasCursor: root.cursorActive && index === root.selectedIndex
              readonly property bool terminating: root.killState === "terminating"
                && rowItem.pid + ":" + rowItem.starttime === root.lastKilledKey

              // "all interfaces" and "localhost" say it best; anything holding
              // one specific address — including a 127.* that is not 127.0.0.1 —
              // is only described by the address itself. Same rule the open/copy
              // host uses, so the row cannot label a listener "localhost" while
              // ctrl+y copies 127.0.0.2.
              readonly property string scopeLabel: scope === "any" ? "all interfaces"
                                                 : Answers.hostFor(rowItem) === "localhost" ? "localhost"
                                                 : address
              readonly property bool exposed: scope !== "local"
              // Empty segments collapse so no separator dangles. Project
              // leads — it is the name a person recognises.
              readonly property string contextLine: {
                var parts = []
                if (rowItem.project) parts.push(rowItem.project)
                parts.push(rowItem.scopeLabel)
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

                  // Exposure at a glance: urgent when reachable beyond
                  // loopback, dim when localhost-only.
                  Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(7)
                    height: Style.space(7)
                    radius: width / 2
                    color: rowItem.exposed ? Color.urgent : root.foreground
                    opacity: rowItem.exposed ? 0.9 : 0.3
                  }

                  Text {
                    id: portText
                    text: rowItem.port
                    textFormat: Text.PlainText
                    color: rowItem.hasCursor ? root.selectedText : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                  }

                  Text {
                    width: parent.width - Style.space(7) - portText.width - Style.spacing.md * 2
                    text: rowItem.process
                    textFormat: Text.PlainText
                    color: rowItem.hasCursor ? root.selectedText : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    elide: Text.ElideRight
                  }
                }

                Text {
                  width: parent.width
                  text: rowItem.contextLine
                  textFormat: Text.PlainText
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
            visible: displayModel.count === 0 && root.banner === null

            Text {
              text: "󰀱"
              color: root.selectedText
              opacity: 0.8
              font.family: root.fontFamily
              font.pixelSize: Style.font.displayLarge
              horizontalAlignment: Text.AlignHCenter
              width: parent.width
            }

            Text {
              text: root.probeState === "failed" && root.probeLaunchFailed ? "Couldn't run list-ports.sh from " + root.sourceDir()
                  : root.probeState === "failed" ? "Couldn't read the socket table. Is iproute2 installed?"
                  : root.probeState === "unknown" ? "Reading listening sockets…"
                  : root.filterText ? "No ports match “" + root.filterText + "”"
                  : "Nothing is listening on localhost"
              textFormat: Text.PlainText
              color: root.foreground
              opacity: 0.7
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              horizontalAlignment: Text.AlignHCenter
              width: parent.width
            }
          }
        }

        Column {
          id: footerBlock
          width: parent.width
          spacing: root.contentSpacing

          Rectangle {
            width: parent.width
            height: Math.max(1, Style.space(1))
            color: root.border
            opacity: 0.35
          }

          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Style.space(14)

            Keycap { keys: "↵"; label: "open" }
            Keycap { keys: "^k"; label: "kill" }
            Keycap { keys: "^r"; label: "refresh" }
            Keycap { keys: "esc"; label: "close" }
          }
        }
      }
    }
  }
}
