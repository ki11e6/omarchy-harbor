# Harbor — Port Answer Machine Plan

## Overview

`docs/VISION.md` defines Harbor as an answer machine for a bind failure: which of
the two exits applies — free the port, or move to another one — and one keystroke
to take it. Measured against the eight scenarios listed there, Harbor currently
covers one cleanly (scenario 1) and partially covers two more.

This plan closes the rest. It assumes `docs/plans/2026-08-30-scope-removal.md`
has landed.

## Current State Analysis

Read in this session (2026-08-30). Line references are to the current tree.

### What works

- `list-ports.sh` produces one row per port, named owner preferred over `?`,
  sorted numerically — the dedup and space-in-process-name fixes from the
  original rewrite hold.
- `Harbor.qml:238-268` key handling, filter, and selection are solid; the
  `PointerMoveGate` fix from the 2026-08-20 review closed the mis-selection bug.
- `Harbor.qml:31-32` — the probe already strips tabs and newlines from `process`
  and `cwd` before assembling the tab-delimited row. **This is load-bearing and
  must be preserved.** Both surveyed omaports plugins omit it; without it a
  process can name its own cwd with an embedded newline and forge a row,
  attributing a port to a PID that does not hold it.

### Verified gaps

| # | Gap | Evidence |
|---|---|---|
| G1 | A failed probe is indistinguishable from an empty machine | `loadPorts` (`Harbor.qml:89-101`) catches any parse failure to `[]`; `listProc` (`:179-186`) has **no `onExited` handler at all**, so a non-zero exit is never observed. The empty state then reads "Nothing is listening on localhost" (`:420`) — a false "free" |
| G2 | Listeners on specific non-loopback addresses are invisible | `list-ports.sh:17` accepts only `127.*`, `0.0.0.0`, `*`, `[::]`, `[::1]`. A server on `192.168.1.5:3000` is dropped, so Harbor shows 3000 as absent while a `0.0.0.0:3000` bind will fail |
| G3 | The address is discarded even when captured | `list-ports.sh:37` prints port, name, pid, cwd — no address. Harbor cannot tell the user whether a `localhost` bind would still succeed |
| G4 | No affirmative "free" | Typing an unmatched port yields `"No ports match “8080”"` (`Harbor.qml:420`) — ambiguous between free, hidden by G2, and failed per G1 |
| G5 | No next-free-port suggestion | Nothing in the codebase. This is the whole "change the port" exit |
| G6 | Kill outcome is never confirmed | `killProc.onExited` triggers a single 350 ms `refreshDelay` (`Harbor.qml:188-198`). No terminating state, no retry, no "it's free now", no "it survived" |
| G7 | Escalation keys on a bare PID | `lastKilledPid` (`:20, 94-99, 165-168`) survives refreshes and compares PID strings only. SIGTERM pid 1234 → it dies → 1234 is recycled onto another listener → a second `ctrl+k` SIGKILLs the wrong process |
| G8 | A kill that cannot happen fails silently | `killSelected` returns at `:164` when the PID is `?`, with no message. Also offers a kill on `docker-proxy` rows that dockerd will simply undo |
| G9 | Owner identity is the runtime's thread name | `process` is `/proc/pid/comm`; four checkouts of the same app are four rows reading `node` |
| G10 | Process-controlled strings render as auto-detected rich text | Row `Text` elements (`:342-381`, `:409-427`) set no `textFormat` |

### Assumptions requiring verification before implementation

Reasoned from source but **not executed** in this session. Confirm each before
relying on it:

- **A1.** ~~`list-ports.sh` is expected to exit 0 with `ss` missing, because
  `jq` succeeds on empty input.~~ **Settled 2026-08-30, prediction wrong in
  mechanism, right in conclusion:** with `ss` missing and jq present, the old
  script exited **127** — `set -o pipefail` did propagate — but stdout still
  carried `[]`, and `Harbor.qml` had no `onExited` handler at all, so the
  overlay parsed `[]` and rendered "Nothing is listening" regardless. The false
  "free" was real, reached via an *ignored* exit code rather than a *masked*
  one. Phase 1's wrapper (`{ok, ports}`) plus the new `onExited` covers both
  routes. (Test note: invoke as `PATH=… /usr/bin/bash list-ports.sh` — a plain
  `PATH=… bash` prevents the outer shell from finding bash itself.)
