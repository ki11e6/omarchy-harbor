# Harbor review — the answer-machine arc

Date: 2026-08-30
Reviewed range: `c5c1a22..b026b0b` (12 commits, 15 files, +2098/-154)
Reviewed at commit: `b026b0b`
Environment: Arch (Linux 7.1.9-arch1-2), Omarchy shell at `/usr/share/omarchy/shell`,
bash 5, `ss` from iproute2, jq, node, python3

Every claim below was produced by running a command or reading the file in this
session. Where a finding is reproducible, the exact command and its real output
are pasted under it, so nothing here has to be taken on trust.

## Method

- Read the full current state of `Harbor.qml`, `BarWidget.qml`, `list-ports.sh`,
  `kill-port.sh`, `answers.js`, `test/fixtures.sh`, `test/answers-test.js`,
  `.github/workflows/test.yml`, `manifest.json`, `dev.sh`, `README.md`.
- Ran the shipped suite: `bash test/fixtures.sh`.
- Ran live reproductions against real listeners on throwaway ports
  (18391-18393 by the suite; 18499, 18501 for this review) rather than
  reasoning about `/proc` and `ss` behaviour.
- Cross-checked every `Style.*` / `Color.*` token Harbor consumes against
  `/usr/share/omarchy/shell/Commons/Style.qml`.

## Baseline: what passes

```
$ bash test/fixtures.sh
ANSWERS_TESTS_PASS
ALL_FIXTURES_PASS
(exit 0)
```

Token check — every design token the redesign introduced exists in the host shell,
so no binding silently resolves to `undefined`:

```
$ grep -n "caption\|bodySmall\|body\|title\|heading\|display" \
    /usr/share/omarchy/shell/Commons/Style.qml
327:    readonly property int caption:      ...   // 10
328:    readonly property int bodySmall:    ...   // 11
329:    readonly property int body:         ...   // 12
331:    readonly property int title:        ...   // 14
332:    readonly property int heading:      ...   // 16
333:    readonly property int display:      ...   // 24
334:    readonly property int displayLarge: ...   // 28
```

`Color.urgent` confirmed in use by the shell itself (`Commons/Border.qml:73`).

Strong work worth naming, so it does not get refactored away by someone who
misses the point:

| Mechanism | Where | Why it matters |
|---|---|---|
| `ok` envelope | `list-ports.sh:28-31, 35-38` | A failed probe and an empty machine are different answers. Defended by a fixture (`test/fixtures.sh:49`). |
| comm-safe stat parsing | `list-ports.sh:104-111`, `kill-port.sh:29-35` | `${statline##*)}` before field-splitting; a comm containing spaces or `)` cannot shift `starttime`. |
| Arity guard tied to a documented count | `list-ports.sh:45` (`NF == 9`) | The header comment states the count and both the guard and the jq assembly depend on it. Fixture at `test/fixtures.sh:38`. |
| Identity-checked signal | `kill-port.sh` whole file | pid + uid + starttime re-read from live `/proc` before signalling. Four refusal fixtures at `test/fixtures.sh:96-104`. |
| Separator sanitization + forgery fixture | `list-ports.sh:141-144`, `test/fixtures.sh:70-86` | A process controls its own comm and cwd; the fixture actually creates a `$'\t'`/`$'\n'` directory and asserts one row, not two. |
| `Text.PlainText` pinned on data-bearing text | `Harbor.qml:508, 552, 570, 657, 667, 678, 729` | Qt `AutoText` parses tag-shaped input as rich text. All process-controlled strings are pinned. |

## Confirmed issues

### 1. `ctrl+r` does not clear the refusal banner that tells you to press `ctrl+r` — MEDIUM

`Harbor.qml:265` sets:

```qml
root.refusalText = "process identity unreadable — ctrl+r to refresh"
```

`ctrl+r` routes to `refresh()`, which never touches `refusalText`:

```
$ grep -n "Key_R &&" -A 2 Harbor.qml
458:          } else if (event.key === Qt.Key_R && (event.modifiers & Qt.ControlModifier)) {
459-            root.refresh()

$ grep -n "function refresh" -A 5 Harbor.qml
157:  function refresh() {
158-    root.probeState = "unknown"
159-    listProc.running = false
160-    listProc.running = true
161-    probeWatchdog.restart()
162-  }
```

