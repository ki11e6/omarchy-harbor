#!/bin/bash
#
# Signal a process only if it is still the process the caller saw.
#   argv: pid uid starttime signal(TERM|KILL)
#
# Re-reads /proc/<pid>/status (Uid) and /proc/<pid>/stat (starttime — field
# 22, read as field 20 after stripping through the last ")" so a comm with
# spaces cannot shift it) and refuses on any mismatch, so a recycled PID
# cannot inherit a signal aimed at its predecessor.
#
# This narrows the exit-vs-signal race to microseconds; it does not close it
# (that would need pidfd_send_signal, unreachable from shell).

set -u

pid="${1:-}" want_uid="${2:-}" want_start="${3:-}" sig="${4:-TERM}"

[[ $pid =~ ^[0-9]+$ ]] || exit 1
(( pid > 1 )) || exit 1
[[ $want_uid =~ ^[0-9]+$ ]] || exit 1
[[ $want_start =~ ^[0-9]+$ ]] || exit 1
case "$sig" in TERM | KILL) ;; *) exit 1 ;; esac

status=$(cat "/proc/$pid/status" 2>/dev/null) || exit 1
statline=$(cat "/proc/$pid/stat" 2>/dev/null) || exit 1

live_uid=$(awk '/^Uid:/{print $2; exit}' <<<"$status")

rest="${statline##*)}"
# set -f: the word-split below is unquoted by design; keep it glob-inert.
set -f
# shellcheck disable=SC2086
set -- $rest
set +f
live_start="${20:-}"

[[ $live_uid == "$want_uid" ]] || exit 1
[[ $live_start == "$want_start" ]] || exit 1

exec kill -s "$sig" "$pid"