- **A2.** Quickshell's `Process` exposes `onExited(exitCode)` on the version
  shipped here (0.3.0). Both surveyed plugins use it; confirm against
  `/usr/share/omarchy/shell` before depending on it.
- **A3.** Setting `Process.running = false` on a probe blocked in uninterruptible
  I/O (a cwd on a dead network mount) may not reap it, in which case the Phase 1
  watchdog needs a re-arm guard rather than a single stop.
- **A4.** `docker-proxy` as a `comm` value is the standard signal for a
  container-published port under Docker's default userland proxy. It will not
  match rootless Docker, Podman, or `userland-proxy: false` setups. Phase 5
  treats it as a heuristic hint, never as a precondition for anything.

## Desired End State

Typing a port number into Harbor produces exactly one of the four answers in
`VISION.md`, plus a next-free suggestion when the port is taken; `ctrl+k` reports
whether it actually freed the port; and an action that cannot happen says why.

## What We're NOT Doing

Everything on the "not doing" table in `docs/VISION.md`. Specifically declined
during the 2026-08-30 prior-art survey and not to be re-proposed without
revising that document: framework-detection regex tables, a Qt-free `Model.js`
rewrite, a settings schema, a confirm-before-kill dialog, terminal-in-project,
IPC query handlers, output caps, polling, multi-select, Docker management,
named ports.

## Coverage

`VISION.md` defines completion as all eight of its scenarios having a truthful
answer. This plan tracks gaps as G1-G10; the two schemes map as follows, so
coverage can be checked without re-deriving it.

| Vision scenario | Gaps | Phase |
|---|---|---|
| 1 — Bind failed, what holds 3000? | G2, G3, G9 | 2, 6 (works today; 2 and 6 sharpen it) |
| 2 — Is 8080 free? | G1, G2, G4 | 1, 2, 3 |
| 3 — Give me one that isn't | G5 | 3 |
| 4 — Did my kill work? | G6, G7 | 4 |
| 5 — Which of my four checkouts? | G9 | 6 |
| 6 — Held by `docker-proxy` | G8 | 5 |
| 7 — Held by root | G8 | 5 |
| 8 — Serving an old build | G9 | 6 |
| (cross-cutting) | G10 | 7 |

## Sequencing

Phases 1 and 2 are the foundation and are ordered. Phase 3 depends on both — the
"free" answer is only truthful once failures are detectable (Phase 1) and no
listener is hidden (Phase 2). Phase 4 depends on Phase 2 for `starttime`.
Phase 5 needs nothing from Phase 2 — `pid == "?"` and `process == "docker-proxy"`
are both in today's schema — but it does need the banner surface that Phase 3
creates, so it follows 3. Phase 7 is independent throughout.

```
1 ──▶ 2 ──┬──▶ 3 ──▶ 5
          ├──▶ 4
          └──▶ 6
7 (independent)
```

---

## Phase 1: Probe honesty

### Overview

Make "unknown" a first-class state. Nothing else in this plan is safe until a
failed probe stops rendering as an empty machine. Closes G1.

### Changes Required

#### 1. `list-ports.sh` — capture `ss`'s own exit code

The pipeline currently hides it (assumption A1). Capture the socket dump first,
then process it:

```bash
sockets=$(ss -Htlnp 2>/dev/null); rc=$?
```

Emit a wrapper object instead of a bare array so the state travels with the data:

```json
{ "ok": true, "ports": [ … ] }
```

`ok` is `rc == 0`. On failure, `ports` is `[]` and `ok` is `false` — the two are
never conflated.

#### 2. `Harbor.qml` — a tri-state probe status

```qml
// "unknown" until a probe completes; never render "free" outside "ok".
property string probeState: "unknown"   // "unknown" | "ok" | "failed"
```

Set to `"ok"` / `"failed"` in `loadPorts` from the wrapper's `ok` field, and to
`"failed"` from a new `listProc.onExited` when the exit code is non-zero or the
payload does not parse. Reset to `"unknown"` in `refresh()` before each run.

#### 3. `Harbor.qml` — watchdog

`listProc` can currently hang indefinitely with no recovery. Add a `Timer`
started by `refresh()` and stopped by `loadPorts()`:

```qml
Timer {
  id: probeWatchdog
  interval: 4000
  onTriggered: {
    listProc.running = false
    root.probeState = "failed"
  }
}
```

