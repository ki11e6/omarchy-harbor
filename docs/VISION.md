# Harbor — what this project is for

Read this before adding a feature. Harbor looks like a list of ports, and that
resemblance has repeatedly pulled it toward becoming a port *monitor*. It is not
one. This document exists so that pull is resisted deliberately rather than
lost by default.

## The moment

Harbor exists for one moment: a command the developer just ran refused to start.

```
Error: listen EADDRINUSE: address already in use :::3000
Error starting userland proxy: listen tcp4 0.0.0.0:5432: bind: address already in use
```

The error names a port and nothing else. The developer has two ways out —
**free the port**, or **move their own service to a different one** — and about
five seconds of patience before they start guessing.

Harbor's job is to answer, in one screen, which of those two exits applies and
to make taking it a single keystroke.

## Who hits this

Developers running more than one thing at once:

- several checkouts or worktrees of the same app, all wanting port 3000
- a `docker compose` stack whose Postgres collides with a locally-installed one
- a server orphaned by a closed terminal, an editor task, or a coding agent —
  invisible to the shell's job list, still holding the socket
- picking a port for a new service and wanting to know what is already taken

The existing answers are `lsof -i :3000` and `ss -tlnp | grep 3000`. Both need
flags recalled mid-frustration, and both reply `node` — which is every
JavaScript project on the machine.

## The scenarios Harbor must cover

Each of these is the same moment seen from a different angle. Harbor is finished
when all eight have a truthful answer.

| # | Scenario | What the developer needs |
|---|---|---|
| 1 | Bind failed — what holds 3000? | The holder, identified well enough to decide, and a kill |
| 2 | Is 8080 free before I commit to it? | An affirmative **yes it is free**, not an empty list |
| 3 | It's taken — give me one that isn't | A concrete next free port |
| 4 | Did my kill actually work? | Confirmation the socket was released, or that it wasn't |
| 5 | Which of my four checkouts is this? | The project, not the runtime's thread name |
| 6 | It's held by `docker-proxy` | To be told `kill` won't free it, and what will |
| 7 | It's held by root | To be told it needs `sudo`, not a silent no-op |
| 8 | localhost:3000 serves an old build | Which checkout is answering |

## The one rule

**Never claim a port is free unless we know it is.**

Every other quality is negotiable; this one is not. A false "free" sends the
developer back to a bind error with their trust in the tool spent. Three
distinct states must stay distinguishable at all times:

- **used** — we saw a listener
- **free** — the probe succeeded and saw no listener
- **unknown** — the probe failed, timed out, or was truncated

"Unknown" must never render as "free". This rule is why Harbor has no
ignore-list setting, no output truncation, and no address filter that hides
listeners: each of those is a mechanism for producing a confident false "free".

## The four answers

Typing a port number into Harbor should produce exactly one of these:

```
3000 is free

3000 · vite
localhost · my-app · pid 4242                      [ctrl+k to free it]

3000 · docker-proxy
container — docker stop frees this

3000 · ?
owned by another user — needs sudo
```

Rows are two lines — identity above, context below. Six facts do not fit on one
line at the card's width, and the two-line shape is what both surveyed port
plugins converged on.

…and when it is taken, a suggestion underneath: `3001 is free`.

That last line is the entire second half of the vision — *so that the user can
change the port* — and none of the three tools surveyed on 2026-08-30 provides
it.

## What Harbor is not

Harbor is an **answer machine**, hit once and left. It is not a dashboard.

The distinction is not stylistic; it decides the architecture. A monitor polls,
holds state, needs settings, and earns its screen space by being glanceable. An
answer machine runs cold on demand, holds nothing, and earns its keystroke by
being certain. Harbor deliberately omits `keepLoaded`, so nothing runs while it
is closed.

Concretely out of scope, and why:

| Not doing | Why |
|---|---|
| Polling, live counts on the bar | Ends zero-idle-cost; nothing to glance at between bind failures |
| Ignore-list / hidden-port settings | Manufactures false "free" answers — violates the one rule |
| Output caps that silently drop rows | Same |
| Multi-select, group headers, filter chips | A selection model for a tool used one row at a time |
| Framework detection by cmdline regex | Confidently mislabels; `node` honestly beats `Next.js` wrongly |
| Docker / Kubernetes management | Warning that a row is a container is in scope; managing it is not |
| User-assigned port labels | Solving "which project is 3000?" by making the user type the answer |
| Terminal-in-project, rich clipboard actions | Serves a browsing workflow, not a bind failure |
| A CLI backend, IPC query handlers | IPC needs `keepLoaded`; the probe is one `ss` call |

Prior art was surveyed on 2026-08-30 — `mich-nduka/omaports`,
`yuler/omaports`, `dupontbertrand/omastatus`. All three are monitors, and all
three are good ones. Their feature lists are not a roadmap for Harbor; several
entries on them are on the table above.

## Known limits

Stated so they are not mistaken for bugs, and so the "free" answer stays honest
about its own scope:

- **TCP only.** A UDP listener on 3000 does not block a TCP bind, so it is not
  relevant to the question and is not shown.
- **Listening sockets only.** `ss -l` does not show `TIME_WAIT`. Most dev
  servers set `SO_REUSEADDR`, for which `TIME_WAIT` does not block a bind.
- **Process identity for your own processes only.** `ss` cannot name another
  user's process without root; those rows show `?` and say so.
- **Free is not always bindable.** Below the kernel's
  `net.ipv4.ip_unprivileged_port_start` (1024 by default, lowered by some
  rootless-container setups) a port can be genuinely free and still unbindable
  without root or `CAP_NET_BIND_SERVICE`. Harbor reports free/used truthfully
  and states the caveat rather than guessing the caller's capabilities.

## Design principles

1. **Truthful over complete.** Fewer facts, none of them wrong.
2. **Cold and certain over warm and stale.** Run the probe at open; hold nothing.
3. **Explain the refusal.** An action that cannot happen says why. A silent
   no-op is the worst outcome in a tool used under time pressure.
4. **No invisible tables.** Behaviour must not depend on a hardcoded allowlist
   the user cannot see. If a distinction matters, derive it from observed facts
   or drop it.
5. **One keystroke to the exit.** Both exits — kill it, or move — end in a
   single key.

## References

- Initial implementation: `docs/plans/2026-08-20-harbor-initial-implementation.md`
- Guide compliance review: `docs/reviews/2026-08-20-development-guide-review.md`
- Scope removal plan: `docs/plans/2026-08-30-scope-removal.md`
- Answer-machine plan: `docs/plans/2026-08-30-port-answer-machine.md`
