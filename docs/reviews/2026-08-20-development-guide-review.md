# Harbor review — Omarchy plugin development guide compliance

Date: 2026-08-20
Guide: https://omarchyplugins.com/develop.html
Reviewed at commit: d796b1b
Environment: `OMARCHY_PATH=/usr/share/omarchy`, Quickshell 0.3.0, Qt 6 (`/usr/lib/qt6/bin/qmllint`)

Every claim below was checked by running a command or reading the shell source in
this session. Claims that failed validation are recorded in
[Refuted claims](#refuted-claims) rather than deleted, so they are not
re-discovered later.

## Method

- `omarchy plugin validate "$PWD"` — the real validator.
- `qmllint` on both entry points, and on `plugins/emojis/Emojis.qml` as a baseline.
  The guide's invocation (`-I "$OMARCHY_PATH/shell"`) cannot resolve `qs.Ui` /
  `qs.Commons` at all: the module URI is `qs.*` but the directory is
  `shell/Ui`. Worked around with a temp dir containing a `qs` -> `shell` symlink.
- Read the shell source for every host contract Harbor relies on
  (`shell.qml`, `services/PluginRegistry.qml`, `Ui/BarWidget.qml`,
  `Ui/WidgetButton.qml`, `Ui/PointerMoveGate.qml`, `plugins/bar/Bar.qml`).
- Ran throwaway Qt/Quickshell test harnesses to settle behavioural questions
  instead of reasoning about them (see [Refuted claims](#refuted-claims)).

## Verified as compliant

| Guide requirement | Evidence |
|---|---|
| Manifest schema | `omarchy plugin validate "$PWD"` -> exit 0. All required fields present (`schemaVersion: 1`, `id`, `name`, `version`, `kinds`, `entryPoints`) plus the optional `author`/`license`/`description`. |
| Kinds <-> entry points aligned | `overlay` -> `Harbor.qml`, `bar-widget` -> `BarWidget.qml`; both files exist with matching case. `omarchy-plugin-validate` enforces this per kind. |
| Namespaced id, no reserved prefix | `io.github.ki11e6.harbor` matches `io.github.username.plugin-name`; not `omarchy.*`. |
| No symlinks | Validator's `find -type l` check passes. |
| `barWidget.defaultSection` legal | `"right"` is in `["left","center","right"]`. |
| `moduleName` matches manifest id | `BarWidget.qml:6` = `io.github.ki11e6.harbor`; the registry registers under `String(manifest.id)` (`shell.qml:678`). |
| Overlay lifecycle contract | `open(payloadJson)` / `close()` / `toggle()` / `opened` all present. `shell.qml:546` calls `open()` via `deliverIfLoaded`, `shell.qml:489` calls `close()` via `hide()`, `shell.qml:505` reads `opened`. |
| `bar.run()` is real | `plugins/bar/Bar.qml:611`. Harbor's click path matches `plugins/menu/BarWidget.qml:21`. |
| Injected properties | `shell` and `manifest` are set in the Loader's `onLoaded` (`shell.qml:630-631`), so `manifest.__sourceDir` is populated before `open()` runs. |
| `list-ports.sh` works | `bash list-ports.sh` emits valid JSON, correctly sorted, with `?` owners for root-owned sockets. |
| Dev loop uses documented commands | `omarchy plugin validate`, `omarchy-restart-shell`, `omarchy plugin enable` all exist; `rescanPlugins` IPC exists at `shell.qml:890`. |
| Lint parity with built-ins | Harbor's qmllint warning categories are the same set the built-in overlay produces (`missing-property` / `unqualified` / `uncreatable-type`), all from the shell's own nested-`QtObject` token idiom. |

The guide's "bar widgets must expose `closeForPopoutSwitch()` / track
`popoutSwitchClosing`" requirement does **not** apply here: `plugins/bar/Bar.qml:319`
guards with `if ("closeForPopoutSwitch" in activePopout)`, and only widgets that
register a popout ever become `activePopout`. Harbor's bar button has no popout.

## Confirmed issues

### 1. README documents an enable workflow that does not exist — HIGH

`README.md:34-46` says the bar widget is optional and that you must
`omarchy plugin disable` first so the enable entry "can move onto the bar".
Both halves are wrong.

- Any plugin declaring `bar-widget` hits `if (!location.found && isBarWidget)`
  at `PluginRegistry.qml:503` on first enable, resolves the section via
  `defaultBarWidgetSection(manifest)` (`:511`, `"right"` for Harbor), and is
  spliced into `config.bar.layout[section]` (`:513`). There is no
  "enabled keyboard-only" state reachable from the CLI — **the bar button is
  mandatory**.
- `omarchy-plugin-add:38-53` (`select_bar_widget_placement`) confirms this from
  the other side: for a plugin with `bar-widget` and without `bar`,
  `plugin add --enable` prompts for a bar section.
- The "disable first" step is unnecessary. With the entry already present,
  `location.found` is true, the insert branch is skipped, and
  `PluginRegistry.qml:521` calls `moveBarEntry(config, key, placement)` —
  `omarchy-plugin-enable` then prints "Enabled and moved".

Fix: either rewrite that README section (the button ships with the plugin,
`enable --section <s>` moves it), or drop the `bar-widget` kind if an
overlay-only install is the intent.

### 2. Filter editing skips the shared `Util` helpers — MEDIUM

`Harbor.qml:235-237` handles `Qt.Key_Backspace` directly. All three built-in
filterable surfaces route this through `Util.editsFilter` / `Util.editedFilter`
(`Commons/Util.qml:97-112`), used at `Emojis.qml:203`, `Clipboard.qml:363`,
`Menu.qml:1088`.

Consequences, read off `Util.qml:98-112`:

- `Ctrl+U` (clear the whole filter) does nothing in Harbor.
- `Ctrl+Backspace` (delete previous word) deletes a single character instead.
- Alt/Meta-modified keys are not excluded from the edit path.

Fix: add an `else if (Util.editsFilter(event, root.filterText))` branch before
the plain-`Backspace` handling, exactly as the built-ins do. `qs.Commons` is
already imported.

### 3. Delegate has no `id`, producing 22 unqualified-access warnings — MEDIUM

`Harbor.qml:295-367`. The delegate `Rectangle` is anonymous, so its children
reach model data through `parent.parent.port`, `parent.parent.hasCursor`, etc.,
and `index` resolves through the implicit scope chain. `qmllint` flags 22
`unqualified` accesses at lines 302-364 that the built-in equivalent does not
produce, because `Clipboard.qml:469` names its delegate `id: row` and uses
`row.index` / `row.previewText`.

Not a runtime fault today, but the `parent.parent` chain breaks silently if a
wrapper element is ever inserted.

Fix: `id: rowItem` on the delegate; replace `parent.parent.X` with `rowItem.X`.

### 4. Deviates from the pointer-gating convention — LOW (hazard unproven)

`Harbor.qml:357-361` selects on raw hover:
`onContainsMouseChanged: if (containsMouse) root.selectedIndex = index`.

`Clipboard.qml` — the closest built-in analogue — instead pairs a
`PointerMoveGate` (`Clipboard.qml:245`) with a `cursorActive` flag: selection
goes through `selectFromPointer()` (`:191-195`), which requires
`pointerGate.moved()` to clear a movement threshold, and `hasCursor` is
`root.cursorActive && index === root.selectedIndex` (`:477`).
`Ui/PointerMoveGate.qml:3-4` states its purpose as filtering "synthetic hover
churn from moving delegates under a stationary pointer".

**I could not reproduce that hazard.** See
[Refuted claims](#refuted-claims) — three separate tests showed hover fires only
on genuine pointer motion. So this is a convention deviation worth closing for
consistency (and because Harbor's `ctrl+k` is destructive), not a demonstrated
defect.

### 5. `ctrl+k` is destructive with no confirmation — LOW (design call)

`Harbor.qml:140-149` sends `SIGTERM`, then `SIGKILL` on a repeat press, with no
confirmation step and no undo. The one destructive action in the built-in
overlays routes through `Ui/ConfirmDialog.qml` (`Clipboard.qml:400-412`,
"Delete entire clipboard history?").

The PID is validated (`/^[0-9]+$/`) and the kill is correctly a no-op for
`?`-owner rows, so this is a UX judgement call, not a correctness bug. Worth
reconsidering given the guide asks READMEs to spell out privilege boundaries.

### 6. A `cwd` containing a tab silently truncates the row — LOW

`list-ports.sh:34-43` joins fields with `\t` and splits them back in `jq`.
Verified by feeding a tab-containing path through the same pipeline: a row whose
`cwd` is `/home/x<TAB>with<TAB>tabs` comes out as `"cwd": "/home/x"`, with the
remainder dropped rather than reported. A newline in `cwd` would break the row
apart entirely.

Pathological input, but the failure is silent. Fix: emit NUL-separated fields, or
build the JSON per row in `jq` with `--arg`.

### 7. README has no configuration section — LOW

The guide requires a README documenting "Installation command, Usage
instructions, Configuration options, Removal steps, Any external dependencies or
privilege boundaries". Harbor covers all but configuration options — of which it
has none. State that explicitly to close the checklist item.

### 8. Layer-shell namespace misses the no-animation rule, so the overlay fades — MEDIUM

`Harbor.qml:179` sets `WlrLayershell.namespace: "harbor"`.
`default/hypr/apps/omarchy-shell.lua:10` exempts the keyboard-driven overlays
from compositor layer animation with an **anchored** namespace regex:

```lua
hl.layer_rule({ match = { namespace = "^(omarchy-menu|omarchy-image-selector|omarchy-emojis|omarchy-clipboard|omarchy-keyboard-panel)$" },
                no_anim = true, animation = "none" })
```

`"harbor"` matches none of those alternatives, and `default/hypr/looknfeel.lua:83-85`
enables `layers` / `layersIn` / `layersOut` fades by default (out at speed 1.5 —
the slow one). So Harbor fades in and out where every built-in overlay it is
modelled on pops instantly. Renaming the namespace cannot fix it: the regex is
anchored to that fixed `omarchy-*` list, and third-party plugins must not claim
the `omarchy.*`/`omarchy-*` namespace.

Fix: document the one-line rule in the README, since a plugin has no mechanism to
ship Hyprland config:

```lua
hl.layer_rule({ match = { namespace = "harbor" }, no_anim = true, animation = "none" })
```

Keeping a distinct namespace is also what avoids collisions with other plugins,
so `"harbor"` itself is the right call — it just needs the accompanying rule.

## Open tradeoff (not an issue)

Harbor sets no `keepLoaded`, unlike `omarchy.clipboard` and `omarchy.emojis`
which both set `keepLoaded: true`. The Loader's `active` binding
(`shell.qml:625`) is therefore false whenever the overlay is closed, so:

- the overlay is constructed asynchronously on every summon, and
- `list-ports.sh` (bash + `ss` + `jq`) runs cold on every open.

That costs a little first-paint latency in exchange for zero idle cost, which
matches the README's framing. Documented here so it reads as deliberate.

Related, and verified safe: because the Loader deactivates during `dismiss()`,
Harbor's overlay item is destroyed *synchronously inside*
`openSelected()`/`copySelected()`, before the following `Quickshell.execDetached`
line runs. A Quickshell harness reproducing this exact shape confirmed the JS
frame survives its own object's destruction and the side effect still executes.
`keepLoaded: true` overlays never hit this path, so it was worth checking.

## Refuted claims

Recorded so they are not re-raised. Each was an initial suspicion that testing
disproved.

### R1. "Hover steals selection while filtering, so `ctrl+k` can kill the wrong process"

Tested with a Qt 6 `ListView` + `hoverEnabled` `MouseArea` harness, cursor
parked inside the window with `hyprctl dispatch 'hl.dsp.cursor.move({x=..., y=...})'`
and window geometry cross-checked against `hyprctl clients -j` (cursor at
1437,814 inside a window spanning x 967..1908, y 560..1068). Three scenarios:

| Scenario | Result |
|---|---|
| `ListModel.clear()` + repopulate, pointer stationary — what `rebuildDisplay()` does on every keystroke | No `containsMouse` transition on any new delegate. Only the dying delegate reported `contains=false`. |
| Window mapping under an already-stationary cursor — the "overlay opens under the mouse" case | No hover event at all. |
| `insert(0, ...)` shifting delegates under a stationary pointer | Neither `containsMouseChanged` nor `positionChanged` fired. |

Control: warping the cursor into the window did produce
`HOVER index=2 contains=true`, so the harness was wired correctly. Conclusion:
hover fires only on real pointer motion; the selection hijack does not occur.
Issue 4 above is what survives — a style deviation only.

An early run of this test appeared to confirm the hazard's absence for the wrong
reason: `hyprctl dispatch movecursor X Y` is rejected by Hyprland's Lua
dispatcher (`hl.dsp.cursor.move({x = X, y = Y})` is the current syntax), so the
cursor never actually moved. Also note `console.log` from `qml`/`qs` goes to the
journal unless `QT_FORCE_STDERR_LOGGING=1` is set.

### R2. "Rapid `ctrl+k` drops the SIGKILL because `running = true` is a no-op while running"

`Harbor.qml:144-148` assigns `killProc.command` then `killProc.running = true`
without the `running = false` restart idiom used at `Ui/MultiSelect.qml:195-196`.
A Quickshell harness reproducing the exact shape (start a long command, then
reassign `command` and set `running = true` while it is still running) showed the
second command **does** execute once the first exits — `FIRST` then
`SECOND-ESCALATION` both ran. The escalation is deferred by milliseconds, not
lost.

### R3. "The bar button should filter on `Qt.LeftButton` like the built-ins"

`plugins/menu/BarWidget.qml:18-22` maps right-click to a terminal and *every
other button* — including middle — to the toggle. Harbor toggling on any button
is the same shape, not a deviation.

### R4. "There are no namespace-keyed `layerrule`s in the Omarchy defaults"

Wrong, and it inverted issue 8. The first search used
`grep "layerrule" "$OMARCHY_PATH/default/hypr/"*.conf ... *.lua` — non-recursive,
and looking for the old `layerrule` spelling. The rules actually live in
`default/hypr/apps/*.lua` and use the Lua API's `hl.layer_rule({ ... })`. A
recursive search over all of `$OMARCHY_PATH` plus `~/.config/hypr` found three of
them. Lesson for future passes here: search recursively and match the Lua API
spelling (`layer_rule`, `hl.dsp.*`), not the legacy `hyprland.conf` keywords.

## Suggested order of work

1. Issue 1 (README enable workflow) — the only thing that actively misleads a user.
2. Issue 8 (layer animation) — one README line, removes a visible difference from
   every built-in overlay.
3. Issue 2 (`Util.editsFilter`) — small, restores expected keyboard behaviour.
4. Issue 3 (delegate `id`) — mechanical, clears 22 lint warnings.
5. Issues 5 and 7 — decide on `ctrl+k` confirmation; add the config note.
6. Issues 4 and 6 — polish.

## Not yet done

Harbor is not currently installed in `~/.config/omarchy/plugins/`, so nothing in
this review was validated against a live shell. The guide's testing checklist
(click behaviour, escape closing, enable/disable cycling, shell-restart
persistence, complete removal) still needs a run of `./dev.sh` followed by manual
exercise of each item.

## Addendum — second-pass verification (same day)

Issues 2, 3, 5, 6, 7, 8 re-verified against source and confirmed as written
(issue 3's warning count reproduced exactly: 22 unqualified at lines 302-364
using the `qs` symlink lint setup).

Two corrections:

### A1. Issue 1's "disable first is unnecessary" sub-claim is wrong

`moveBarEntry` locates the entry via `findBarLocation`, which searches **only**
`config.bar.layout` (`PluginRegistry.qml:179-187`); an enable entry living in
`config.plugins` (the pre-bar-widget state) is not found, `moveBarEntry`
returns an error string, and `setEnabled` discards the return value
(`PluginRegistry.qml:519-520`) — a silent no-op. Confirmed live earlier the
same day: two `omarchy bar put --section right` attempts changed nothing until
a `plugin disable` / `plugin enable --section right` cycle migrated the entry.
Issue 1's main point (the bar button is mandatory on fresh installs, so
"optional" was misleading) stands and is fixed in the README.

### A2. R1's refutation does not transfer to the live layer-shell overlay

R1's harness used a regular window; the real overlay is a layer-shell surface.
Observed live: with the pointer resting mid-screen where the overlay maps, a
filtered two-row list ("53" -> rows 53 and 42053) activated the row under the
pointer, and Enter ran `xdg-open http://localhost:42053` instead of the
copy-branch for row 53. Parking the cursor at the screen corner made the same
sequence behave. Whether the trigger is a compositor pointer-enter on surface
map or micro-motion, the mis-selection is real in situ, so issue 4 was fixed
functionally (PointerMoveGate + cursorActive, the clipboard pattern), not just
as a style alignment.

### A3. Issue 3's lint accounting was wrong (fix still applied)

Naming the delegate and replacing the `parent.parent` chains does **not**
clear the 22 unqualified warnings: re-linting after the fix still reports 22,
now all pointing at `root.*` / `resultList` id-references from inside the
delegate scope — a class qmllint flags regardless of delegate naming, and which
`Clipboard.qml` itself emits (12 of them) under the same lint setup. The
`parent.parent` chains were never the flagged lines (`parent` resolves
statically). The rename was applied anyway for the stated robustness reason —
inserting a wrapper element can no longer silently break the bindings.