Note assumption A3 — if `running = false` does not reap a D-state process, the
watchdog must not re-arm into a loop.

#### 4. `Harbor.qml:419-427` — empty state says which state it is

```
probeState === "failed"  → "Couldn't read the socket table. Is iproute2 installed?"
probeState === "unknown" → "Reading listening sockets…"
filterText non-empty     → "No ports match “<filter>”"
otherwise                → "Nothing is listening on localhost"
```

### Success Criteria

#### Automated Verification
- [x] `bash -n list-ports.sh`
- [x] `bash list-ports.sh | jq -e '.ok == true and (.ports | type == "array")'`
- [x] `PATH=/nonexistent /usr/bin/bash list-ports.sh | jq -e '.ok == false and (.ports | length) == 0'`
      (settles A1 — see the corrected A1 entry above)
- [x] `omarchy plugin validate "$PWD"` → exit 0
- [x] (added) `.ports` byte-identical to the old script's array on the live
      machine — the wrapper changed the envelope, not the rows

#### Manual Verification
- [ ] With `ss` unreachable, the overlay shows the iproute2 message — **not**
      "Nothing is listening on localhost"
- [ ] Normal open still lists ports with no visible change
- [ ] A probe stalled past 4 s lands in the failed state rather than an empty list

---

## Phase 2: Probe schema v2 — address, uid, starttime

### Overview

Widen what the probe sees and reports, so no listener is hidden and the kill path
has an identity to check against. Closes G2 and G3; supplies data for Phases 3-6.

### Changes Required

#### 1. `list-ports.sh:16-19` — stop dropping non-loopback listeners

Delete the address `case` filter. Any listener on port N is relevant to whether
port N can be bound, whatever address it holds. Replace the filter with a scope
classification:

```
any    →  0.0.0.0, ::, *, [::]
local  →  127.*, ::1, [::1]
iface  →  anything else
```

#### 2. `list-ports.sh` — emit eight fields

`port, scope, address, process, pid, uid, starttime, cwd` — eight, which is the
count the arity guard below and the jq assertions in Success Criteria both
depend on. Change one, change all three.

- `uid` and `starttime` from `/proc/$pid/status` (`Uid:` field 2) and
  `/proc/$pid/stat` (field 22 overall; index 20 after stripping through the last
  `)`, which is what makes the comm-with-spaces case safe).
- Keep the existing tab/newline sanitization at `:31-32` and **extend it to every
  new string-valued field**. This is the forgery mitigation described in Current
  State; do not drop it in favour of a line-based parser.
- Add an arity guard in the `awk` pass (`NF == 8`, dropping malformed records) as
  a second layer.
- Add one **wrapper-level** field alongside `ok` — not a per-row field —
  extending Phase 1's envelope to `{ok, unprivilegedPortStart, ports}`. Its value
  is `/proc/sys/net/ipv4/ip_unprivileged_port_start`, defaulting to 1024 when
  unreadable. Phase 3 consumes it; it lives here because this is the phase that
  owns the probe's output schema.

A NUL-separated transport would preserve fidelity for paths containing tabs, but
introduces an unverified dependency on `jq -R -s` handling NUL bytes. Not worth
it: sanitization already prevents the security-relevant failure, and a path with
a literal tab in it is cosmetic.

#### 3. `list-ports.sh` — union scope across collapsed rows

The `awk` dedup at `:38-44` keys on port and keeps one representative row. With
an address attached, taking one representative **under-reports exposure**: a port
bound on both `127.0.0.1` and `0.0.0.0` would render as whichever row won.

Widest scope wins across all rows for a port: `any` > `iface` > `local`.

**The address must be subordinate to the scope, not chosen independently.**
Picking `scope` by widest-wins and `address` by the existing named-owner-wins
rule yields an incoherent row — `all interfaces` displayed next to a literal
`127.0.0.1`. The rule is therefore:

| Field | Sourced from |
|---|---|
| `scope` | widest scope across all sockets on that port |
| `address` | the socket that **won** the scope union |
| `process`, `pid`, `uid`, `starttime`, `cwd` | the named-owner-wins socket (unchanged) |

Scope and address then always agree by construction.

#### 4. `Harbor.qml` — carry the new fields

