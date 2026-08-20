import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui

Item {
  id: root

  property var shell: null
  property var manifest: null

  property bool opened: false
  property string filterText: ""
  property int selectedIndex: 0
  property bool cursorActive: false
  property var ports: []
  // Set by ctrl+k; a second ctrl+k on the same still-alive PID escalates to SIGKILL.
  property string lastKilledPid: ""

  // Ports that don't speak HTTP: Enter copies the address instead of opening
  // a dead browser tab.
  readonly property var nonHttpPorts: ({ "22": 1, "25": 1, "53": 1, "111": 1, "631": 1,
                                         "3306": 1, "5432": 1, "6379": 1, "27017": 1 })

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
  property int rowHeight: Math.max(Style.space(40), Style.font.body + Style.spacing.md * 2)
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
    root.lastKilledPid = ""
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
  }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "io.github.ki11e6.harbor")
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  function refresh() {
    listProc.running = false
    listProc.running = true
  }

  function loadPorts(raw) {
    var parsed = []
    try { parsed = JSON.parse(raw || "[]") } catch (e) { parsed = [] }
    root.ports = parsed
    root.disarmPointer()
    if (root.lastKilledPid) {
      var alive = false
      for (var i = 0; i < parsed.length; i++)
        if (parsed[i].pid === root.lastKilledPid) alive = true
      if (!alive) root.lastKilledPid = ""
    }
    root.rebuildDisplay()
  }

  function matches(row, needle) {
    if (!needle) return true
    var hay = (row.port + " " + row.process + " " + row.pid + " " + row.cwd).toLowerCase()
    return hay.indexOf(needle) !== -1
  }

  function rebuildDisplay() {
    var needle = root.filterText.toLowerCase()
    displayModel.clear()
    for (var i = 0; i < root.ports.length; i++) {
      var row = root.ports[i]
      if (root.matches(row, needle))
        displayModel.append({ port: row.port, process: row.process, pid: row.pid, cwd: row.cwd })
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
    root.disarmPointer()
    root.rebuildDisplay()
  }

  function openSelected() {
    if (root.selectedIndex < 0 || root.selectedIndex >= displayModel.count) return
    var row = displayModel.get(root.selectedIndex)
    root.dismiss()
    if (root.nonHttpPorts[row.port])
      Quickshell.execDetached(["wl-copy", "localhost:" + row.port])
    else
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
    if (!/^[0-9]+$/.test(row.pid)) return
    killProc.command = (row.pid === root.lastKilledPid)
      ? ["kill", "-9", row.pid]
      : ["kill", row.pid]
    root.lastKilledPid = row.pid
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
  }

  Process {
    id: killProc
    onExited: refreshDelay.restart()
  }

  // Give the killed process a moment to release its socket before re-listing.
  Timer {
    id: refreshDelay
    interval: 350
    onTriggered: root.refresh()
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
            text: "enter open · ctrl+y copy · ctrl+k kill · ctrl+r refresh · esc close"
            color: root.foreground
            opacity: 0.45
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Item {
          width: parent.width
          height: parent.height - root.headerHeight - root.contentSpacing

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

              readonly property bool hasCursor: root.cursorActive && index === root.selectedIndex

              width: resultList.width
              height: root.rowHeight
              radius: root.cornerRadius
              color: rowItem.hasCursor ? root.selectedBackground : "transparent"

              Row {
                anchors.fill: parent
                anchors.leftMargin: Style.spacing.md
                anchors.rightMargin: Style.spacing.md
                spacing: Style.spacing.md

                Text {
                  width: Style.space(64)
                  anchors.verticalCenter: parent.verticalCenter
                  text: rowItem.port
                  color: rowItem.hasCursor ? root.selectedText : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                }

                Text {
                  width: Style.space(110)
                  anchors.verticalCenter: parent.verticalCenter
                  text: rowItem.process
                  color: rowItem.hasCursor ? root.selectedText : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                }

                Text {
                  width: Style.space(56)
                  anchors.verticalCenter: parent.verticalCenter
                  text: rowItem.pid
                  color: rowItem.hasCursor ? root.selectedText : root.foreground
                  opacity: 0.7
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }

                Text {
                  width: parent.width - Style.space(64) - Style.space(110) - Style.space(56) - Style.spacing.md * 3
                  anchors.verticalCenter: parent.verticalCenter
                  text: rowItem.cwd
                  color: rowItem.hasCursor ? root.selectedText : root.foreground
                  opacity: 0.6
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  elide: Text.ElideMiddle
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
            visible: displayModel.count === 0

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
              text: root.filterText ? "No ports match “" + root.filterText + "”" : "Nothing is listening on localhost"
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
