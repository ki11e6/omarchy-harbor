#!/bin/bash
#
# Emit listening TCP ports as {"ok": bool, "unprivilegedPortStart": n,
# "ephemeralStart": n, "ephemeralEnd": n, "ports": [...], "occupied": [...]},
# where ports holds {port, scope, address, process, pid, uid, starttime,
# project, cwd} objects (nine fields — the arity guard and the jq assembly
# both depend on that count), sorted by port, one entry per holder per port.
#
# ports answers "who holds this?"; occupied answers "can I bind this?". They
# are not the same set. `ss -l` shows only LISTEN, but a socket in any other
# live state still refuses a bind — a process that pinned a source port for
# an outbound connection owns that port completely while being absent from
# every listener table. Answering from ports alone reports such a port free
# and hands the user the EADDRINUSE this tool exists to prevent, so occupied
# carries every port the machine holds, whatever the socket is doing.
#
# TIME-WAIT is excluded from occupied on purpose: SO_REUSEADDR binds straight
# over it and essentially every dev server sets it, so counting it would
# manufacture a false "taken".
#
# project is the basename of the nearest ancestor of cwd carrying a project
# marker (.git, package.json, ...), so a Laravel server started in public/
# reports the app, not "public". Fallback: the cwd basename; empty for
# foreign rows and for servers started from $HOME or /. The walk is capped
# at 8 levels and never guesses frameworks — an honest "node" beats a wrong
# "Next.js".
#
# Every listener is reported whatever address it holds: something bound to
# 192.168.1.5:3000 still blocks a 0.0.0.0:3000 bind, so hiding it would
# manufacture a false "free". Scope classifies the bind address:
#   any    0.0.0.0, ::, *             reachable from the network
#   local  127.*, ::1, ::ffff:127.*   loopback only
#   iface  anything else              one specific interface
#
# Dedup collapses address families to one row per holder per port: rows
# sharing a port and a pid merge, rows with different pids stay apart. Two
# processes on 127.0.0.1:3000 and 192.168.1.5:3000 are two answers to "who
# holds this?" — merging them hid one holder, and a kill aimed at the shown
# one left the port taken by the hidden one. Unreadable owners ("?") group
# together, since nothing tells them apart. Within a row, scope comes from
# the widest bind and address from the socket that won the scope union, so
# scope and address always agree.
#
# "ok" is false when the socket table could not be read (ss missing or
# failing) or the JSON assembly failed. An empty machine and a failed probe
# are different answers and must never be conflated — the wrapper carries
# ss's own verdict so the overlay never renders a failure as "all free".

set -o pipefail

fail() {
  printf '{"ok": false, "unprivilegedPortStart": 1024, "ephemeralStart": 0, "ephemeralEnd": 0, "ports": [], "occupied": []}\n'
  exit 0
}

# The dedup/union pass, callable standalone (--dedup, rows on stdin) so the
# fixture tests can exercise it directly.
dedup() {
  awk -F'\t' '
    function rank(s) { return s == "any" ? 3 : s == "iface" ? 2 : 1 }
    NF == 9 {
      k = $1 "\t" $5
      if (!(k in srank) || rank($2) > srank[k]) { srank[k] = rank($2); scope[k] = $2; adr[k] = $3 }
      if (!(k in ident)) ident[k] = $4 "\t" $5 "\t" $6 "\t" $7 "\t" $8 "\t" $9
    }
    END { for (k in ident) { split(k, kp, "\t"); print kp[1] "\t" scope[k] "\t" adr[k] "\t" ident[k] } }
  '
}

if [[ "${1:-}" == "--dedup" ]]; then
  dedup
  exit 0
fi

# One dump, two questions: -a so occupancy sees every state, -l applied as a
# filter below so only listeners pay for the /proc identity walk. Captured
# outside the pipeline so ss's own exit code is observable; piped, jq succeeds
# on empty input and would mask a missing/failing ss.
sockets=$(ss -Htanp 2>/dev/null) || fail

# Below this port an unprivileged bind fails even when the port is free;
# consumers use it to caveat "free" claims. Read, not hardcoded: rootless
# container setups lower it.
ups=$(cat /proc/sys/net/ipv4/ip_unprivileged_port_start 2>/dev/null)
[[ $ups =~ ^[0-9]+$ ]] || ups=1024

# The kernel draws outbound source ports from this range, so a port inside it
# can be free at the instant of the answer and taken by the time the user
# binds. Consumers caveat reports and steer suggestions clear of it. Read, not
# hardcoded; 0/0 means unreadable, and the answer layer then makes no claim
# rather than inventing a range.
read -r eph_start eph_end < <(cat /proc/sys/net/ipv4/ip_local_port_range 2>/dev/null)
[[ $eph_start =~ ^[0-9]+$ && $eph_end =~ ^[0-9]+$ && $eph_end -ge $eph_start ]] \
  || { eph_start=0; eph_end=0; }

# Every port the machine holds in a bind-refusing state, listeners included.
# Bare port numbers, so a thousand ESTABLISHED sockets cost one small array
# and none of the per-row /proc work.
occupied_json=$(
  awk '$1 != "TIME-WAIT" { p = $4; sub(/.*:/, "", p); if (p ~ /^[0-9]+$/) print p }' <<<"$sockets" \
    | sort -n -u | jq -R -s '[split("\n")[] | select(length > 0) | tonumber]'
) || fail