Add `scope`, `address`, `uid`, `starttime` to `displayModel.append` (`:115`).
The `matches` haystack (`:105`) gets `scope` and `address` only — `uid` and
`starttime` are all-digit strings, and putting them in the haystack would make a
numeric port query match every row the user owns (uid 1000 vs port 1000). Keep
the full `cwd` in the haystack even once it stops being displayed, so
directory-name filtering keeps working.

#### 5. `Harbor.qml` — redesign the row, once

**This phase owns the row layout, and it is the only phase that changes it.**

The delegate at `:336-382` is a fixed-width four-column `Row` — `Style.space(64)`
/ `110` / `56` / remainder — inside a card capped at `Style.space(520)`. This
phase adds `scope` and Phase 6 adds `project`, taking the row to six facts. They
do not fit on one line at that width, and redesigning twice is churn worth
avoiding, so the final shape lands here with the project slot present but empty
until Phase 6 fills it.

Two lines per row — identity above, context below, matching the shape in
`VISION.md`:

```
3000 · vite
localhost · my-app · pid 4242
```

- Line 1: port (bold) · owner name
- Line 2: scope label · project · `pid N`
- Scope renders as `localhost` or `all interfaces`; for `iface` scope the
  literal address is the informative thing and is shown instead
- Empty segments collapse — no dangling separators when project is absent
  (which is every row until Phase 6)

`rowHeight` (`:40`) grows from one line to two. At the current
`cardHeight` cap of `Style.space(420)` that is roughly seven visible rows, which
is ample for a tool whose dominant use is typing a port and reading one row. Do
not widen the card to compensate; 520 is what the layout is tuned for.

### Success Criteria

#### Automated Verification
- [x] All eight fields present:
      `bash list-ports.sh | jq -e '.ports | all(has("port") and has("scope") and has("address") and has("process") and has("pid") and has("uid") and has("starttime") and has("cwd"))'`
