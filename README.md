# Harbor

A summonable Omarchy shell overlay that answers the `EADDRINUSE` moment: type a port number and Harbor says **"3000 is free"**, or shows who holds it — named by project checkout, not thread name — with a suggested free port underneath and a verified kill one keystroke away.

See [docs/VISION.md](docs/VISION.md) for what Harbor is for and what it
deliberately does not do.

![kind: overlay](https://img.shields.io/badge/kind-overlay-blue)

![Harbor overlay](preview.png)

## Keys

| Key | Action |
|-----|--------|
| type | Filter the list (e.g. `3000`, `node`, or a directory name). A filter that is exactly a port number is a question: Harbor answers **"3000 is free"** (with a caveat below the privileged-port floor) or suggests the next free port when it's taken |
| `enter` / click | Open `http://localhost:<port>` in the browser |
| `ctrl+y` | Copy `localhost:<port>` to the clipboard |
| `ctrl+k` | Kill the owning process (SIGTERM) and verify: the banner reports **"3000 is now free"** or **"still listening — ctrl+k again to force"** (SIGKILL). Kills that can't happen say why — root-owned, container-held, or identity unreadable |
| `ctrl+r` | Refresh the list |
| arrows / `ctrl+n` / `ctrl+p` | Move selection |
| `esc` | Clear the filter, then close |

## Install

```bash
omarchy plugin add https://github.com/ki11e6/omarchy-harbor --enable
```

Then bind a key in `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + ALT + P", "Harbor", "omarchy-shell shell toggle io.github.ki11e6.harbor")
```

### Bar widget

Enabling Harbor also places a stateless 󰛳 button on the bar (no polling, no idle
cost) that toggles the same overlay — `omarchy plugin add --enable` asks which
section, defaulting to `right`. Move it later with:

```bash
omarchy bar move io.github.ki11e6.harbor --section <left|center|right>
```

The bar entry doubles as the plugin's enable flag, so there is no
keyboard-only install: removing the button from the bar
(`omarchy plugin disable`) disables the overlay too.

### Instant open/close (recommended)

Omarchy exempts its own overlays from layer animations, but that rule is
namespace-anchored and can't cover third-party plugins. Add one line to your
`~/.config/hypr/looknfeel.lua` so Harbor pops instantly instead of fading:

```lua
hl.layer_rule({ match = { namespace = "harbor" }, no_anim = true, animation = "none" })
```

## How it works

The overlay runs `list-ports.sh` (a small `ss -tlnp` wrapper) each time it opens or refreshes, and renders the result with the active Omarchy theme.
Every listener is shown whatever address it holds — something on `192.168.1.5:3000` still blocks a `0.0.0.0:3000` bind — with its bind scope (`localhost`, `all interfaces`, or the literal address). Duplicates across address families collapse to one row per port, preferring the row whose owner is known and the widest bind scope.

Rows are named by the project checkout the server was started from (the nearest ancestor of its working directory carrying `.git`, `package.json`, and similar markers), so four `node` processes read as four project names. No framework guessing: an honest `node` beats a wrong `Next.js`.

A probe that fails or times out says so — Harbor never renders a failed probe as "everything is free". Free claims below the kernel's unprivileged-port floor carry a "needs root" caveat, and suggested ports never go below it.

Ports owned by other users (for example root services like CUPS) show `?` for process and PID, since `ss` can't read their process info without root.
`ctrl+k` on those says `owned by another user — needs sudo`; on a `docker-proxy` row it says `container port — docker stop frees this` instead of sending a kill dockerd would undo.

Everything runs unprivileged as your user. `ctrl+k` re-checks the target's identity (pid, uid, start time) against live `/proc` before signaling, so a recycled PID can't catch a signal meant for its predecessor; there is no confirmation step — the first press sends SIGTERM (polite), and only a deliberate second press on a survivor sends SIGKILL.

## Configuration

None. Harbor has no options; the filter, keys, and theming (inherited from the active Omarchy theme) are the whole interface.

## Dependencies

Everything ships with a stock Omarchy install:

- `jq` — JSON assembly in `list-ports.sh`
- `wl-clipboard` — the copy actions (`wl-copy`)
- `xdg-open` — opening ports in the browser

## Development

```bash
./dev.sh              # sync into ~/.config/omarchy/plugins/, validate, restart the shell, enable
bash test/fixtures.sh # regression fixtures: probe, dedup, kill helper, answer logic
```

## Uninstall

```bash
omarchy plugin remove io.github.ki11e6.harbor
```

## License

MIT
