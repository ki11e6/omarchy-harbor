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

// Every port the machine holds, as an exact numeric set. Two sources, because
// the row table is listeners only: `ports` names the holders Harbor can show,
// `occupied` carries every port held in any other bind-refusing state. A
// socket pinned to a port by an outbound connection appears only in the
// second, and answering from the first alone calls it free.
//
// Exact scan, never display-list emptiness: the display filter is substring
// based, so "3000" also matches 13000 — an empty display does not mean the
// typed number is free, and a non-empty one does not mean it is taken.
function occupancy(ports, occupied) {
  var set = {}
  var rows = ports || []
  for (var i = 0; i < rows.length; i++) set[parseInt(rows[i].port, 10)] = true
  var extra = occupied || []
  for (var j = 0; j < extra.length; j++) set[parseInt(extra[j], 10)] = true
  return set
}

function portInUse(occ, n) {
  return (occ || {})[n] === true
}

// True when the kernel may hand this port out as an outbound source port. A
// port in here can be genuinely free at the instant of the answer and taken
// by the time the user binds it. start of 0 means the probe could not read
// the range, and an unread range asserts nothing.
function inEphemeralRange(n, start, end) {
  return start > 0 && end >= start && n >= start && n <= end
}

// Nearest higher free port. The banner *reports* on a port the user named,
// caveat included; a suggestion *recommends* one, so it stays where the answer
// will still hold a second later: never below the unprivileged floor (advice
// to try a privileged port is bad advice) and never inside the ephemeral
// range (advice to race the kernel is worse).
function nextFreePort(occ, from, floor, ephStart, ephEnd) {
  var p = Math.max(from + 1, floor)
  var scanned = 0
  // The scan cap bounds the loop; returning 0 means "no suggestion", not
  // "nothing is free". Jumping the ephemeral block spends no budget — it is
  // one contiguous range, so the jump strictly advances and cannot repeat.
  while (p <= 65535 && scanned <= 200) {
    if (inEphemeralRange(p, ephStart, ephEnd)) { p = ephEnd + 1; continue }
    if (!portInUse(occ, p)) return p
    p += 1
    scanned += 1
  }
  return 0
}

// The host that actually reaches a row, for open and copy. A listener bound to
// one address has nothing at any other, so this branches on the *address*, not
// the scope label: "local" spans all of 127.*, and 127.0.0.2 — or
// systemd-resolved on 127.0.0.53, present on a stock box — is no more reachable
// at localhost than 192.168.1.5 is. Only a wildcard bind, or 127.0.0.1 itself,
// is honestly "localhost". IPv6 literals get brackets so the result is a
// usable URL authority.
//
// Lives here rather than in the overlay because it is the answer to "where do I
// point my browser", it has been wrong twice, and the QML side has no harness.
function hostFor(row) {
  var addr = String((row && row.address) || "")
  if (addr === "" || addr === "0.0.0.0" || addr === "::" || addr === "*" || addr === "127.0.0.1")
    return "localhost"
  return addr.indexOf(":") >= 0 ? "[" + addr + "]" : addr
}

if (typeof module !== "undefined") {
  module.exports = {
    queriedPortOf: queriedPortOf,
    occupancy: occupancy,
    portInUse: portInUse,
    inEphemeralRange: inEphemeralRange,
    nextFreePort: nextFreePort,
    hostFor: hostFor
  }
}