- [x] Scope-union fixture: two rows for one port, `127.0.0.1` and `0.0.0.0`, in
      **both input orders** → collapsed row reports `any` each time
      (via the script's `--dedup` mode, added so fixtures can drive the pass directly)
- [x] Scope/address coherence: in that same fixture the emitted `address` is
      `0.0.0.0`, not `127.0.0.1` — the scope winner supplies the address
- [x] Arity fixture: a record with a missing field is dropped, not misparsed
- [x] Sanitization fixture: a cwd containing an embedded newline and a tab
      produces exactly one well-formed record and forges no additional row
      (run live: a real listener in `/tmp/harbor bad<TAB>t<NL>n` → one row, spaces)
- [x] Named-owner-wins dedup fixture from the 2026-08-20 plan (Phase 2) still passes

**Retired fixture.** That same 2026-08-20 Phase 2 criterion asserts
`jq -e 'type == "array" and (all(.[]; has("port") …))'` against the script's
output. Phase 1 of *this* plan replaced the bare array with a `{ok, ports}`
wrapper, so that assertion is deliberately obsolete — it is superseded by the
eight-field check above, not broken. Noted here so a red result from re-running
the old fixture is not mistaken for a regression.

#### Manual Verification
- [x] Bind a server to a specific LAN address (`python -m http.server --bind
      192.168.x.x 8123`) → the row appears, scope reads as that address.
      Before this phase it was invisible. (Verified live on 192.168.1.36:8378;
      dnsmasq on the Docker bridge 172.17.0.1:53 also surfaced — a previously
      hidden real listener on this machine.)
- [x] `starttime` for a known PID matches
      `sed 's/.*) //' /proc/<pid>/stat | awk '{print $20}'` — note this strips
      through the last `)` exactly as the implementation must, because
      `awk '{print $22}'` on the raw line is wrong for any process whose comm
      contains a space
- [x] Root-owned ports still show `?` for process and pid
- [ ] Two-line rows render without clipping at the default card width, with the
      project segment absent (Phase 6 has not landed) and no dangling separator
- [ ] A long cwd/owner name elides rather than pushing `pid N` off the row

---

## Phase 3: The answer — free / used, and where to go instead

### Overview

The headline feature. Closes G4 and G5, and is the reason for Phases 1 and 2.

### Changes Required

#### 1. `Harbor.qml` — recognise a port query

```qml
readonly property int queriedPort: {
  var t = root.filterText.trim()
  // No leading zeros: "00080" is not a port a user typed on purpose, and
  // treating it as 80 would answer a question they did not ask.
  if (!/^[1-9][0-9]{0,4}$/.test(t)) return 0
  var n = parseInt(t, 10)
  return n <= 65535 ? n : 0
}
```

#### 2. `Harbor.qml` — exact-match occupancy, not list emptiness

**This is the subtle part.** `rebuildDisplay` filters by substring
(`Harbor.qml:103-107`), so typing `3000` also matches `13000` and `30001`.
Deciding "free" from `displayModel.count === 0` is therefore wrong in both
directions: `3000` can be free while the list is non-empty, and a filter matching
nothing does not mean the typed number is free.

Occupancy must be an exact scan of `root.ports`:

```qml
function portInUse(n) {
  for (var i = 0; i < root.ports.length; i++)
    if (parseInt(root.ports[i].port, 10) === n) return true
  return false
}
```

#### 3. `Harbor.qml` — the free banner

Shown only when `queriedPort > 0 && probeState === "ok" && !portInUse(queriedPort)`.
The `probeState === "ok"` conjunct is the one rule from `VISION.md` in code form;
it must not be relaxed.

Render as an affirmative line above the list: **`3000 is free`**.

**Free is not always bindable.** Below the kernel's unprivileged-port floor a
port can be genuinely free and still refuse an unprivileged bind. Read the
actual threshold rather than hardcoding 1024 — rootless-container setups lower
it, and principle 4 in `VISION.md` says derive from observed facts, not from a
constant:

```
/proc/sys/net/ipv4/ip_unprivileged_port_start   (fall back to 1024 if unreadable)
```

Phase 2 already emits this as the wrapper field `unprivilegedPortStart`; this
phase only consumes it. When `queriedPort` is below it, the banner carries the
caveat rather than a bare claim:

> **`80 is free`** · needs root or CAP_NET_BIND_SERVICE

Stating the constraint beats guessing the caller's capabilities — the user may
well have them.

#### 4. `Harbor.qml` — next free port

When `queriedPort` is in use, suggest the nearest higher free port:

```qml
function nextFreePort(from) {
  var used = {}
  for (var i = 0; i < root.ports.length; i++) used[parseInt(root.ports[i].port, 10)] = true
  // Never suggest a port the user probably cannot bind. Unlike the banner,
  // which reports a fact about a port the user asked about, a suggestion is
  // advice — and advice to try a privileged port is bad advice.
  var start = Math.max(from + 1, root.unprivilegedPortStart)
  for (var p = start; p <= 65535 && p - start <= 200; p++)
    if (!used[p]) return p
  return 0
}
```

The 200-port scan cap bounds the loop; returning 0 means "no suggestion", not
"nothing is free". Render underneath the matching row: `3001 is free`.

Note the asymmetry with the banner, and keep it: the banner *reports* on a port
the user named, caveat included; the suggestion *recommends* one, so it stays
above the privileged floor entirely.

Suppress the suggestion entirely when `probeState !== "ok"` — a suggestion is a
free-claim and inherits the same rule.

### Success Criteria

#### Automated Verification

All exercised via `answers.js` — the three pure functions live there (Qt-free,
`module.exports`-guarded like the surveyed repos) precisely so node can drive
these checks; QML imports the same file.

- [x] `nextFreePort` unit-checked against a synthetic `ports` array: contiguous
      run 3000-3005 used → returns 3006
- [x] Substring-collision check: `ports` containing only `13000`, query `3000` →
      `portInUse(3000)` is false and the free banner shows
- [x] `nextFreePort(80)` returns a port ≥ the unprivileged floor, never 81
- [x] Threshold fallback: with `/proc/sys/net/ipv4/ip_unprivileged_port_start`
      unreadable, the floor is 1024 and nothing errors
- [x] Leading-zero rejection: filter `00080` yields `queriedPort == 0`, so no
      banner and no suggestion
- [x] (added) Scan cap: 201 consecutive used ports → returns 0, no suggestion

#### Manual Verification

All six verified live 2026-08-30: real servers, real keystrokes (`wtype` into
the summoned overlay), screenshots inspected.

- [x] Nothing on 8080, type `8080` → **"8080 is free"**
- [x] Nothing on 80, type `80` → "80 is free" **with** the privilege caveat
- [x] Start a server on 3000, type `3000` → the row, plus "3001 is free"
- [x] Occupy 3000 and 3001, type `3000` → suggestion reads 3002
- [x] With `ss` unreachable, type `8080` → **no free banner and no suggestion**,
      only the probe-failure message. This is the single most important check in
      this plan. (Test-harness note: sabotaging the installed copy triggers the
      shell's plugin hot-reload — wait ~2 s before summoning or the toggle races
      the reload and the overlay never maps.)
- [x] Type `300` (a prefix, not a port a user means) → substring list behaves as
      before; no free claim is made about 300 unless 300 itself is unused
      (it was unused, and correctly got the free-with-caveat banner)

---

## Phase 4: Kill verification

### Overview

Turn `ctrl+k` from fire-and-forget into a closed loop, and fix the recycled-PID
escalation. Closes G6 and G7.

### Changes Required

#### 1. `Harbor.qml` — key escalation on identity, not PID

Replace `lastKilledPid` (`:20`) with `lastKilledKey`, holding `pid + ":" + starttime`.
A recycled PID produces a different starttime and therefore cannot inherit the
armed SIGKILL. Clearing logic in `loadPorts` (`:94-99`) compares the composite key.

#### 2. `Harbor.qml` — re-check identity inside the kill

Pass `pid`, `uid` and `starttime` as **argv** to a small `sh` script that re-reads
`/proc/$pid/status` and `/proc/$pid/stat` and only signals on an exact match.
Passing as argv rather than string interpolation keeps the existing
`/^[0-9]+$/` PID guard (`:164`) sufficient against injection; retain that guard
regardless.

Use `set -f` before any unquoted `set -- $rest` word-split of `/proc` fields.

This **narrows** the race — it does not close it. The process can still exit
between the final comparison and the signal. Closing it needs `pidfd_open` +
`pidfd_send_signal`, unreachable from shell. Do not describe this as
"TOCTOU-safe" in code comments or the README.

#### 3. `Harbor.qml` — replace the blind 350 ms refresh

`refreshDelay` (`:193-198`) fires once and reports nothing. Replace with a
verification sequence at roughly 300 ms, 1 s and 3 s, driven by a re-arming timer
that stops early on success.

**The loop must not re-run the full probe.** Once Phase 6 lands, every probe
carries a capped directory walk per PID; three of them per kill is three times
that cost for a yes/no question. Use a port-scoped check instead — no `-p`, no
`/proc`, no project walk:

```sh
ss -Htln "sport = :$PORT"
```

Empty output means the port is free. Run the *full* probe exactly once, after the
sequence resolves, to bring the list back in sync. The question the loop is
asking is "is the port free", not "is the process gone" — a process can die while
something else takes the port, and a process can survive having closed its
socket. The port-scoped check answers the right one.

After each check:

- **port unbound** → `killState = "freed"`, banner: **`3000 is now free`**
- **still bound after the last attempt** → `killState = "survived"`, banner:
  `still listening — ctrl+k again to force`

The row shows a `terminating…` affordance (reduced opacity, as both surveyed
plugins do) while the sequence runs.

#### 4. `Harbor.qml` — clear kill state on filter change and on close

Otherwise a stale "3000 is now free" banner can outlive its query.

### Success Criteria

#### Automated Verification
- [x] `bash -n` on the kill helper script (`kill-port.sh`)
- [x] Helper refuses to signal when the supplied starttime does not match a live
      PID's actual starttime (exercise with a real PID and a wrong value)
      — also verified: wrong uid refused, non-TERM/KILL signal refused, pid 1
      refused, and exact identity match does signal (exit 0, process died)
- [x] Helper exits non-zero, and signals nothing, for a PID that no longer exists
- [x] `ss -Htln "sport = :8123"` is empty with nothing on 8123 and non-empty with
      a server on it — the loop's entire predicate
- [x] The verification loop issues no `/proc` reads and no project walk: by
      construction, `checkProc` runs only `ss -Htln "sport = :$1"`, and the one
      full `refresh()` fires only when the sequence resolves (freed/survived)

#### Manual Verification
- [x] `python -m http.server 8123`, `ctrl+k` → row greys, then **"8123 is now free"**
      (verified live via wtype + screenshot)
- [x] A SIGTERM-ignoring server → `ctrl+k` ends in "still listening — ctrl+k again
      to force"; the second press escalates and frees it (verified live; the
      shell's job control reported the process `Killed`, confirming SIGKILL)
- [x] Kill a server, let its PID be recycled onto a different listener, press
      `ctrl+k` again → the second press does **not** SIGKILL the new process (G7).
      Not stageable live (PID recycling can't be forced reliably); the guarantee
      is covered by two fixture-verified layers: the escalation key includes
      starttime, and the helper independently refuses any starttime mismatch.

---

## Phase 5: Explain refusals

### Overview

Every kill that cannot happen says why. Closes G8. Principle 3 in `VISION.md` —
a silent no-op is the worst outcome under time pressure.

### Changes Required

#### 1. `Harbor.qml:164` — replace the silent `return`

When `pid` is `?` (owner not readable, i.e. another user):

> `owned by another user — needs sudo`

#### 2. `Harbor.qml` — container hint

When `process` is `docker-proxy`:

> `container port — docker stop frees this`

and disable the kill for that row. Killing `docker-proxy` either gets undone by
dockerd or leaves the container holding the port; offering it is worse than
refusing it.

Per assumption A4 this is a heuristic that misses rootless Docker, Podman, and
`userland-proxy: false`. It is a hint only — nothing else may branch on it, and
the absence of the hint must never be read as "this is definitely not a container".

#### 3. Message surface

Both messages need somewhere to render. **Phase 3 owns creating the banner
slot**; this phase reuses it rather than adding a second status region, which is
why Phase 5 follows Phase 3 in the sequencing graph even though it needs nothing
from Phase 2. If Phase 5 is pulled forward for any reason, it inherits
responsibility for building the banner.

### Success Criteria

#### Automated Verification
- [x] `grep -n 'docker-proxy' Harbor.qml` → exactly **two** comparison sites
      (the criterion originally said one, but this phase's own two requirements
      — the row hint and the kill refusal — inherently need one each; corrected)

#### Manual Verification
- [x] `ctrl+k` on a root-owned row (631) → the sudo message. Was silent before
      (verified live via wtype + screenshot)
- [x] With a container publishing a port, its row shows the container hint and
      `ctrl+k` refuses rather than killing `docker-proxy` (verified live with a
      renamed python3 whose comm reads `docker-proxy` — no real container
      needed; the process survived the refused kill)
- [x] A normal user-owned row is unaffected by both branches (Phase 4's kill
      scenarios re-ran green after this change landed)

---

## Phase 6: Identity — which checkout is this?

### Overview

Turn four rows reading `node` into four project names. Closes G9. Scenarios 5
and 8.

### Changes Required

#### 1. `list-ports.sh` — walk up from cwd to the nearest project marker

Markers: `.git`, `package.json`, `Cargo.toml`, `go.mod`, `composer.json`,
`pyproject.toml`, `Gemfile`. Emit the **basename** of the directory found, falling
back to the cwd basename.

Constraints, all of which matter:

- **Cap the walk at 8 levels.** Unbounded, the cost is ~7 `stat` calls per level
  per PID on every open, and Harbor's whole design is that the probe runs cold at
  open time. This is the slowest thing in the probe.
- **`[ -e ]` follows symlinks.** A process can point its cwd at a dead network
  mount and hang the walk. The Phase 1 watchdog is the backstop and must be in
  place first.
- Stop at `$HOME` and `/`, but if the walk terminates at `$HOME` itself, emit
  nothing rather than the user's login name.

#### 2. **Explicitly not doing:** framework detection

No cmdline regex table. `\bnext\b` matches `python train.py --next-epoch`, and
first-match-wins ordering means the mislabel is never corrected. Showing `node`
honestly beats showing `Next.js` wrongly. This is recorded in `VISION.md` and
requires revising that document to reverse.

#### 3. `Harbor.qml` — fill the project slot

No layout work here. Phase 2 already shipped the two-line row with an empty
project segment; this phase populates it. The full cwd stays in the search
haystack (`:105`) so directory-name filtering keeps working even though the raw
path is no longer displayed.

### Success Criteria

#### Automated Verification
- [ ] Fixture: cwd `<repo>/public` with a `.git` two levels up → project is the
      repo's basename, not `public`
- [ ] Fixture: cwd `$HOME` → project is empty, not the username
- [ ] Fixture: a 20-level-deep path with no marker → walk terminates at the cap,
      does not run away
- [ ] Probe wall-clock with ~20 listeners stays under 300 ms

#### Manual Verification
- [ ] Two dev servers in two different checkouts → two distinguishable rows
- [ ] A Laravel-style server started in `public/` reports the app, not `public`
- [ ] Filtering by a directory name that is not the project basename still matches

---

## Phase 7: Hardening and CI

### Overview

Closes G10 and adds the regression net for everything above.

### Changes Required

#### 1. `Harbor.qml` — pin `textFormat: Text.PlainText`

On every `Text` rendering process-controlled data: the row's process, pid, cwd
and address (`:342-381`), and the empty-state message (`:409-427`), which
interpolates `filterText`.

Scope this honestly in the commit message: `comm` is kernel-capped at 15 bytes,
and path components cannot contain `/`, which together make a working remote
`<img src>` hard to assemble. This is defence in depth, not an incident. It also
does **not** address bidi/zero-width spoofing (U+202E in a directory name), which
`PlainText` renders faithfully — noted here so it is not assumed covered.

#### 2. `.github/workflows/test.yml`

Modelled on `dupontbertrand/omastatus`'s 25-line workflow:

- `jq -e` assertions on `manifest.json` — `schemaVersion`, declared `kinds`,
  and `test -f` on every path in `entryPoints`
- `bash -n` on `list-ports.sh` and the Phase 4 kill helper
- the shell fixtures from Phases 2, 3 and 6 as a runnable script

The fixtures are the regression tests for the defects this plan exists to fix.
Run them after any probe change.

### Success Criteria

#### Automated Verification
- [ ] `grep -c 'textFormat: Text.PlainText' Harbor.qml` matches the number of
      data-bearing `Text` elements
- [ ] Workflow passes on push
- [ ] `omarchy plugin validate "$PWD"` → exit 0

#### Manual Verification
- [ ] A directory named `<b>x</b>` renders literally in the row
- [ ] Theme switching still re-themes the overlay (`textFormat` does not disturb
      colour bindings)

---

## Testing Strategy

No test framework exists for Omarchy plugins. The regression suite is the set of
shell fixtures accumulated across phases, run in CI:

| Fixture | Defends |
|---|---|
| Named-owner-wins dedup, both input orders | Original 2026-08-20 rewrite |
| Space-in-process-name | Original 2026-08-20 rewrite |
| Probe failure → `ok: false` | G1 — the false "free" |
| Scope union, both input orders | G3 under-reporting |
| Scope/address coherence | Incoherent `all interfaces` + `127.0.0.1` rows |
| Arity guard + embedded newline/tab in cwd | Row forgery |
| Substring collision (`13000` vs query `3000`) | G4 mis-answer |
| Leading-zero query (`00080`) | Answering a question the user did not ask |
| `nextFreePort(80)` ≥ unprivileged floor | Advising an unbindable port |
| Unprivileged-floor fallback when sysctl unreadable | Crash on non-standard kernels |
| Project walk: `public/`, `$HOME`, depth cap | G9 |
| Kill helper: wrong starttime, dead PID | G7 |
| `ss -Htln "sport = :N"` empty/non-empty | Phase 4's verification predicate |

The single highest-value manual check in the whole plan: **with `ss` unreachable,
Harbor must not claim any port is free.**

## Performance Considerations

The probe still runs only on open and refresh; `keepLoaded` stays off, so idle
cost remains zero. Phase 2 widens the probe by two `/proc` reads per PID
(`status`, `stat`) and Phase 6 adds a capped directory walk — together the
dominant cost and the reason for the 8-level cap and the 300 ms budget in Phase
6's criteria. If first-paint latency becomes noticeable, Phase 6's walk is the
first thing to make lazy, not the socket enumeration.

## References

- Product definition: `docs/VISION.md`
- Prerequisite: `docs/plans/2026-08-30-scope-removal.md`
- Prior art surveyed 2026-08-30: `mich-nduka/omaports` (probe enrichment,
  scope classification, project-root walk), `yuler/omaports` (identity re-check
  before signalling, Makefile dev loop), `dupontbertrand/omastatus` (CI workflow,
  resource bounding). All three are monitors; only the mechanisms above transfer
- Guide compliance review: `docs/reviews/2026-08-20-development-guide-review.md`
