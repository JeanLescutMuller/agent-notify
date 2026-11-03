#!/bin/bash
# notify.log size cap (v5.13): over NOTIFY_LOG_MAX_BYTES (default 100 MB) the
# detached debounced refresh keeps the newest half, cut at a line start.
# See tests/AGENTS.md scenario 19.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_helpers.sh"
TEST_ROOT="$(mktemp -d /tmp/notify-tests.XXXXXX)"
trap 'rm -rf "$TEST_ROOT"' EXIT

RENDER_PID=91001

run() {   # run ROOT ARGS... (generic adapter, isolated)
  local root="$1"; shift
  HOME="$TEST_ROOT/home" NOTIFY_AGENT_TYPE=generic NOTIFY_AGENT_SESSION_ID=log-cap \
    NOTIFY_ROOT_DATA_DIR="$root" NOTIFY_CONFIG_DIR="$TEST_ROOT/config" \
    NOTIFY_RENDER_PID="$RENDER_PID" bash "$NOTIFY" "$@" </dev/null >/dev/null 2>&1
}
size_of() { wc -c < "$1" | tr -d ' '; }
refreshes() { local c; c=$(count_log_occurrences "$ROOT/notify.log" "[$RENDER_PID] refresh"); echo "${c:-0}"; }
# lines FILE N: N numbered lines of 100 bytes each.
lines() { awk -v n="$2" 'BEGIN { for (i = 1; i <= n; i++) printf "LINE %08d %85s\n", i, "x" }' > "$1"; }

# new_root NAME: a root with one registered session and a fresh debounce stamp.
new_root() {
  ROOT="$TEST_ROOT/$1"
  mkdir -p "$ROOT"
  date '+%s' > "$ROOT/.last_refresh"
  run "$ROOT" session-start
}
# due_event: one hook call with the debounced refresh due; waits for that
# refresh (it logs "refresh" after trim_log ran in the same subshell).
due_event() {
  local before; before=$(refreshes)
  echo 0 > "$ROOT/.last_refresh"
  run "$ROOT" event Working
  local i
  for i in $(seq 1 100); do
    [ "$(refreshes)" -gt "$before" ] && return 0
    sleep 0.1
  done
  fail "$1: the debounced refresh never ran"
}
all_lines_whole() {   # every line is a complete fixture line or a notify log line
  if grep -vqE '^(LINE [0-9]{8} +x$|[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8} \[)' "$1"; then
    fail "$2: a cut line was left (first: $(grep -vE '^(LINE |[0-9]{4}-)' "$1" | head -1 | cut -c1-40))"
  fi
}

test_over_cap_trims_to_newest_half() {
  new_root over
  lines "$ROOT/notify.log" 300   # 30,000 bytes
  export NOTIFY_LOG_MAX_BYTES=10000
  due_event over
  unset NOTIFY_LOG_MAX_BYTES
  local size; size=$(size_of "$ROOT/notify.log")
  [ "$size" -le 10000 ] || fail "over cap: still $size bytes"
  assert_log_contains "$ROOT/notify.log" "LINE 00000300" "over cap: the newest line is kept"
  assert_log_not_contains "$ROOT/notify.log" "LINE 00000001 " "over cap: the oldest line is gone"
  assert_log_not_contains "$ROOT/notify.log" "LINE 00000250 " "over cap: older than the newest half is gone"
  assert_log_contains "$ROOT/notify.log" "notify.log trimmed: was 3" "over cap: the trim is logged"
  [ "$(count_log_occurrences "$ROOT/notify.log" "notify.log trimmed")" -eq 1 ] || fail "over cap: trimmed once"
  all_lines_whole "$ROOT/notify.log" "over cap"
  [ -z "$(ls "$ROOT"/notify.log.trim.* 2>/dev/null)" ] || fail "over cap: no temporary file left"
  pass "over the cap: keeps the newest half, whole lines, logs it once, no temp file"
}

test_under_cap_untouched() {
  # (Exactly at the cap is not testable end to end: the hook call itself
  # appends lines before the trim runs.)
  local n
  new_root under
  lines "$ROOT/notify.log" 50   # 5,000 bytes
  cp "$ROOT/notify.log" "$ROOT/before"
  n=$(size_of "$ROOT/before")
  export NOTIFY_LOG_MAX_BYTES=10000
  due_event under
  unset NOTIFY_LOG_MAX_BYTES
  head -c "$n" "$ROOT/notify.log" | cmp -s - "$ROOT/before" || fail "under cap: old content changed"
  assert_log_not_contains "$ROOT/notify.log" "notify.log trimmed" "under cap: not trimmed"
  pass "under the cap: content untouched"
}

test_not_due_not_trimmed() {
  new_root notdue
  lines "$ROOT/notify.log" 300
  export NOTIFY_LOG_MAX_BYTES=10000
  date '+%s' > "$ROOT/.last_refresh"
  run "$ROOT" event Working
  sleep 1
  unset NOTIFY_LOG_MAX_BYTES
  assert_log_contains "$ROOT/notify.log" "LINE 00000001 " "not due: nothing trimmed between debounced refreshes"
  pass "between debounced refreshes (300 s): never trimmed"
}

test_bad_values_and_missing_file() {
  new_root badmax
  lines "$ROOT/notify.log" 300
  export NOTIFY_LOG_MAX_BYTES=abc
  due_event badmax
  unset NOTIFY_LOG_MAX_BYTES
  assert_log_contains "$ROOT/notify.log" "LINE 00000001 " "bad cap value: nothing trimmed"

  new_root missing
  rm -f "$ROOT/notify.log"
  export NOTIFY_LOG_MAX_BYTES=100000
  due_event missing
  unset NOTIFY_LOG_MAX_BYTES
  assert_log_not_contains "$ROOT/notify.log" "notify.log trimmed" "missing log: no trim, no error"
  pass "a non-numeric cap or a missing log: no trim, no error"
}

test_default_cap_100mb_real_size() {
  # The real default on a real 101 MB file: trimmed to ~50 MB, off the hook's
  # critical path (the hook call itself returns at once).
  new_root default
  lines "$ROOT/notify.log" 1060000   # 106,000,000 bytes > 104,857,600
  local t0 t1
  t0=$(date '+%s')
  echo 0 > "$ROOT/.last_refresh"
  run "$ROOT" event Working
  t1=$(date '+%s')
  [ $((t1 - t0)) -le 1 ] || fail "default cap: the hook call took $((t1 - t0)) s"
  local i
  for i in $(seq 1 200); do
    grep -qF "notify.log trimmed" "$ROOT/notify.log" 2>/dev/null && break
    sleep 0.1
  done
  local size; size=$(size_of "$ROOT/notify.log")
  [ "$size" -le 52500000 ] && [ "$size" -ge 52000000 ] || fail "default cap: $size bytes after trim (expected ~50 MB)"
  assert_log_contains "$ROOT/notify.log" "LINE 01060000" "default cap: newest line kept"
  assert_log_contains "$ROOT/notify.log" "(cap 104857600)" "default cap is 100 MB"
  rm -f "$ROOT/notify.log"
  pass "default cap 100 MB on a real 106 MB file: trimmed to ~50 MB in the background"
}

test_over_cap_trims_to_newest_half
test_under_cap_untouched
test_not_due_not_trimmed
test_bad_values_and_missing_file
test_default_cap_100mb_real_size
printf '\nAll %s log-cap scenarios passed.\n' "$pass_count"
