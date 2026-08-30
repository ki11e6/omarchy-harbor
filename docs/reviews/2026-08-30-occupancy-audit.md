# Harbor review — the occupancy audit

Date: 2026-08-30
Reviewed at commit: `540890d`
Environment: Arch (Linux 7.1.9-arch1-2), Omarchy shell at `/usr/share/omarchy/shell`,
bash 5, `ss` from iproute2, jq, node, python3

Prompted by a question about the banner in `preview.png`: *how does Harbor know
3001 is free when you ask about 3000?* It does not probe 3001 — it reads one
socket table and does set arithmetic on the snapshot. That is a reasonable
design, but it makes every answer only as wide as the table. This review asks
what the table leaves out.

## Method

Same standard as the answer-machine review: every claim below was produced by
running a command in this session. Where a finding is reproducible, the command
and its real output are pasted under it. Live reproductions used throwaway ports
(45321-45323, 45400-45401, 18601) and real sockets rather than reasoning about
`ss` behaviour.

Baseline before any change:

```
$ bash test/fixtures.sh
ANSWERS_TESTS_PASS
ALL_FIXTURES_PASS
(exit 0)
```

## Confirmed issues

### 1. Non-LISTEN sockets are invisible, so a held port answers "free" — HIGH

`ss -tln` reports only LISTEN. A socket in any other live state holds its port
just as completely:

```
$ # 45321 pinned as the source port of an outbound connection
harbor's view   ss -Htln sport=:45321  ->  exit=0 stdout=''
reality         ss -Htan sport=:45321  ->  ESTAB 127.0.0.1:45321 127.0.0.1:37671
list-ports.sh reports port 45321: ABSENT -> Harbor answers 'free'
RESULT: bind 0.0.0.0:45321   FAILED -> [Errno 98] Address already in use
RESULT: bind 127.0.0.1:45321 FAILED -> [Errno 98] Address already in use
```

`VISION.md:133-134` waved this class away on the grounds that `SO_REUSEADDR`
defeats `TIME_WAIT`. That is true of `TIME_WAIT` and only of `TIME_WAIT`:

```
$ # ESTABLISHED holder, client sets SO_REUSEADDR before bind
SO_REUSEADDR bind 0.0.0.0:45322   -> FAILED [Errno 98] Address already in use
SO_REUSEADDR bind 127.0.0.1:45322 -> FAILED [Errno 98] Address already in use

$ # control: TIME_WAIT holder, same option
bind reuse=False -> FAILED [Errno 98] Address already in use
bind reuse=True  -> SUCCEEDED
```

**This compounds with issue 2.** `nextFreePort` recommended into 32768-60999 —
precisely where outbound sockets live. End to end, following Harbor's own advice:

```
probe sees 45400: yes
probe sees 45401: no
BANNER WOULD READ:  45400 is taken - 45401 is free
acting on the advice: bind 45401 -> [Errno 98] Address already in use
```

Harbor produced the exact error it exists to prevent. Worst possible outcome
against design principle 1.

### 2. Suggestions respected the floor but not the ceiling — MEDIUM

`answers.js:32` floored at `unprivilegedPortStart` and never read
`ip_local_port_range` (32768-60999 here):

```
query 40000 taken -> suggests 40001   <-- INSIDE ephemeral range
query 32768 taken -> suggests 32769   <-- INSIDE ephemeral range
query 50000 taken -> suggests 50001   <-- INSIDE ephemeral range
```

The floor was already derived from an observed sysctl (principle 4). The ceiling
is an equally observable fact that was simply not read.

### 3. `rowHost` sent every `local` row to `localhost`, but `local` spans all of 127.* — MEDIUM

`Harbor.qml:238-241` returned `"localhost"` unless `scope === "iface"`, while
`list-ports.sh:89` classifies `127.*` and `::1` as `local`. Reproduced:

```
$ bash list-ports.sh | jq -c '.ports[]|select(.port=="18601")'
{"port":"18601","scope":"local","address":"127.0.0.2","process":"python3",...}

$ curl --max-time 3 http://localhost:18601
HTTP 000 (Could not connect to server)
$ curl --max-time 3 http://127.0.0.2:18601
HTTP 200
```