ports_json=$(
  {
    # `users` is the last read variable so it captures the rest of the line;
    # process names containing spaces would otherwise break the regex match.
    while read -r state _ _ local _ users; do
      # The row table is listeners only — the -l this dump traded away for
      # occupancy, reapplied here. Everything below walks /proc per row.
      [[ $state == "LISTEN" ]] || continue
      [[ -n $local ]] || continue
      addr="${local%:*}"
      port="${local##*:}"
      [[ $port =~ ^[0-9]+$ ]] || continue

      # Strip the interface scope (127.0.0.53%lo) and IPv6 brackets; the
      # bare address is what classifies and displays.
      addr="${addr%%\%*}"
      addr="${addr#\[}"
      addr="${addr%\]}"
      case "$addr" in
        0.0.0.0 | '::' | '*') scope="any" ;;
        # ::ffff:127.* is an IPv6 socket bound to v4 loopback (the JVM's
        # usual shape) — loopback-only, not one specific interface.
        127.* | ::1 | ::ffff:127.*) scope="local" ;;
        *) scope="iface" ;;
      esac

      # A socket shared by several processes (a prefork master and its
      # workers) lists every holder, newest first. The row names the root of
      # that tree — the holder whose parent holds no copy — because a kill
      # aimed at a worker is undone by its master respawning it. systemd
      # (socket activation) wins outright: it keeps the port whatever the
      # service does, and the overlay refuses to signal it.
      pid="" name=""
      hnames=() hpids=()
      rest="$users"
      while [[ $rest =~ \(\"([^\"]+)\",pid=([0-9]+) ]]; do
        hnames+=("${BASH_REMATCH[1]}")
        hpids+=("${BASH_REMATCH[2]}")
        rest="${rest#*"${BASH_REMATCH[0]}"}"
      done
      if (( ${#hpids[@]} > 0 )); then
        name="${hnames[0]}" pid="${hpids[0]}"
        for i in "${!hpids[@]}"; do
          if [[ ${hnames[i]} == "systemd" ]]; then
            name="systemd" pid="${hpids[i]}"
            break
          fi
          pp=$(awk '/^PPid:/{print $2; exit}' "/proc/${hpids[i]}/status" 2>/dev/null)
          [[ " ${hpids[*]} " == *" $pp "* ]] || { name="${hnames[i]}" pid="${hpids[i]}"; }
        done
      fi

      cwd="-" uid="?" start="?"
      if [[ -n $pid ]]; then
        cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null || echo "-")
        # The kernel appends " (deleted)" when the directory is gone. Strip it
        # before the marker walk: the dead leaf can't match, but its live
        # ancestors still can, so an orphaned server in a rebuilt checkout
        # keeps its project name instead of showing "gone (deleted)".
        cwd="${cwd% (deleted)}"
        uid=$(awk '/^Uid:/{print $2; exit}' "/proc/$pid/status" 2>/dev/null)
        [[ $uid =~ ^[0-9]+$ ]] || uid="?"
        # starttime is stat field 22; strip through the last ")" first so a
        # comm containing spaces (or anything else) cannot shift the fields,
        # leaving starttime at index 20 of the remainder.
        statline=$(cat "/proc/$pid/stat" 2>/dev/null || echo "")
        rest="${statline##*)}"
        read -r -a statf <<<"$rest"
        start="${statf[19]:-?}"
        [[ $start =~ ^[0-9]+$ ]] || start="?"
      else
        name="?" pid="?"
      fi

      # The checkout the server was started from, not the directory it sits
      # in. Walk capped at 8 levels; stops at $HOME and / (a server started
      # from the home directory belongs to no project, and emitting the
      # username would be worse than emitting nothing).
      project=""
      if [[ -n $pid && $cwd != "-" ]]; then
        d="$cwd" root=""
        for _ in 1 2 3 4 5 6 7 8; do
          [[ -z $d || $d == "/" || $d == "$HOME" ]] && break
          for m in .git package.json Cargo.toml go.mod composer.json pyproject.toml Gemfile; do
            if [[ -e "$d/$m" ]]; then root="$d"; break; fi
          done
          [[ -n $root ]] && break
          d="${d%/*}"
        done
        if [[ -n $root ]]; then
          project="${root##*/}"
        elif [[ $cwd != "$HOME" && $cwd != "/" ]]; then
          project="${cwd##*/}"
        fi
      fi

      # Tabs/newlines in any field would corrupt the tab-delimited row — a
      # process controls its own comm and cwd, so a stray separator here is
      # how a row gets forged. Sanitize every string-valued field.
      name="${name//[$'\t\n']/ }"
      cwd="${cwd//[$'\t\n']/ }"
      addr="${addr//[$'\t\n']/ }"
      project="${project//[$'\t\n']/ }"

      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$port" "$scope" "$addr" "$name" "$pid" "$uid" "$start" "$project" "$cwd"
    done <<<"$sockets" | dedup | sort -t$'\t' -k1,1n -k5,5n
  } | jq -R -s '[split("\n")[] | select(length > 0) | split("\t") |
    {port: .[0], scope: .[1], address: .[2], process: .[3],
     pid: .[4], uid: .[5], starttime: .[6], project: .[7], cwd: .[8]}]'
) || fail

printf '{"ok": true, "unprivilegedPortStart": %s, "ephemeralStart": %s, "ephemeralEnd": %s, "ports": %s, "occupied": %s}\n' \
  "$ups" "$eph_start" "$eph_end" "$ports_json" "$occupied_json"