`refusalText` is only cleared by `clearKillFeedback()` (`:147`) and by the reset
at the top of `killSelected` (`:252`). `clearKillFeedback()` is called from
`open()`, `close()`, `dismiss()` and `setFilter()` — **not** from `refresh()`:

```
$ grep -n "clearKillFeedback()" Harbor.qml
115:    root.clearKillFeedback()      # open()
133:    root.clearKillFeedback()      # close()
138:    root.clearKillFeedback()      # dismiss()
144:  function clearKillFeedback() {
230:    root.clearKillFeedback()      # setFilter()
```

So the banner survives the exact remedy it prescribes. The same applies to the
other two refusals (`:257`, `:261`).

**Do not fix by calling `clearKillFeedback()` inside `refresh()`.** `applyVerify`
sets the outcome and *then* refreshes (`:392-393`, `:398-399`), so that would wipe
the "3000 is now free" banner a moment after showing it. Clear `refusalText` at
the `ctrl+r` key handler instead, or give `refresh()` a `userInitiated` parameter.

### 2. `enter` and `ctrl+y` hardcode `localhost` for interface-bound rows — MEDIUM

`Harbor.qml:239` and `:246`:

```qml
Quickshell.execDetached(["xdg-open", "http://localhost:" + row.port])
Quickshell.execDetached(["wl-copy", "localhost:" + row.port])
```

`f6df3a9` deliberately surfaces `iface`-scope rows, because a listener on
`192.168.1.5:3000` still blocks a `0.0.0.0:3000` bind. But such a listener has
nothing on loopback, so Enter opens a URL that cannot connect. Reproduced live:

```
$ ip=$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | head -1)
$ echo $ip
192.168.1.36
$ (exec python3 -m http.server --bind "$ip" 18501) & sleep 1

$ bash list-ports.sh | jq -c '.ports[] | select(.port=="18501")'
{"port":"18501","scope":"iface","address":"192.168.1.36","process":"python3",
 "pid":"590650","uid":"1000","starttime":"1399442","project":"omarchy-harbor",
 "cwd":"/home/cybersamurai/Projects/omarchy-harbor"}

$ curl --max-time 3 http://localhost:18501
localhost:18501 -> HTTP 000 / Failed to connect to localhost:18501: Could not connect to server
$ curl --max-time 3 http://192.168.1.36:18501
192.168.1.36:18501 -> HTTP 200
```

The row already carries `address` and the delegate already computes `scopeLabel`
from it (`:610-612`). Fix: use `row.address` when `row.scope === "iface"`, keep
`localhost` for `local` and `any`.

### 3. Kill-verify can attribute one row's result to another row — LOW (narrow race)

`killSelected` (`Harbor.qml:249-280`) resets `killPort`, `killState` and
`verifyAttempt`, and restarts `killProc` — but never stops the verification
sequence that may already be in flight for a previous row:

```
$ grep -n "function killSelected" -A 32 Harbor.qml | grep "verifyTimer\|checkProc"
(no matches)
```

Sequence: ctrl+k on row A arms `verifyTimer` (300ms) and `checkProc` for port A.
Inside that window, ctrl+k on row B sets `killPort = B`, `killState =
"terminating"`. A's `checkProc` then completes and calls `applyVerify` (`:389`),
which passes the `killState === "terminating"` guard and — if port A is now free
— sets `killState = "freed"`. The banner reads `killPort`, so it announces
**"B is now free"** while B may still be alive.

Fix: `verifyTimer.stop()` and `checkProc.running = false` alongside the state
reset in `killSelected`.

### 4. `applyVerify` cannot distinguish "ss failed" from "port is free" — LOW

`Harbor.qml:389-395` treats empty stdout as proof of a freed port:

```qml
function applyVerify(out) {
  if (root.killState !== "terminating") return
  if (String(out || "").trim() === "") {
    root.killState = "freed"
```