Not hypothetical on a stock box — `ss` on this machine during the review:

```
LISTEN 0 4096      127.0.0.54:53   0.0.0.0:*
LISTEN 0 4096   127.0.0.53%lo:53   0.0.0.0:*
```

This is issue 2 of the answer-machine review, fixed for `iface` and left open
for `local`. It recurred because the fix lived in QML, which the harness cannot
reach — so the fix here moves the function into `answers.js` and covers it.

### 4. `BarWidget` had no `ok` envelope — LOW

`BarWidget.qml:41-49` never checked `bindsProbe`'s exit code, and `loadBinds`
swallowed a parse failure into `binds = []`. Any failure — `hyprctl` missing,
non-Hyprland session, malformed JSON — reached `bindLabel = ""`, and the tooltip
then asserted **"No keybinding set — add one in ~/.config/hypr/bindings.lua"**.
A definitive negative claim resting on a probe that never ran: the same
conflation `list-ports.sh` built its `ok` envelope to prevent, absent from the
other half of the plugin.

### 5. `killState === "terminating"` had no banner — LOW

The `banner` chain handled `freed` and `survived` but fell through on
`terminating`, so for the ~300ms-3s verify window the answer zone kept showing
the pre-kill answer while only the dimmed row indicated anything had happened.

### 6. `checkProc` ignored `exitStatus` — LOW

`onExited: function(exitCode)` took the code alone. Analysis says Qt sets
`exitCode` to the signal number on a signal death, so the cancellation path in
`killSelected` should already land on the safe `survived` branch — but that
rests on Qt internals rather than on the contract, and `exitStatus` is the
field that actually states it. Not reproduced against a running shell.

## Fixes

| # | Fix | Verified by |
|---|-----|-------------|
| 1 | Probe reads `ss -Htanp`; `-l` reapplied as a loop filter so only listeners pay the `/proc` walk. New `occupied` array carries every port held in a non-`TIME-WAIT` state; `occupancy()` unions it with the row table. | Live: 45401 now in `occupied`, absent from `ports`. Compound scenario now reads "45400 is taken — 61000 is free" and `bind 61000 SUCCEEDED`. New fixture at `test/fixtures.sh`, negative-control checked against the old flags. |
| 2 | `ephemeralStart`/`ephemeralEnd` read from `ip_local_port_range`; `nextFreePort` jumps the range, reports carry a caveat inside it. Unreadable range → `0/0` → no claim, old behaviour. | Unit checks incl. the jump, the cross-into-range case, and the range-reaches-65535 case. Live: unreadable-range probe emits `0/0` and falls back to a plain scan. |
| 3 | `rowHost` → `Answers.hostFor(row)`, branching on the address: only a wildcard bind or `127.0.0.1` is `localhost`, IPv6 bracketed. | 11 unit assertions incl. `127.0.0.2`, `127.0.0.53`, `::1`, absent address. |
| 4 | `bindState` tri-state; `loadBinds` treats a non-array payload as failure; `onExited` guards the exit code. The nudge is shown only on `"ok"`. | Inputs live: `hyprctl binds -j` exits 0, one Harbor bind (`modmask=72 key=P`) → `bindState "ok"`, label `SUPER+ALT+P`. Tooltip not hovered. |
| 5 | `terminating` branch added to `banner`. | Live, screenshotted: `8123 terminating…` mid-kill, then `8123 is now free`. |
| 6 | `onExited: function(exitCode, exitStatus)`; non-normal status is inconclusive → `survived`. | Rapid double-kill on two rows produced a true claim (`8202 is now free`, both ports confirmed free). The misattribution window was not provably entered. |

### 7. `scopeLabel` still said "localhost" for a `127.0.0.2` bind — found by running it

Not visible in source review. With issue 3 fixed, `ctrl+y` copied `127.0.0.2:3100`
while the row above it read `harbor-live · localhost · pid 760155` — the action
was corrected and the label was not, so the UI contradicted itself. `scopeLabel`
branched on `scope`, which lumps all of `127.*` into `local`. It now applies the
same `hostFor` rule. Verified live after reinstall:

```
● 631  ?         localhost        <- 127.0.0.1, still "localhost"
● 3000 python3   all interfaces   <- wildcard
● 3100 python3   127.0.0.2        <- fixed
● 53   ?         172.17.0.1       <- docker bridge
```

