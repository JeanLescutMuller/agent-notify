#!/bin/bash
# notify.log size cap (v5.14): over NOTIFY_LOG_MAX_BYTES (default 100 MB) the
# detached debounced refresh renames it to notify.log.1 (no copy).
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
now_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time * 1000'; }
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
test_over_cap_rotates() {
  new_root over
  lines "$ROOT/notify.log" 300   # 30,000 bytes
  cp "$ROOT/notify.log" "$ROOT/before"
  export NOTIFY_LOG_MAX_BYTES=10000
  due_event over
  [ -f "$ROOT/notify.log.1" ] || fail "over cap: notify.log.1 created"
  head -c "$(size_of "$ROOT/before")" "$ROOT/notify.log.1" | cmp -s - "$ROOT/before" \
    || fail "over cap: notify.log.1 holds the old log unchanged"
  assert_log_not_contains "$ROOT/notify.log" "LINE 00000300" "over cap: the new log starts empty of old lines"
  assert_log_contains "$ROOT/notify.log" "notify.log rotated to notify.log.1 (was 3" "over cap: the rotation is logged in the new log"
  [ "$(size_of "$ROOT/notify.log")" -lt 10000 ] || fail "over cap: the new log is small"

  # A second rotation replaces notify.log.1: at most two files, ever.
  lines "$ROOT/notify.log" 200
  printf 'SECOND\n' >> "$ROOT/notify.log"
  due_event over-again
  unset NOTIFY_LOG_MAX_BYTES
  assert_log_contains "$ROOT/notify.log.1" "SECOND" "second rotation: notify.log.1 replaced by the newer log"
  assert_log_not_contains "$ROOT/notify.log.1" "LINE 00000300" "second rotation: the oldest log is gone"
  [ -z "$(ls "$ROOT"/notify.log.2 "$ROOT"/notify.log.*.* 2>/dev/null)" ] || fail "second rotation: no third file"
  pass "over the cap: renamed to notify.log.1 unchanged; a second rotation replaces it (two files at most)"
}

test_under_cap_untouched() {
  # (Exactly at the cap is not testable end to end: the hook call itself
  # appends lines before the rotation runs.)
  local n
  new_root under
  lines "$ROOT/notify.log" 50   # 5,000 bytes
  cp "$ROOT/notify.log" "$ROOT/before"
  n=$(size_of "$ROOT/before")
  export NOTIFY_LOG_MAX_BYTES=10000
  due_event under
  unset NOTIFY_LOG_MAX_BYTES
  head -c "$n" "$ROOT/notify.log" | cmp -s - "$ROOT/before" || fail "under cap: old content changed"
  assert_log_not_contains "$ROOT/notify.log" "notify.log rotated" "under cap: not rotated"
  [ ! -e "$ROOT/notify.log.1" ] || fail "under cap: no notify.log.1"
  pass "under the cap: content untouched"
}

test_not_due_not_rotated() {
  new_root notdue
  lines "$ROOT/notify.log" 300
  export NOTIFY_LOG_MAX_BYTES=10000
  date '+%s' > "$ROOT/.last_refresh"
  run "$ROOT" event Working
  sleep 1
  unset NOTIFY_LOG_MAX_BYTES
  assert_log_contains "$ROOT/notify.log" "LINE 00000001 " "not due: nothing rotated between debounced refreshes"
  [ ! -e "$ROOT/notify.log.1" ] || fail "not due: no notify.log.1"
  pass "between debounced refreshes (300 s): never rotated"
}

test_bad_values_and_missing_file() {
  new_root badmax
  lines "$ROOT/notify.log" 300
  export NOTIFY_LOG_MAX_BYTES=abc
  due_event badmax
  unset NOTIFY_LOG_MAX_BYTES
  assert_log_contains "$ROOT/notify.log" "LINE 00000001 " "bad cap value: nothing rotated"

  new_root missing
  rm -f "$ROOT/notify.log"
  export NOTIFY_LOG_MAX_BYTES=100000
  due_event missing
  unset NOTIFY_LOG_MAX_BYTES
  assert_log_not_contains "$ROOT/notify.log" "notify.log rotated" "missing log: no rotation, no error"
  pass "a non-numeric cap or a missing log: no rotation, no error"
}

test_default_cap_100mb_real_size() {
  # The real default on a real 106 MB file: rotated by a rename, so the whole
  # background step (refresh included) finishes within a second, and the hook
  # call itself returns at once.
  new_root default
  lines "$ROOT/notify.log" 1060000   # 106,000,000 bytes > 104,857,600
  local t0 t1 t2 i
  t0=$(now_ms)
  echo 0 > "$ROOT/.last_refresh"
  run "$ROOT" event Working
  t1=$(now_ms)
  # Limit = the Stop hook's 2 s timeout (plugin.json); the rename is not on this path.
  [ $((t1 - t0)) -lt 2000 ] || fail "default cap: the hook call took $((t1 - t0)) ms"
  for i in $(seq 1 100); do
    [ -f "$ROOT/notify.log.1" ] && grep -qF "notify.log rotated" "$ROOT/notify.log" 2>/dev/null && break
    sleep 0.05
  done
  t2=$(now_ms)
  [ $((t2 - t0)) -lt 3000 ] || fail "default cap: rotation done $((t2 - t0)) ms after the call"
  [ "$(size_of "$ROOT/notify.log.1")" -ge 106000000 ] || fail "default cap: notify.log.1 holds the whole old log"
  assert_log_contains "$ROOT/notify.log" "(was 106" "default cap: rotated at 106 MB"
  assert_log_contains "$ROOT/notify.log" "cap 104857600)" "default cap is 100 MB"
  rm -f "$ROOT/notify.log.1"
  pass "default cap 100 MB on a real 106 MB file: renamed within a second, hook call instant"
}

test_over_cap_rotates
test_under_cap_untouched
test_not_due_not_rotated
test_bad_values_and_missing_file
test_default_cap_100mb_real_size
printf '\nAll %s log-cap scenarios passed.\n' "$pass_count"
