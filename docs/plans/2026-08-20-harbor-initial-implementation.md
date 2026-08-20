# Harbor — Initial Implementation Plan

## Overview

Harbor (`io.github.ki11e6.harbor`) is an Omarchy shell overlay listing every listening
localhost TCP port with its owning process, PID, and working directory. It is a
ground-up rewrite of [omarchy-portboard](https://github.com/SVIGHNESH/omarchy-portboard)
(reviewed 2026-08-20, clone at `~/omarchy-portboard`) that fixes the issues found in
review and applies the agreed design changes.

## Current State Analysis

The portboard source was read fully and validated on this machine
(`omarchy plugin validate` → exit 0; `list-ports.sh` produces correct JSON).
Structure: `manifest.json`, `Portboard.qml` (overlay), `list-ports.sh` (JSON port
lister), `bin/portboard` (fzf fallback CLI), README, LICENSE, preview.png.

### Key Discoveries

- Overlay plugins receive `shell` and `manifest` context properties; `manifest.__sourceDir`
  is stamped in by the shell (`/usr/share/omarchy/shell/services/PluginRegistry.qml:564`),
  which is how the QML locates its helper script (`~/omarchy-portboard/Portboard.qml:35-37`).
- `omarchy-shell shell toggle <id>` works for lazily-loaded plugins:
  `toggle()` routes through `summon()` (`/usr/share/omarchy/shell/shell.qml:510-513`),
  which queues the payload in `pendingPayloads` and delivers it on `Loader.onLoaded`
  (`shell.qml:440-478`). The stock `bindings.lua:29` example uses `toggle`.
- Without `keepLoaded`, the plugin Loader is only active while summoned
  (`shell.qml:625`) — the overlay reloads fresh each open. Desirable here (fresh
  port list, no idle cost), so Harbor deliberately omits `keepLoaded`.
- Theming/conventions to copy come from `omarchy.emojis`
  (`/usr/share/omarchy/shell/plugins/emojis/Emojis.qml`): `Color.menu.*` tokens
  (`Commons/Color.qml:98-99`), `Border.surfaceSpec` (`Commons/Border.qml`),
  `BorderSurface` content insets (`Ui/BorderSurface.qml:11-21`), the
  `open/close/toggle/dismiss` function contract, and `shell.hide(id)` on dismiss.
- Built-in overlays show a large icon glyph in their empty state
  (`emojis/Emojis.qml:318-326`, `clipboard/Clipboard.qml:585-593`); portboard's is
  text-only (`Portboard.qml:339-353`).

### Verified defects in portboard (all reproduced this session)

1. Non-namespaced plugin ID `svighnesh.portboard` (`manifest.json:3`, `Portboard.qml:54`,
   `README.md:30,49`) — guide and installed third-party plugins use `io.github.<user>.<name>`.
2. `sort -un -t$'\t' -k1,1` (`list-ports.sh:31`) keeps an **input-order-dependent** row
   when a port has two owners — proven empirically with two-row fixtures in both orders.
3. Process names containing spaces break the whitespace-split `read` so the
   `users` regex never matches — proven empirically with a simulated `ss` line.
   Root cause: the trailing `_` in `read -r _ _ _ local _ users _`
   (`list-ports.sh:9`) truncates `users` to field 6 only.
4. `kill {3}` in the fzf CLI (`bin/portboard:59`) shell-globs when PID is `?`.
5. `jq` dependency (`list-ports.sh:32`) undocumented; no `license` field in manifest.
6. Hint bar (`Portboard.qml:245`) omits navigation/esc keys.
7. Enter always opens `http://localhost:<port>` (`Portboard.qml:112`), even for
   non-HTTP services (postgres, DNS).

## Desired End State

A publishable plugin at `~/Projects/omarchy-harbor` that:

- passes `omarchy plugin validate`,
- is installable via `omarchy plugin add https://github.com/ki11e6/omarchy-harbor --enable`,
- summons via `omarchy-shell shell toggle io.github.ki11e6.harbor`,
- lists ports deterministically (named owner preferred over `?`), survives
  space-containing process names,
- Enter opens HTTP ports in the browser and copies `localhost:<port>` for known
  non-HTTP ports; ctrl+y always copies; ctrl+k escalates TERM → KILL,
- looks native (menu theme tokens, empty-state icon, complete hint bar).

## What We're NOT Doing

- No fzf/terminal fallback CLI (portboard's `bin/portboard` is dropped entirely).
- No UDP sockets, no non-loopback interfaces, no config file/options.
- No `keepLoaded`, no bar-widget kind, no port probing/HTTP detection.

## Implementation Approach

Clone the emojis overlay conventions (as portboard did — that part was right),
keep the two-file architecture (QML presentation + standalone bash lister), fix
the lister's parsing/dedup, and extend the QML with the three behavior changes
(smart Enter, copy action, kill escalation). Dev loop: `./dev.sh` rsyncs the repo
into `~/.config/omarchy/plugins/io.github.ki11e6.harbor/` (copies, not symlinks —
the guide forbids symlinks) and runs `omarchy-restart-shell`.

---

## Phase 1: Scaffold

### Overview
Repo skeleton: manifest, license, dev loop script. After this phase the (empty)
plugin validates and appears in `omarchy plugin list`.

### Changes Required

#### 1. `manifest.json`
```json
{
  "schemaVersion": 1,
  "id": "io.github.ki11e6.harbor",
  "name": "Harbor",
  "version": "0.1.0",
  "author": "ki11e6",
  "license": "MIT",
  "description": "Summonable overlay of listening localhost ports with owning process and cwd. Enter opens/copies, ctrl+y copies, ctrl+k kills.",
  "kinds": ["overlay"],
  "entryPoints": { "overlay": "Harbor.qml" }
}
```
(Modeled on `emojis/manifest.json`, plus the `license` field portboard lacked.
Requires a minimal `Harbor.qml` stub in this phase so `entryPoints` resolves.)

#### 2. `LICENSE` — MIT, `Copyright (c) 2026 ki11e6`.

#### 3. `dev.sh` — idempotent install-for-development
```bash
#!/bin/bash
set -euo pipefail

ID="io.github.ki11e6.harbor"
SRC="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/.config/omarchy/plugins/$ID"

mkdir -p "$DEST"
rsync -a --delete --exclude '.git' --exclude 'docs' --exclude 'dev.sh' "$SRC/" "$DEST/"
omarchy plugin validate "$DEST"
omarchy plugin enable "$ID" >/dev/null 2>&1 || true
omarchy-restart-shell
```

#### 4. `.gitignore` — `preview.png` stays tracked; nothing generated yet, keep minimal.

### Success Criteria

#### Automated Verification
- [x] `omarchy plugin validate ~/Projects/omarchy-harbor` → exit 0
- [x] `bash -n dev.sh` → exit 0
- [x] After `./dev.sh`: `omarchy plugin list --json | jq -e '.[] | select(.id == "io.github.ki11e6.harbor")'`

#### Manual Verification
- [x] Shell restarts cleanly after `./dev.sh` (bar comes back, no console errors)
      (Note: enable had to move after `omarchy-restart-shell` — on first install the
      running shell hasn't discovered the plugin dir yet and enable fails.)

---

## Phase 2: Port lister (`list-ports.sh`)

### Overview
Standalone script emitting a JSON array of `{port, process, pid, cwd}`, fixing
portboard's space-parsing and nondeterministic dedup.

### Changes Required

#### 1. `list-ports.sh`
Keep portboard's overall pipeline (`ss -Htlnp` → filter loopback/wildcard →
enrich with `/proc/$pid/cwd` → JSON via `jq -R -s`), with two fixes:

**Fix A — space-safe parsing.** Drop the trailing `_` so the last `read` variable
captures the remainder of the line (verified: `read`'s last var takes the rest,
and the existing regex then matches names with spaces):
```bash
ss -Htlnp 2>/dev/null | while read -r _ _ _ local _ users; do
```

**Fix B — deterministic dedup.** Replace `sort -un` with an awk pass that prefers
the row with a real owner, then sorts by port:
```bash
awk -F'\t' '
  {
    named = ($3 != "?")
    if (!($1 in best) || (named && !bestNamed[$1])) { best[$1] = $0; bestNamed[$1] = named }
  }
  END { for (p in best) print best[p] }
' | sort -n -t$'\t' -k1,1
```

Address filter, `/proc` cwd lookup, and the `jq` JSON assembly are carried over
from `~/omarchy-portboard/list-ports.sh` unchanged (they tested correct).

### Success Criteria

#### Automated Verification
- [x] `bash -n list-ports.sh`
- [x] `bash list-ports.sh | jq -e 'type == "array" and (all(.[]; has("port") and has("process") and has("pid") and has("cwd")))'`
- [x] Dedup fixture test (both input orders → named row wins):
      `printf '3000\t?\t?\t-\n3000\tnode\t123\t/x\n' | <awk snippet> | grep -q node` and reversed order likewise
- [x] Space fixture test: simulated `ss` line with `"my app"` yields `process == "my app"`, not `?`

#### Manual Verification
- [x] Output matches `ss -tlnp` reality with a dev server running (verified with
      `python -m http.server 8123`: row appeared with `cwd=/tmp`, disappeared after kill)
- [x] Root-owned ports (53, 631 on this machine) show `?`/`?`/`-`

---

## Phase 3: Overlay (`Harbor.qml`)

### Overview
The full overlay, structured exactly like `Portboard.qml`/`Emojis.qml`
(context properties → theme tokens → `open/close/toggle/dismiss` → `Process` +
`PanelWindow` → keyCatcher → header + ListView), with the behavior changes.

### Changes Required

#### 1. Carry over unchanged (proven conventions, all APIs verified to exist in `/usr/share/omarchy/shell`)
- Context properties, `Color.menu.*` / `Border.surfaceSpec` / `Style.*` theme block
- `PanelWindow` with `WlrLayer.Overlay`, exclusive keyboard focus, scrim + click-outside dismiss
- `open/close/toggle`, `dismiss()` via `shell.hide()` — fallback ID string becomes `"io.github.ki11e6.harbor"`
- `Process` + `StdioCollector` pattern for the lister; 350 ms refresh delay after kill
- Filter/selection model, keyCatcher with esc-clears-filter-then-closes
- PID guard `/^[0-9]+$/` before any kill

#### 2. Smart Enter (`openSelected`)
```qml
// Ports that don't speak HTTP: copy the address instead of opening a dead browser tab.
readonly property var nonHttpPorts: ({ "22":1, "25":1, "53":1, "111":1, "631":1,
                                       "3306":1, "5432":1, "6379":1, "27017":1 })

function openSelected() {
  if (root.selectedIndex < 0 || root.selectedIndex >= displayModel.count) return
  var row = displayModel.get(root.selectedIndex)
  root.dismiss()
  if (root.nonHttpPorts[row.port])
    Quickshell.execDetached(["wl-copy", "localhost:" + row.port])
  else
    Quickshell.execDetached(["xdg-open", "http://localhost:" + row.port])
}
```
(`wl-copy` verified present at `/usr/bin/wl-copy` — ships with Omarchy.)

#### 3. Copy action (`copySelected`, ctrl+y)
Copies `localhost:<port>` via `wl-copy` and dismisses.

#### 4. Kill escalation (`killSelected`, ctrl+k)
```qml
property string lastKilledPid: ""

function killSelected() {
  ...pid guard...
  killProc.command = (row.pid === root.lastKilledPid)
    ? ["kill", "-9", row.pid]     // second ctrl+k on a survivor escalates
    : ["kill", row.pid]
  root.lastKilledPid = row.pid
  killProc.running = true
}
```
`lastKilledPid` resets in `loadPorts()` when the PID no longer appears in the list.

#### 5. Cosmetics
- Hint bar: `"enter open · ctrl+y copy · ctrl+k kill · ctrl+r refresh · esc close"`
- Empty state gets an icon glyph above the message, same structure as
  `clipboard/Clipboard.qml:585-593` (large Nerd Font glyph, `Style.font.displayLarge`,
  `root.selectedText` at 0.8 opacity) — use `󰛳` (nf-md-web, network-ish) or similar.
- Key handling adds `Qt.Key_Y + ControlModifier` for copy.

### Success Criteria

#### Automated Verification
- [x] `omarchy plugin validate ~/Projects/omarchy-harbor` → exit 0
- [x] `/usr/lib/qt6/bin/qmllint -I /usr/share/omarchy/shell Harbor.qml` — same warning
      categories as the Portboard baseline, no new ones
- [x] `omarchy plugin validate ~/Projects/omarchy-harbor` → exit 0

#### Manual Verification (per the dev-guide testing lifecycle — automated live with wtype/grim)
- [x] `./dev.sh` then summon/hide via `omarchy-shell` opens/closes it (screenshots verified)
- [x] Dev server row appears (`python -m http.server 8123` → `8321`, `cwd=/tmp` shown)
- [x] Enter opens browser for non-allowlisted port (xdg-open fired on port 42053)
- [x] Smart Enter on allowlisted port copies: filter `631` + Enter → clipboard `localhost:631`
- [x] ctrl+y copies (`localhost:8321`); ctrl+k killed the http.server; second ctrl+k on a
      SIGTERM-ignoring server escalated to SIGKILL and killed it
- [x] Root-owned row (`53`): ctrl+k is a no-op — port still listening after
- [x] Typing filters; esc clears filter, esc again closes (exercised repeatedly)
- [ ] Click-outside closes (not automatable without a pointer injector — user to verify)
- [x] Empty state (filter garbage) shows icon + message — required a fix: the
      centered Column needed an explicit `width`; the unsized-Column pattern in the
      built-in overlays (clipboard verified) silently renders nothing → upstream Omarchy
      bug, reported separately
- [ ] Theme switch re-themes the overlay (skipped to avoid disrupting the session — user to verify)

---

## Phase 4: Docs & release readiness

### Overview
README, keybinding docs, preview image, final lifecycle checks.

### Changes Required

#### 1. `README.md`
Modeled on portboard's (good structure), corrected:
- Keys table incl. ctrl+y and the smart-Enter behavior
- Install: `omarchy plugin add https://github.com/ki11e6/omarchy-harbor --enable`
- Keybinding example uses **toggle**:
  `o.bind("SUPER + ALT + P", "Harbor", "omarchy-shell shell toggle io.github.ki11e6.harbor")`
- Dependencies section: `jq` (preinstalled on Omarchy), `wl-clipboard`
- Uninstall: `omarchy plugin remove io.github.ki11e6.harbor`

#### 2. `preview.png` — screenshot of the summoned overlay.

#### 3. Full uninstall/reinstall pass
`omarchy plugin remove` → confirm gone from list → `./dev.sh` → confirm back.

### Success Criteria

#### Automated Verification
- [x] `omarchy plugin validate ~/Projects/omarchy-harbor` → exit 0
- [x] README contains no `svighnesh`/`portboard` leftovers: `! grep -ri 'portboard\|svighnesh' README.md manifest.json Harbor.qml`

#### Manual Verification
- [x] Disable → enable cycle: `omarchy plugin remove --yes` unloaded it live; `./dev.sh`
      reinstalled and re-enabled it
- [x] Survives `omarchy-restart-shell` (restarted several times across dev iterations)
- [x] Clean removal leaves no files in `~/.config/omarchy/plugins/` (remove creates a
      timestamped `.bak` dir — cleaned manually)

---

## Phase 5: Optional bar-widget entry point (added 2026-08-20 after design discussion)

### Overview
A stateless bar button that toggles the overlay — closes the discoverability gap
without polling or idle cost. Modeled 1:1 on `omarchy.menu`'s bar widget
(`/usr/share/omarchy/shell/plugins/menu/BarWidget.qml`), the official precedent
for a bar widget summoning another kind.

### Changes Required

#### 1. `manifest.json` — add `bar-widget` kind, `barWidget` entry point and metadata
(`displayName`, `category: Development`, `defaultSection: right`, `allowMultiple: false`)

#### 2. `BarWidget.qml` — `BarWidget` + `WidgetButton` with the 󰛳 glyph;
`onPressed` runs `omarchy-shell shell toggle io.github.ki11e6.harbor '{}'` via
`root.bar.run()` — the same IPC path as the keybinding.

### Success Criteria

#### Automated Verification
- [x] `omarchy plugin validate .` → exit 0
- [x] qmllint on `BarWidget.qml`: identical warning-category profile to
      `omarchy.menu`'s BarWidget baseline
- [x] Widget placed in bar: `jq '[.bar.layout.right[].id]' ~/.config/omarchy/shell.json`
      contains `io.github.ki11e6.harbor`
- [x] Overlay still summons/hides via `omarchy-shell shell toggle/hide` after the change

#### Manual Verification
- [x] 󰛳 icon renders in the bar's right section (screenshot verified)
- [ ] Physical click on the icon toggles the overlay (no pointer-injection tool on
      this machine — user to verify; the command it runs was verified via IPC)

### Deviation discovered during implementation
`PluginRegistry.setEnabled` (`services/PluginRegistry.qml:495-517`) only inserts a
bar-layout entry when the plugin has **no existing enable entry**. Harbor was
enabled overlay-only first, so its entry lived in `config.plugins` and
`omarchy bar put` silently no-opped. Fix: `omarchy plugin disable` then
`omarchy plugin enable --section right` migrates the entry into `bar.layout`
(where it doubles as the enable flag for both kinds, like `omarchy.menu`).
Documented in the README's bar-widget section. This also exercised the
disable/enable cycle the Phase 4 review flagged as untested.

## Testing Strategy

No test framework exists for Omarchy plugins; verification is the per-phase
criteria above. The two bash fixtures in Phase 2 (dedup order-independence,
space-in-name) are the regression tests for the defects this rewrite exists to
fix — run them after any future lister change.

## Performance Considerations

The lister runs only on open/refresh (no polling); without `keepLoaded` the
overlay consumes nothing while closed. `/proc/<pid>/cwd` readlinks are O(ports),
trivially cheap.

## References

- Reviewed upstream: `~/omarchy-portboard` (clone of SVIGHNESH/omarchy-portboard)
- Convention sources: `/usr/share/omarchy/shell/plugins/emojis/`, `/usr/share/omarchy/shell/plugins/clipboard/`
- Shell plumbing: `/usr/share/omarchy/shell/shell.qml:440-513` (summon/toggle), `services/PluginRegistry.qml:564` (`__sourceDir`)
- Dev guide: https://omarchyplugins.com/develop.html
