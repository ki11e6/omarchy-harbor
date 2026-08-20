import QtQuick
import qs.Ui

BarWidget {
  id: root
  moduleName: "io.github.ki11e6.harbor"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰛳"
    onPressed: function(mouseButton) {
      if (!root.bar) return
      // Same IPC path as the keybinding so click and hotkey behave identically.
      root.bar.run("omarchy-shell shell toggle io.github.ki11e6.harbor '{}'")
    }
  }
}
