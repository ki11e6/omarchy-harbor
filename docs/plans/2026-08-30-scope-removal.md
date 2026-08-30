# Harbor — Scope Removal Plan

## Overview

Harbor shipped with two behaviours carried over from its portboard ancestor that
do not serve the product defined in `docs/VISION.md`: a hardcoded port allowlist
that silently changes what the Enter key does, and a hint bar that advertises a
browsing action ahead of the two actions the tool exists for.

This plan removes them. It is deliberately small and behaviour-only — no probe
changes, no new features. Those are in
`docs/plans/2026-08-30-port-answer-machine.md`, which assumes this plan has
landed.

## Current State Analysis

Verified by reading the source in this session (2026-08-30):

- `Harbor.qml:24-25` defines `nonHttpPorts`, a 9-entry map
  (`22, 25, 53, 111, 631, 3306, 5432, 6379, 27017`).
- `Harbor.qml:144-152` (`openSelected`) branches on that map: Enter copies
  `localhost:<port>` for those nine ports and runs
  `xdg-open http://localhost:<port>` for every other port.
- `Harbor.qml:302` renders the hint bar:
  `"enter open · ctrl+y copy · ctrl+k kill · ctrl+r refresh · esc close"`.
- `README.md:15` documents the conditional Enter, naming all nine services.
- `manifest.json:8` describes the plugin as
  `"Enter opens/copies, ctrl+y copies, ctrl+k kills."`

### Why the allowlist goes

It is an invisible table that decides what a key does (principle 4 in
`VISION.md`). Nine entries out of 65,535 ports means the common cases it is
meant to catch — Kafka on 9092, Elasticsearch on 9200, gRPC on 50051, MinIO on
9000 — are all missed, so Enter launches a browser tab at a binary protocol
anyway. The table does not make the behaviour correct; it makes it
*unpredictable*, which is worse. The same keystroke doing two different things
based on a lookup the user cannot inspect is the failure mode, not the coverage
gap.

Deleting it makes Enter unconditional. The failure it reintroduces for those
nine ports — a browser tab at Postgres — is trivially recoverable and, crucially,
*expected*.

**This table must not come back.** If HTTP-vs-not detection is wanted later it
has to be derived from the observed process identity (Phase 6 of the additions
plan gives us that), never from a port allowlist.

### Why the hint bar is re-ordered, not just trimmed

The hint bar is the only place Harbor teaches its own keys, and it currently
leads with the browsing action. Under the vision the two exits are `ctrl+k`
(free it) and — once Phase 3 of the additions plan lands — reading the suggested
free port. `ctrl+y` stays bound because it costs nothing, but it should not
consume prime space.

## Desired End State

- Enter always runs `xdg-open http://localhost:<port>`. No branch, no table.
- `ctrl+y` still copies; it is no longer in the hint bar.
- README and manifest describe the actual behaviour.
- `docs/VISION.md` is the referenced authority for why the table is gone, so a
  future contributor reading `git log` finds the reasoning rather than
  re-deriving it.

## What We're NOT Doing

- Not making Enter destructive. `ctrl+k` remains the only kill path. Whether
  Enter should eventually become the kill is a question to revisit *after* the
  answer states exist, not now.
- Not removing `BarWidget.qml` or the `bar-widget` kind. The button is
  stateless, polls nothing, and per the 2026-08-20 review (issue 1 / addendum
  A1) the bar entry doubles as the plugin's enable flag — there is no
  overlay-only install. It stays. It must never grow a live count.
- Not touching `list-ports.sh`, the probe contract, or the kill path.
- Not removing the `Configuration: None` README section. It is accurate, closes
  a dev-guide checklist item, and is now a stated product position rather than
  an omission.

---

## Phase 1: Unconditional Enter

### Changes Required

#### 1. `Harbor.qml` — delete `nonHttpPorts`

Remove lines 22-25 in full, including the comment.

#### 2. `Harbor.qml` — collapse `openSelected` (lines 144-152)

```qml
function openSelected() {
  if (root.selectedIndex < 0 || root.selectedIndex >= displayModel.count) return
  var row = displayModel.get(root.selectedIndex)
  root.dismiss()
  Quickshell.execDetached(["xdg-open", "http://localhost:" + row.port])
}
```

Note the ordering is load-bearing and must be preserved: `dismiss()` destroys
the overlay item synchronously (no `keepLoaded`), and the 2026-08-20 review
confirmed with a Quickshell harness that the following `execDetached` still runs
because the JS frame survives its own object's destruction.

#### 3. `Harbor.qml:302` — hint bar

```qml
text: "enter open · ctrl+k kill · ctrl+r refresh · esc close"
```

`ctrl+y` remains bound at `Harbor.qml:252-254`; only the advertisement is
dropped.

### Success Criteria

#### Automated Verification
- [ ] `omarchy plugin validate "$PWD"` → exit 0
- [ ] `grep -c nonHttpPorts Harbor.qml` → 0
- [ ] qmllint warning-category profile unchanged from the pre-change baseline
      (use the `qs` → `shell` symlink setup documented in the 2026-08-20 review;
      the guide's own `-I` invocation cannot resolve `qs.Ui` / `qs.Commons`)

#### Manual Verification
- [ ] `./dev.sh`, then filter `631` and press Enter → a browser opens (previously
      this copied). Confirms the branch is gone.
- [ ] Filter a dev-server port and press Enter → browser opens as before.
- [ ] `ctrl+y` still copies `localhost:<port>` despite not being in the hint bar.
- [ ] Hint bar renders on one line at the default card width without eliding.

---

## Phase 2: Documentation truthfulness

### Changes Required

#### 1. `README.md:15` — keys table

Replace the conditional-Enter row with:

| Key | Action |
|-----|--------|
| `enter` / click | Open `http://localhost:<port>` in the browser |

Delete the parenthetical listing the nine services.

#### 2. `manifest.json:8` — description

Drop `opens/copies`:

```
"Summonable overlay of listening localhost ports with owning process and cwd. Enter opens, ctrl+y copies, ctrl+k kills."
```

#### 3. `README.md` — link the vision

Add one line under the opening description so the product definition is
reachable from the entry point:

```markdown
See [docs/VISION.md](docs/VISION.md) for what Harbor is for and what it
deliberately does not do.
```

### Success Criteria

#### Automated Verification
- [ ] `omarchy plugin validate "$PWD"` → exit 0 (manifest description changed)
- [ ] `! grep -n 'copies the address\|non-HTTP' README.md`
- [ ] `grep -q 'docs/VISION.md' README.md`

#### Manual Verification
- [ ] README keys table matches actual key handling in `Harbor.qml:238-268`,
      read side by side.

---

## Testing Strategy

No test framework exists for Omarchy plugins; verification is the per-phase
criteria above. The behavioural change is small enough to confirm by exercising
Enter on one allowlisted port (`631`) and one non-allowlisted port — those two
cases are the entire diff in observable behaviour.

## Rollback

Both phases are additive-free deletions confined to `Harbor.qml`, `README.md`
and `manifest.json`. `git revert` restores the previous behaviour with no state
or migration to unwind.

## References

- Product definition: `docs/VISION.md`
- Where the allowlist came from: `docs/plans/2026-08-20-harbor-initial-implementation.md`
  Phase 3, item 2 ("Smart Enter")
- Bar-widget mandatory-enable finding: `docs/reviews/2026-08-20-development-guide-review.md`
  issue 1 and addendum A1