`checkProc` (`:380-387`) has no `onExited` exit-code guard, unlike `listProc`
which explicitly has one (`:334-336`). Both a free port and a failed `ss`
produce identical empty stdout:

```
$ sh -c 'ss -Htln "sport = :$1"' harbor-verify 18599     # genuinely free port
stdout=[]  exit=0

$ PATH=/nonexistent /usr/bin/sh -c 'ss -Htln "sport = :$1"' harbor-verify 22
stdout=[]  exit=127

$ sh -c 'ss -Htln "sport = :$1"' harbor-verify 53        # control: real listener
LISTEN 0 4096      127.0.0.54:53 0.0.0.0:*
LISTEN 0 4096      172.17.0.1:53 0.0.0.0:*
LISTEN 0 4096   127.0.0.53%lo:53 0.0.0.0:*
```

The control run confirms the verify command itself is correct — the gap is purely
the missing exit-code check. This is the same conflation the `ok` envelope in
`list-ports.sh:28-31` was built to prevent, so it is an inconsistency with the
project's own stated invariant more than a likely field failure (if `ss` were
missing, the probe would already have failed and there would be no row to kill).

Fix: check `exitCode` on `checkProc` and treat non-zero as inconclusive
(`survived`, or a distinct "couldn't verify" tone).

### 5. A deleted working directory leaks `(deleted)` into the project name — LOW

`list-ports.sh:101` takes `readlink` output verbatim. The kernel appends
` (deleted)` for an unlinked cwd, the marker walk then cannot match anything
under the dead path, and the basename fallback (`:133-135`) carries the suffix
into the user-visible project name. Reproduced live:

```
$ mkdir -p /tmp/harbor-del/gone && cd /tmp/harbor-del/gone \
    && (exec python3 -m http.server 18499) & sleep 1
$ rmdir /tmp/harbor-del/gone
$ readlink /proc/$p/cwd
/tmp/harbor-del/gone (deleted)

$ bash list-ports.sh | jq -c '.ports[] | select(.port=="18499")'
{"port":"18499","scope":"any","address":"0.0.0.0","process":"python3",
 "pid":"581148","uid":"1000","starttime":"1374590",
 "project":"gone (deleted)",
 "cwd":"/tmp/harbor-del/gone (deleted)"}
```

`"project": "gone (deleted)"` is what the row would display. Cosmetic, but it
undercuts the "named by project" promise in exactly the situation (a rebuilt or
moved checkout) where a dev server is most likely to be orphaned.

Fix: strip a trailing ` (deleted)` after the `readlink` at `list-ports.sh:101`,
before the marker walk runs.

### 6. README describes a row format the delegate does not render — LOW

`README.md:34`:

> **Named by project** — rows read `3000 · node / my-app`, resolved by walking …

The delegate renders two lines (`Harbor.qml:631-684`): line one is a scope dot,
then port, then process; line two is `contextLine` (`:616-623`), which joins
project, scope label and pid with ` · `. Actual output for a real row is closer
to:

```
● 3000  node
  my-app · localhost · pid 1234
```

Fix: update the README sample to the two-line shape introduced by `f6df3a9` /
`ebee177`.

## Minor notes (not issues)

- **`exec kill` needs an external `kill`.** `kill-port.sh:40` uses
  `exec kill -s "$sig" "$pid"`; `exec` bypasses the bash builtin and searches
  PATH. Verified present here (`/usr/bin/kill`, util-linux, 34976 bytes), so this
  is fine on Arch/Omarchy. Recorded because if it were ever absent the kill would
  no-op and surface to the user as "still listening" — a confusing failure mode
  for a missing binary.
