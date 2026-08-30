// Unit checks for answers.js — the free/used/next-free logic.
// Run: node test/answers-test.js

const assert = require("assert")
const A = require("../answers.js")

const mk = ps => ps.map(p => ({ port: String(p) }))

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
assert.strictEqual(A.portInUse(mk([3000]), 3000), true, "exact hit")
assert.strictEqual(A.portInUse(mk([13000]), 3000), false, "substring collision")
assert.strictEqual(A.portInUse(mk([]), 3000), false, "empty list")

// nextFreePort: nearest higher free port, floored at the unprivileged start
assert.strictEqual(
  A.nextFreePort(mk([3000, 3001, 3002, 3003, 3004, 3005]), 3000, 1024), 3006,
  "contiguous run")
assert.strictEqual(A.nextFreePort(mk([]), 80, 1024), 1024,
  "suggestions never go below the floor")
assert.ok(A.nextFreePort(mk([]), 80, 1024) >= 1024, "floor respected")

// scan cap: a fully-occupied window returns 0 (no suggestion), not a lie
const run = []
for (let p = 3001; p <= 3001 + 201; p++) run.push(p)
assert.strictEqual(A.nextFreePort(mk(run), 3000, 1024), 0, "scan cap returns 0")

console.log("ANSWERS_TESTS_PASS")
