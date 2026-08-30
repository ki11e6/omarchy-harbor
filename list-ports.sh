#!/bin/bash
#
# Emit listening TCP ports as {"ok": bool, "unprivilegedPortStart": n,
# "ports": [...]}, where ports holds {port, scope, address, process, pid,
# uid, starttime, project, cwd} objects (nine fields — the arity guard and
# the jq assembly both depend on that count), sorted by port, one entry per
# port.
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
#   any    0.0.0.0, ::, *          reachable from the network
#   local  127.*, ::1              loopback only
#   iface  anything else           one specific interface
#
# Dedup collapses address families to one row per port: identity fields
# (process, pid, uid, starttime, cwd) come from the socket with a named
# owner; scope comes from the widest bind, and address from the socket that
# won the scope union, so scope and address always agree.
#
# "ok" is false when the socket table could not be read (ss missing or
# failing) or the JSON assembly failed. An empty machine and a failed probe
# are different answers and must never be conflated — the wrapper carries
# ss's own verdict so the overlay never renders a failure as "all free".

set -o pipefail

fail() {
  printf '{"ok": false, "unprivilegedPortStart": 1024, "ports": []}\n'
  exit 0
}

# The dedup/union pass, callable standalone (--dedup, rows on stdin) so the
# fixture tests can exercise it directly.
dedup() {
  awk -F'\t' '
    function rank(s) { return s == "any" ? 3 : s == "iface" ? 2 : 1 }
    NF == 9 {
      p = $1
      if (!(p in seen)) { seen[p] = 1 }
      if (!(p in srank) || rank($2) > srank[p]) { srank[p] = rank($2); scope[p] = $2; adr[p] = $3 }
      named = ($5 != "?")
      id = $4 "\t" $5 "\t" $6 "\t" $7 "\t" $8 "\t" $9
      if (!(p in ident) || (named && !identNamed[p])) { ident[p] = id; identNamed[p] = named }
    }
    END { for (p in seen) print p "\t" scope[p] "\t" adr[p] "\t" ident[p] }
  '
}

if [[ "${1:-}" == "--dedup" ]]; then
  dedup
  exit 0
fi

# Capture the dump outside the pipeline so ss's own exit code is observable;
# piped, jq succeeds on empty input and would mask a missing/failing ss.
sockets=$(ss -Htlnp 2>/dev/null) || fail

# Below this port an unprivileged bind fails even when the port is free;
# consumers use it to caveat "free" claims. Read, not hardcoded: rootless
# container setups lower it.
ups=$(cat /proc/sys/net/ipv4/ip_unprivileged_port_start 2>/dev/null)
[[ $ups =~ ^[0-9]+$ ]] || ups=1024

ports_json=$(
  {
    # `users` is the last read variable so it captures the rest of the line;
    # process names containing spaces would otherwise break the regex match.
    while read -r _ _ _ local _ users; do
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
        127.* | ::1) scope="local" ;;
        *) scope="iface" ;;
      esac

      pid="" name=""
      if [[ $users =~ \(\"([^\"]+)\",pid=([0-9]+) ]]; then
        name="${BASH_REMATCH[1]}"
        pid="${BASH_REMATCH[2]}"
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
    done <<<"$sockets" | dedup | sort -n -t$'\t' -k1,1
  } | jq -R -s '[split("\n")[] | select(length > 0) | split("\t") |
    {port: .[0], scope: .[1], address: .[2], process: .[3],
     pid: .[4], uid: .[5], starttime: .[6], project: .[7], cwd: .[8]}]'
) || fail

printf '{"ok": true, "unprivilegedPortStart": %s, "ports": %s}\n' "$ups" "$ports_json"
