# Harbor

A summonable Omarchy shell overlay showing every listening localhost TCP port, with the owning process, PID, and working directory.
Answers "which dev server is on 5173?" without leaving the keyboard.

![kind: overlay](https://img.shields.io/badge/kind-overlay-blue)

![Harbor overlay](preview.png)

## Keys

| Key | Action |
|-----|--------|
| type | Filter the list (e.g. `3000`, `node`, or a directory name) |
| `enter` / click | Open `http://localhost:<port>` in the browser — or copy `localhost:<port>` for known non-HTTP ports (ssh, smtp, dns, rpcbind, cups, mysql, postgres, redis, mongo) |
| `ctrl+y` | Copy `localhost:<port>` to the clipboard |
| `ctrl+k` | Kill the owning process (SIGTERM); press again on a survivor to escalate to SIGKILL |
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
Only sockets bound to loopback or wildcard addresses are shown; IPv4/IPv6 duplicates are collapsed to one row per port, preferring the row whose owner is known.

Ports owned by other users (for example root services like CUPS) show `?` for process and PID, since `ss` can't read their process info without root.
`ctrl+k` does nothing for those.

Everything runs unprivileged as your user: `ctrl+k` can only signal processes you own, and there is no confirmation step — the first press sends SIGTERM (polite), and only a deliberate second press on a survivor sends SIGKILL.

## Configuration

None. Harbor has no options; the filter, keys, and theming (inherited from the active Omarchy theme) are the whole interface.

## Dependencies

Everything ships with a stock Omarchy install:

- `jq` — JSON assembly in `list-ports.sh`
- `wl-clipboard` — the copy actions (`wl-copy`)
- `xdg-open` — opening ports in the browser

## Development

```bash
./dev.sh   # sync into ~/.config/omarchy/plugins/, validate, restart the shell, enable
```

## Uninstall

```bash
omarchy plugin remove io.github.ki11e6.harbor
```

## License

MIT