Docs: `VISION.md` "Known limits" now separates the row table from the occupancy
set, states `TIME-WAIT`-as-free as the deliberate exception, and lists both
ranges where "free" is not a promise. `README.md` updated for the new probe
flags, the occupancy rule, the suggestion bar, and the `enter`/`ctrl+y` host.

## Verification

```
$ bash test/fixtures.sh   (x3 consecutive)
ANSWERS_TESTS_PASS
ALL_FIXTURES_PASS
(exit 0)
```

Run three times back to back: the first draft of the 18395 fixture left a
`TIME-WAIT` behind that failed the next run's precondition. The precondition now
asks the same question `occupied` asks (every state but `TIME-WAIT`) and the
fixture's client sets `SO_REUSEADDR`.

qmllint, with the `qs` symlink reconstructed against `/usr/share/omarchy/shell`:

```
BEFORE (HEAD):  errors=0  warnings=63
AFTER  (work):  errors=0  warnings=64
```

The one added warning is `QProcess::ExitStatus ... was not found`, already
present on both pre-existing `onExited` handlers — qmllint cannot resolve the
enum here. The host shell uses the same two-parameter signature
(`Ui/MultiSelect.qml:244`).

## Live exercise

Installed with `./dev.sh` onto a running Omarchy session (Hyprland 0.56.2) and
driven with real listeners, `wtype` keystrokes and `grim` captures. Every
screen below was read, not assumed.

| Case | Staged | Overlay said | Ground truth |
|---|---|---|---|
| Occupancy (issue 1) | listener on 3000, ESTABLISHED-only holder on 3001 | **3000 is taken — 3002 is free** | 3001 skipped; pre-fix it read "3001 is free" and the bind failed |
| Ephemeral caveat (issue 2) | nothing on 45999 | **45999 is free** / *in the kernel's outbound port range — a connection can claim it* | `ss` clean, port inside 32768-60999 |
| Ephemeral suggestion (issue 2) | listener on 45400 | **45400 is taken — 61000 is free** | jumped the whole range |
| Host (issues 3, 7) | listener on `127.0.0.2:3100` | row `127.0.0.2`, `ctrl+y` → `127.0.0.2:3100` | `curl localhost:3100` → 000, `curl 127.0.0.2:3100` → 200 |
| Kill (issue 5) | `http.server` on 8123 | **8123 terminating…** → **8123 is now free** | 0 listeners after |
| Survivor + escalation | server ignoring SIGTERM on 8124 | **8124 still listening** / *ctrl+k again to force* → 2nd `ctrl+k` → **8124 is now free** | alive after TERM, gone after KILL |
| Refusal + `ctrl+r` | port 631 (CUPS, root-owned) | **owned by another user** / *needs sudo*, then `ctrl+r` → **631 is taken — 1024 is free** | CUPS untouched; suggestion respects the floor |
| Exact-vs-substring | listeners on 8201, 8202 | filter `820` lists both, banner answers **820 is free** | the display filter is substring, the answer is not |

Shell journal over the whole session: hot-reload debug lines only — no QML
errors, no `TypeError`, no binding loops.

One observed behaviour that is not a defect: a listener started while the
overlay was already open did not appear until `ctrl+r`. The probe runs at open
and on refresh by design (principle 2, "cold and certain over warm and stale").

## Not covered by this review

- The bar tooltip was not hovered; only its inputs were verified.
- The issue-6 misattribution window was not provably entered — the rapid
  double-kill produced a true claim, which is a pass but not a proof.
- `ip_local_reserved_ports` is not read. Ports listed there are excluded from
  ephemeral allocation, so treating them as ephemeral is conservative — a
  suggestion Harbor could safely make and does not. Empty on this machine.
- The kill verify deliberately stays on `ss -Htln`, unlike the occupancy probe.
  Killing a listener leaves its accepted connections in `TIME-WAIT` on the same
  port, and `-a` would read those as a survivor. The reasoning is recorded at
  the call site but was not staged as a test.
- Network namespaces. A listener inside a container's own netns is invisible to
  both halves of the probe; `docker-proxy` on the host is what Harbor sees.
