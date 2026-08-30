import QtQuick
import Quickshell.Io
import qs.Ui

BarWidget {
  id: root
  moduleName: "io.github.ki11e6.harbor"

  // "SUPER+ALT+P" when a Hyprland binding named "Harbor" exists, else "".
  // o.bind registers a Lua callback, so the binds JSON carries no command —
  // the bind's description is the only identifiable handle.
  property string bindLabel: ""

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function modLabel(mask) {
    var parts = []
    if (mask & 64) parts.push("SUPER")
    if (mask & 8) parts.push("ALT")
    if (mask & 4) parts.push("CTRL")
    if (mask & 1) parts.push("SHIFT")
    return parts
  }

  function loadBinds(raw) {
    var binds = []
    try { binds = JSON.parse(raw || "[]") } catch (e) { binds = [] }
    for (var i = 0; i < binds.length; i++) {
      var d = String(binds[i].description || "").toLowerCase()
      if (d.indexOf("harbor") === -1) continue
      var parts = root.modLabel(Number(binds[i].modmask) || 0)
      parts.push(String(binds[i].key || "").toUpperCase())
      root.bindLabel = parts.join("+")
      return
    }
    root.bindLabel = ""
  }

  // One shot at bar load — no polling, the widget stays idle-free.
  Process {
    id: bindsProbe
    running: true
    command: ["hyprctl", "binds", "-j"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.loadBinds(text)
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰀱"
    tooltipText: root.bindLabel !== ""
      ? "Harbor — is this port free?\n" + root.bindLabel
      : "Harbor — is this port free?\nNo keybinding set — add one in ~/.config/hypr/bindings.lua"
    onPressed: function(mouseButton) {
      if (!root.bar) return
      // Same IPC path as the keybinding so click and hotkey behave identically.
      root.bar.run("omarchy-shell shell toggle io.github.ki11e6.harbor '{}'")
    }
  }
}
