// Unit checks for answers.js — the free/used/next-free logic.
// Run: node test/answers-test.js

const assert = require("assert")
const A = require("../answers.js")

const mk = ps => ps.map(p => ({ port: String(p) }))
const occ = (listeners, occupied) => A.occupancy(mk(listeners), occupied || [])

// queriedPortOf: a filter is a question only when it is exactly a port number
assert.strictEqual(A.queriedPortOf("8080"), 8080, "plain port")
assert.strictEqual(A.queriedPortOf(" 3000 "), 3000, "trimmed")
assert.strictEqual(A.queriedPortOf("65535"), 65535, "max port")
assert.strictEqual(A.queriedPortOf("65536"), 0, "out of range")
assert.strictEqual(A.queriedPortOf("00080"), 0, "leading zero rejected")
assert.strictEqual(A.queriedPortOf("0"), 0, "port zero rejected")
assert.strictEqual(A.queriedPortOf("node"), 0, "non-numeric")
assert.strictEqual(A.queriedPortOf(""), 0, "empty")

// portInUse: exact scan, never substring
assert.strictEqual(A.portInUse(occ([3000]), 3000), true, "exact hit")
assert.strictEqual(A.portInUse(occ([13000]), 3000), false, "substring collision")
assert.strictEqual(A.portInUse(occ([]), 3000), false, "empty list")

// occupancy unions the row table with the non-LISTEN ports. A port held only
// by an outbound connection has no row to show, and reading it as free is the
// EADDRINUSE Harbor exists to prevent.
assert.strictEqual(A.portInUse(occ([], [45321]), 45321), true,
  "a port held only by a non-LISTEN socket is taken")
assert.strictEqual(A.portInUse(occ([3000], [45321]), 3000), true,
  "listeners still count when occupied is present")
assert.strictEqual(A.portInUse(A.occupancy(mk([3000]), undefined), 3000), true,
  "a probe without occupied still answers from rows")

// inEphemeralRange: an unread range (0) asserts nothing
assert.strictEqual(A.inEphemeralRange(40000, 32768, 60999), true, "inside")
assert.strictEqual(A.inEphemeralRange(8080, 32768, 60999), false, "outside")
assert.strictEqual(A.inEphemeralRange(40000, 0, 0), false, "unread range claims nothing")

// nextFreePort: nearest higher free port, floored at the unprivileged start
assert.strictEqual(
  A.nextFreePort(occ([3000, 3001, 3002, 3003, 3004, 3005]), 3000, 1024, 0, 0), 3006,
  "contiguous run")
assert.strictEqual(A.nextFreePort(occ([]), 80, 1024, 0, 0), 1024,
  "suggestions never go below the floor")

// non-LISTEN ports are skipped by suggestions too — the compound failure:
// Harbor recommending a port that is already held invisibly
assert.strictEqual(A.nextFreePort(occ([45400], [45401]), 45400, 1024, 0, 0), 45402,
  "a suggestion must skip a port held by a non-LISTEN socket")

// suggestions never land inside the kernel's outbound source-port range
const suggested = A.nextFreePort(occ([45400]), 45400, 1024, 32768, 60999)
assert.strictEqual(suggested, 61000, "a suggestion inside the range jumps past it")
assert.strictEqual(A.inEphemeralRange(suggested, 32768, 60999), false,
  "no suggestion may sit in the ephemeral range")
assert.strictEqual(A.nextFreePort(occ([8080]), 8080, 1024, 32768, 60999), 8081,
  "the range does not disturb suggestions outside it")
// a scan that runs into the range from below jumps it rather than stalling
const upTo = []
for (let p = 32700; p <= 32767; p++) upTo.push(p)
assert.strictEqual(A.nextFreePort(occ(upTo), 32699, 1024, 32768, 60999), 61000,
  "a scan crossing into the range jumps to its far side")
// the jump must not run off the end of the port space
assert.strictEqual(A.nextFreePort(occ([]), 40000, 1024, 32768, 65535), 0,
  "a range reaching the last port leaves no suggestion, not a bad one")

// scan cap: a fully-occupied window returns 0 (no suggestion), not a lie
const run = []
for (let p = 3001; p <= 3001 + 201; p++) run.push(p)
assert.strictEqual(A.nextFreePort(occ(run), 3000, 1024, 0, 0), 0, "scan cap returns 0")

// hostFor: only a wildcard bind, or 127.0.0.1 itself, is reachable as
// "localhost". Scope is not the discriminator — "local" spans all of 127.*.
assert.strictEqual(A.hostFor({ scope: "any", address: "0.0.0.0" }), "localhost", "wildcard v4")
assert.strictEqual(A.hostFor({ scope: "any", address: "::" }), "localhost", "wildcard v6")
assert.strictEqual(A.hostFor({ scope: "any", address: "*" }), "localhost", "wildcard star")
assert.strictEqual(A.hostFor({ scope: "local", address: "127.0.0.1" }), "localhost", "loopback proper")
assert.strictEqual(A.hostFor({ scope: "local", address: "127.0.0.2" }), "127.0.0.2",
  "a 127.* address that is not 127.0.0.1 is not reachable as localhost")
assert.strictEqual(A.hostFor({ scope: "local", address: "127.0.0.53" }), "127.0.0.53",
  "systemd-resolved's address must not be rewritten to localhost")
assert.strictEqual(A.hostFor({ scope: "iface", address: "192.168.1.5" }), "192.168.1.5", "iface v4")
assert.strictEqual(A.hostFor({ scope: "local", address: "::1" }), "[::1]", "v6 literal is bracketed")
assert.strictEqual(A.hostFor({ scope: "iface", address: "fe80::1" }), "[fe80::1]", "v6 iface bracketed")
assert.strictEqual(A.hostFor({ scope: "local", address: "" }), "localhost", "missing address")
assert.strictEqual(A.hostFor({}), "localhost", "absent address field")

console.log("ANSWERS_TESTS_PASS")