- **`Keycap` reaches model data through `parent.parent`.** `Harbor.qml:303`
  (`text: parent.parent.keys`) resolves correctly today (Text → Rectangle → the
  component's root Row), but this is the exact `parent.parent` fragility that
  issue 3 of the 2026-08-20 review had removed from the list delegate. An `id` on
  the component root would keep it inert to wrapper insertion.
- **Bar tooltip binding is read once.** `BarWidget.qml:41-49` runs
  `hyprctl binds -j` at bar load with no polling — correct for the stated
  zero-idle-cost goal, but a changed keybinding needs a shell restart before the
  tooltip catches up. Worth one README line next to the binding instructions.
- **`answers.js` dual-export trick works.** `module.exports` guarded at `:40`;
  QML's `.js` import ignores it and `node test/answers-test.js` drives the same
  file. Confirmed by the passing suite.

## Suggested order of work

1. Issue 2 (`localhost` on `iface` rows) — the only finding that hands the user a
   broken action on a row Harbor deliberately chose to show.
2. Issue 1 (`ctrl+r` refusal banner) — a message that outlives its own remedy,
   in the one flow that runs under time pressure.
3. Issue 3 (`verifyTimer.stop()`) — one line, removes a wrong-port claim.
4. Issue 4 (`checkProc` exit code) — restores the `ok`-envelope invariant.
5. Issues 5 and 6 — polish and doc accuracy.

## Not covered by this review

- No live exercise of the redesigned overlay in a running shell. Everything here
  is source reading plus scripted reproduction of the shell/probe layer; the
  visual claims of `ebee177`/`b026b0b` (hero banner sizing, card height
  animation, keycap row, new `preview.png`) were not verified against a
  running compositor. `./dev.sh` followed by manual exercise still needed.
- `docs/plans/2026-08-30-port-answer-machine.md` was not audited against the
  implementation; its Testing Strategy table is cited by `test/fixtures.sh:4-5`
  as the mapping from fixture to defect, and that mapping was taken at face value.
- No qmllint pass this round (the `qs` symlink setup from the 2026-08-20 review
  was not reconstructed), so the redesign's ~200 new QML lines have not been
  checked for new unqualified-access warnings.

---

## Addendum — all findings fixed (2026-08-30, same day)

Every issue above was fixed and re-verified live in a running shell.

| # | Fix | Verified by |
|---|-----|-------------|
| 1 | `refusalText` cleared at the `ctrl+r` key handler (not inside `refresh()`, exactly per the review's warning); outcome banners deliberately survive a manual refresh | Live: 631 refusal → `ctrl+r` → ordinary taken-answer banner (screenshots) |
| 2 | `rowHost(row)`: `address` for `iface` scope, brackets for IPv6 literals, `localhost` otherwise; used by both `enter` and `ctrl+y` | Live: clipboard received `192.168.1.36:18501` from an iface row and `localhost:18502` from an any row |
| 3 | `verifyTimer.stop()` + `checkProc.running = false` in `killSelected` | Code; race not stageable deterministically |
| 4 | `checkProc` reports via `onExited(exitCode, stdout)`; non-zero exit → `survived` — never a free-claim on silence | Live: normal kill still ends in "8123 is now free" (exit-0 path); fixture-level `ss` behavior from the review stands |
| 5 | ` (deleted)` stripped after `readlink`, **before** the marker walk, so live ancestors still resolve the project | New fixture: server on 18394 in a deleted dir under a `.git` parent → `project == "del"`, no `(deleted)` in cwd |
| 6 | README row sample now shows the two-line shape | — |
| minor | Keycap children reference the component root by `id`; README notes the tooltip binding is read once per bar load | — |

### Two additional defects found while verifying (not in the review)

- **`ctrl+y` was broken in general, not just for iface rows.** Argv-style
  `Quickshell.execDetached(["wl-copy", text])` dies silently in this
  environment. The shell's own plugins pipe instead —
  `bash -c "printf %s <quoted> | wl-copy"` (network `Panel.qml:450`,
  tailscale `Service.qml:109`). Harbor now follows that pattern.
- **Dismiss-before-exec no longer survives plugin unload.** The 2026-08-20
  review verified that an `execDetached` queued after `dismiss()` still runs;
  on the current shell it does not. Both `openSelected` and `copySelected`
  now exec first and dismiss after. The 2026-08-20 note is superseded.

### Test-harness caveat

After a `dev.sh` rsync, hot reload can leave one per-monitor overlay instance
on a stale compilation (TypeError on newly added functions) while the other
runs the new code. A full `omarchy-restart-shell` resolves it; remember this
before debugging "impossible" journal errors during development.
