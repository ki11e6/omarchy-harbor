#!/bin/bash
#
# Emit all listening localhost TCP ports as a JSON array of
# {port, process, pid, cwd} objects, sorted by port, one entry per port.
# When a port has both a named and an unknown ("?") owner across address
# families, the named row wins.

set -o pipefail

{
  # `users` is the last read variable so it captures the rest of the line;
  # process names containing spaces would otherwise break the regex match.
  ss -Htlnp 2>/dev/null | while read -r _ _ _ local _ users; do
    addr="${local%:*}"
    port="${local##*:}"
    case "$addr" in
      127.* | 0.0.0.0 | '*' | '[::]' | '[::1]') ;;
      *) continue ;;
    esac

    pid="" name=""
    if [[ $users =~ \(\"([^\"]+)\",pid=([0-9]+) ]]; then
      name="${BASH_REMATCH[1]}"
      pid="${BASH_REMATCH[2]}"
    fi

    cwd="-"
    if [[ -n $pid ]]; then
      cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null || echo "-")
    else
      name="?" pid="?"
    fi

    printf '%s\t%s\t%s\t%s\n' "$port" "$name" "$pid" "$cwd"
  done | awk -F'\t' '
    {
      named = ($3 != "?")
      if (!($1 in best) || (named && !bestNamed[$1])) { best[$1] = $0; bestNamed[$1] = named }
    }
    END { for (p in best) print best[p] }
  ' | sort -n -t$'\t' -k1,1
} | jq -R -s '[split("\n")[] | select(length > 0) | split("\t") |
  {port: .[0], process: .[1], pid: .[2], cwd: .[3]}]'
