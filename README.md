# Harbor 󰀱

**Is this port free?** Harbor is a summonable Omarchy overlay that answers the
`EADDRINUSE` moment: press a key, type a port number, and it says
**"3000 is free"** — or shows who holds it, named by project checkout rather
than thread name, with the next free port suggested underneath and a verified
kill one keystroke away.

See [docs/VISION.md](docs/VISION.md) for what Harbor is for and what it
deliberately does not do.

![kind: overlay](https://img.shields.io/badge/kind-overlay-blue)

![Harbor overlay](preview.png)

## The problem it solves

```
Error: listen EADDRINUSE: address already in use :::3000
```

The error names a port, not a process. `lsof -i :3000` needs flags recalled
mid-frustration and answers `node` — which is every JavaScript project on the
machine. You have two ways out: **free the port**, or **move your service to
another one**. Harbor makes both a single keystroke.

## Features

- **Affirmative answers** — type `8080` and get **"8080 is free"**, never an
  ambiguous empty list. Below the privileged-port floor the answer carries a
  "needs root" caveat.
- **Next free port** — when 3000 is taken, Harbor says **"3001 is free"** so
  you can move instead of fight.
- **Named by project** — rows read `3000 · node / my-app`, resolved by walking
  from the server's working directory to the nearest `.git`/`package.json`.
  Four `node` processes become four project names. No framework guessing.
- **Verified kills** — `ctrl+k` sends SIGTERM, re-checks the socket, and
  reports **"3000 is now free"** or **"still listening — ctrl+k again to
  force"**. The signal is identity-checked (pid + uid + start time) so a
  recycled PID can never catch a kill meant for its predecessor.
- **Refusals explained** — a root-owned port says *needs sudo*; a
  `docker-proxy` port says *docker stop frees this* instead of offering a kill
  dockerd would undo. No silent no-ops.
- **Exposure at a glance** — an urgent dot marks listeners reachable beyond
  localhost; something bound to `192.168.1.5:3000` still blocks your bind, so
  Harbor shows it.
- **Honest failure** — a failed or hung probe says so. Harbor never renders a
  broken probe as "everything is free".
- **Zero idle cost** — nothing polls; the probe runs when you summon it.

## Install

```bash
omarchy plugin add https://github.com/ki11e6/omarchy-harbor --enable
```

## Set the keybinding

Harbor is meant to be summoned from the keyboard. Add to
`~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + ALT + P", "Harbor", "omarchy-shell shell toggle io.github.ki11e6.harbor")
```

Keep the description `"Harbor"` — the bar icon's hover tooltip looks the
binding up by that name and shows it (`Harbor — is this port free? SUPER+ALT+P`).
Until a binding exists, the tooltip reminds you to set one.

## Keys

| Key | Action |
|-----|--------|
| type | Filter the list — or ask: a filter that is exactly a port number gets the free/taken answer |
| `enter` / click | Open `http://localhost:<port>` in the browser |
| `ctrl+k` | Kill the owner (SIGTERM) and verify; press again on a survivor to escalate to SIGKILL |
| `ctrl+y` | Copy `localhost:<port>` to the clipboard |
| `ctrl+r` | Refresh the list |
| arrows / `ctrl+n` / `ctrl+p` | Move selection |
| `esc` | Clear the filter, then close |

## Bar widget

Enabling Harbor also places a stateless 󰀱 anchor on the bar (no polling, no
idle cost) that toggles the same overlay; hovering it shows the plugin name
and your keybinding. `omarchy plugin add --enable` asks which section,
defaulting to `right`. Move it later with:

```bash
omarchy bar move io.github.ki11e6.harbor --section <left|center|right>
```

The bar entry doubles as the plugin's enable flag, so there is no
keyboard-only install: removing the button from the bar
(`omarchy plugin disable`) disables the overlay too.

## Instant open/close (recommended)

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

## Credits

Harbor began as a ground-up rewrite inspired by
[SVIGHNESH/omarchy-portboard](https://github.com/SVIGHNESH/omarchy-portboard) —
the first Omarchy plugin to put listening ports in a summonable overlay. The
architecture (a QML overlay over a small `ss` wrapper script) follows its lead;
the code was rewritten from scratch. Thank you!

## License

MIT
