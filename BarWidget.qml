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
  // "no binding" is a claim and needs the same evidence a free port does: an
  // empty bindLabel from a probe that never ran means nothing was learned, not
  // that nothing is bound. Same invariant as the probe's ok envelope.
  property string bindState: "unknown"   // "unknown" | "ok" | "failed"

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
    var binds = null
    try { binds = JSON.parse(raw || "") } catch (e) { binds = null }
    // A working `hyprctl binds -j` always yields an array; anything else is a
    // probe that failed, not a machine without bindings.
    if (!Array.isArray(binds)) {
      root.bindState = "failed"
      root.bindLabel = ""
      return
    }
    root.bindState = "ok"
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
    // hyprctl missing, or not a Hyprland session: no payload to trust.
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.bindState = "failed"
        root.bindLabel = ""
      }
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰀱"
    // The "set one" nudge is only shown on evidence: a probe that read the
    // binds and found none. A failed or pending lookup says nothing rather
    // than sending the user to edit a file that may already be correct.
    tooltipText: root.bindLabel !== ""
      ? "Harbor — is this port free?\n" + root.bindLabel
      : root.bindState === "ok"
        ? "Harbor — is this port free?\nNo keybinding set — add one in ~/.config/hypr/bindings.lua"
        : "Harbor — is this port free?"
    onPressed: function(mouseButton) {
      if (!root.bar) return
      // Same IPC path as the keybinding so click and hotkey behave identically.
      root.bar.run("omarchy-shell shell toggle io.github.ki11e6.harbor '{}'")
    }
  }
}
