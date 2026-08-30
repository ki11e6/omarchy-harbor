#!/bin/bash
#
# Regression fixtures for the probe, dedup, kill helper, and answer logic.
# Each defends a defect fixed in docs/plans/2026-08-30-port-answer-machine.md
# (mapping in its Testing Strategy table). Run from anywhere:
#   bash test/fixtures.sh
# Needs: bash, jq, awk, iproute2 (ss), node, python3.

set -u
cd "$(dirname "$0")/.."

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

# ---------------------------------------------------------------- syntax
bash -n list-ports.sh || fail "list-ports.sh syntax"
bash -n kill-port.sh || fail "kill-port.sh syntax"

# ---------------------------------------------------------------- dedup
row_local=$'3000\tlocal\t127.0.0.1\tnode\t123\t1000\t555\tmyapp\t/x'
row_any=$'3000\tany\t0.0.0.0\tnode\t123\t1000\t555\tmyapp\t/x'
a=$(printf '%s\n%s\n' "$row_local" "$row_any" | bash list-ports.sh --dedup)
b=$(printf '%s\n%s\n' "$row_any" "$row_local" | bash list-ports.sh --dedup)
[[ "$a" == "$b" ]] || fail "scope union is input-order-dependent"
[[ "$a" == $'3000\tany\t0.0.0.0\tnode\t123\t1000\t555\tmyapp\t/x' ]] \
  || fail "scope winner must supply scope AND address"

row_unnamed=$'3000\tlocal\t127.0.0.1\t?\t?\t?\t?\t\t-'
row_named=$'3000\tlocal\t127.0.0.1\tnode\t123\t1000\t555\tmyapp\t/x'
for order in "$row_unnamed\n$row_named" "$row_named\n$row_unnamed"; do
  # shellcheck disable=SC2059
  printf "$order\n" | bash list-ports.sh --dedup | grep -q $'\tnode\t' \
    || fail "named owner must win dedup in both input orders"
done

[[ -z $(printf '4000\tlocal\t127.0.0.1\tnode\t123\t1000\t555\t/x\n' | bash list-ports.sh --dedup) ]] \
  || fail "arity guard must drop rows that are not nine fields"

# ---------------------------------------------------------------- envelope
bash list-ports.sh | jq -e '
  .ok == true and (.unprivilegedPortStart | type == "number") and
  (.ports | all(has("port") and has("scope") and has("address") and
                has("process") and has("pid") and has("uid") and
                has("starttime") and has("project") and has("cwd")))
' >/dev/null || fail "success envelope / nine-field schema"

PATH=/nonexistent /usr/bin/bash list-ports.sh \
  | jq -e '.ok == false and (.ports | length) == 0' >/dev/null \
  || fail "failure path must report ok:false, never an empty (all-free) list"

# ------------------------------------------------- live probe: walk + forgery
srv1="" srv2="" srv3=""
cleanup() {
  [[ -n $srv1 ]] && kill "$srv1" 2>/dev/null
  [[ -n $srv2 ]] && kill "$srv2" 2>/dev/null
  [[ -n $srv3 ]] && kill "$srv3" 2>/dev/null
  rm -rf /tmp/harbor-fx
}
trap cleanup EXIT

for p in 18391 18392 18393; do
  [[ -z $(ss -Htln "sport = :$p") ]] || fail "fixture port $p is already in use"
done

mkdir -p /tmp/harbor-fx/app/.git /tmp/harbor-fx/app/sub/public
(cd /tmp/harbor-fx/app/sub/public && exec python3 -m http.server 18391) >/dev/null 2>&1 &
srv1=$!
baddir=$'/tmp/harbor-fx/bad\tt\nn'
mkdir -p "$baddir"
(cd "$baddir" && exec python3 -m http.server 18392) >/dev/null 2>&1 &
srv2=$!
deep=/tmp/harbor-fx/a/b/c/d/e/f/g/h/i/j/k/l/m/n/o/p/q/r/s/leaf
mkdir -p "$deep"
(cd "$deep" && exec python3 -m http.server 18393) >/dev/null 2>&1 &
srv3=$!
sleep 1

out=$(bash list-ports.sh)
[[ $(jq -r '.ports[] | select(.port=="18391") | .project' <<<"$out") == "app" ]] \
  || fail "marker walk: public/-style cwd must report the checkout, not public"
[[ $(jq '[.ports[] | select(.port=="18392")] | length' <<<"$out") == 1 ]] \
  || fail "a tab/newline cwd must yield exactly one row, never a forged extra"
jq -e '.ports[] | select(.port=="18392") | .cwd | test("[\\t\\n]") | not' <<<"$out" >/dev/null \
  || fail "tab/newline must be sanitized out of cwd"
[[ $(jq -r '.ports[] | select(.port=="18393") | .project' <<<"$out") == "leaf" ]] \
  || fail "markerless deep path must fall back to the leaf basename (capped walk)"

# ---------------------------------------------------------------- kill helper
sleep 300 &
tp=$!
sleep 0.2
uid=$(id -u)
start=$(sed 's/.*) //' "/proc/$tp/stat" | awk '{print $20}')
bash kill-port.sh "$tp" "$uid" "$((start + 1))" TERM && fail "wrong starttime must be refused"
kill -0 "$tp" 2>/dev/null || fail "refused kill must not signal"
bash kill-port.sh "$tp" "$((uid + 1))" "$start" TERM && fail "wrong uid must be refused"
bash kill-port.sh "$tp" "$uid" "$start" HUP && fail "non-TERM/KILL signal must be refused"
bash kill-port.sh 1 0 1 TERM && fail "pid 1 must be refused"
bash kill-port.sh "$tp" "$uid" "$start" TERM || fail "exact identity must signal"
sleep 0.3
kill -0 "$tp" 2>/dev/null && fail "matched TERM should have killed the process"
bash kill-port.sh "$tp" "$uid" "$start" TERM && fail "dead pid must be refused"

# ---------------------------------------------------------------- answers.js
node test/answers-test.js || fail "answers.js unit checks"

echo "ALL_FIXTURES_PASS"
