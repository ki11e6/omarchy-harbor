// Pure answer logic for Harbor: is the queried port free, and where to go
// instead. No Qt in here, so `node` can drive the fixture checks directly;
// QML's .js import ignores the module.exports block.

// A filter that is exactly a port number is a question about that port.
// No leading zeros: "00080" is not a port a user typed on purpose, and
// treating it as 80 would answer a question they did not ask.
function queriedPortOf(text) {
  var t = String(text === undefined || text === null ? "" : text).trim()
  if (!/^[1-9][0-9]{0,4}$/.test(t)) return 0
  var n = parseInt(t, 10)
  return n <= 65535 ? n : 0
}

// Exact scan, never display-list emptiness: the display filter is substring
// based, so "3000" also matches 13000 — an empty display does not mean the
// typed number is free, and a non-empty one does not mean it is taken.
function portInUse(ports, n) {
  var list = ports || []
  for (var i = 0; i < list.length; i++)
    if (parseInt(list[i].port, 10) === n) return true
  return false
}

// Nearest higher free port. The banner *reports* on a port the user named,
// caveat included; a suggestion *recommends* one, so it never goes below the
// unprivileged floor — advice to try a privileged port is bad advice.
function nextFreePort(ports, from, floor) {
  var used = {}
  var list = ports || []
  for (var i = 0; i < list.length; i++) used[parseInt(list[i].port, 10)] = true
  var start = Math.max(from + 1, floor)
  // The scan cap bounds the loop; returning 0 means "no suggestion",
  // not "nothing is free".
  for (var p = start; p <= 65535 && p - start <= 200; p++)
    if (!used[p]) return p
  return 0
}

if (typeof module !== "undefined") {
  module.exports = {
    queriedPortOf: queriedPortOf,
    portInUse: portInUse,
    nextFreePort: nextFreePort
  }
}
