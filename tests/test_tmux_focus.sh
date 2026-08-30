#!/bin/bash
# End-to-end scenario for `notify user-focus` (tests/AGENTS.md scenario 9):
# switching tmux panes marks the newly active pane Acknowledged and every
# other known pane Seen, while never touching a plain shell pane or
# downgrading OnHold/Acknowledged - the automatic (force=false) guardrail
# path that only user-focus actually exercises end to end.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_helpers.sh"
TEST_ROOT="$(mktemp -d /tmp/notify-tests.XXXXXX)"
trap 'rm -rf "$TEST_ROOT"' EXIT

ROOT_DATA_DIR="$TEST_ROOT/state"
BIN="$TEST_ROOT/bin"
mkdir -p "$ROOT_DATA_DIR" "$BIN"
date '+%s' > "$ROOT_DATA_DIR/.last_refresh"

# Four panes: %1 (about to be focused), %2 (already Acknowledged, must stay),
# %3 (OnHold, must stay), and a plain shell pane %4 with no notify session at
# all (must be skipped, never given a session dir just for being listed).
PID1=91001 PID2=91002 PID3=91003 PID4=91004
printf '%s\n' '#!/bin/bash' \
  'case "$1" in' \
  "  list-panes) printf '%%1 $PID1\\n%%2 $PID2\\n%%3 $PID3\\n%%4 $PID4\\n' ;;" \
  'esac' > "$BIN/tmux"
chmod +x "$BIN/tmux"

run_notify() {
  local render_pid="$1"
  shift
  HOME="$TEST_ROOT/home" PATH="$BIN:$PATH" \
    NOTIFY_AGENT_TYPE=generic NOTIFY_AGENT_SESSION_ID="focus-test-$render_pid" \
    NOTIFY_AGENT_WD="$PROJECT_DIR" NOTIFY_AGENT_PID="$render_pid" \
    NOTIFY_ROOT_DATA_DIR="$ROOT_DATA_DIR" NOTIFY_CONFIG_DIR="$TEST_ROOT/config" \
    NOTIFY_RENDER_PID="$render_pid" \
    bash "$NOTIFY" "$@" 2>/dev/null
}

# Seed sessions for %1, %2, %3. %4 deliberately gets none.
for pid in "$PID1" "$PID2" "$PID3"; do
  run_notify "$pid" session-start
  run_notify "$pid" event Working
done
run_notify "$PID2" update USER_STATE Acknowledged
run_notify "$PID3" update USER_STATE OnHold

# Focus pane %1 (a plain generic tmux-triggered focus, not any notify
# command's own PID resolution - user-focus reads $TMUX_PANE directly).
HOME="$TEST_ROOT/home" PATH="$BIN:$PATH" \
  NOTIFY_ROOT_DATA_DIR="$ROOT_DATA_DIR" NOTIFY_CONFIG_DIR="$TEST_ROOT/config" \
  TMUX_PANE="%1" \
  bash "$NOTIFY" user-focus 2>/dev/null

assert_file_contains "$ROOT_DATA_DIR/$PID1/state.env" "USER_STATE=Acknowledged" \
  "the focused pane becomes Acknowledged"
assert_file_contains "$ROOT_DATA_DIR/$PID2/state.env" "USER_STATE=Acknowledged" \
  "an already-Acknowledged pane is not downgraded to Seen by automatic focus"
assert_file_contains "$ROOT_DATA_DIR/$PID3/state.env" "USER_STATE=OnHold" \
  "an OnHold pane is immune to automatic focus updates"
[ -d "$ROOT_DATA_DIR/$PID4" ] && fail "a plain shell pane with no session must not get one created"

pass "tmux focus: newly active pane Acknowledged, others Seen/guarded, plain panes untouched"

# $TMUX_PANE empty (hook fired with no pane context) must be a pure no-op:
# zero panes touched, no crash.
before_hash=$(cat "$ROOT_DATA_DIR/$PID1/state.env" "$ROOT_DATA_DIR/$PID2/state.env" "$ROOT_DATA_DIR/$PID3/state.env" | shasum)
HOME="$TEST_ROOT/home" PATH="$BIN:$PATH" \
  NOTIFY_ROOT_DATA_DIR="$ROOT_DATA_DIR" NOTIFY_CONFIG_DIR="$TEST_ROOT/config" \
  TMUX_PANE="" \
  bash "$NOTIFY" user-focus 2>/dev/null
after_hash=$(cat "$ROOT_DATA_DIR/$PID1/state.env" "$ROOT_DATA_DIR/$PID2/state.env" "$ROOT_DATA_DIR/$PID3/state.env" | shasum)
[ "$before_hash" = "$after_hash" ] || fail "empty TMUX_PANE must not touch any session"
pass "tmux focus: empty TMUX_PANE is a no-op"

printf '\nAll %s tmux-focus scenarios passed.\n' "$pass_count"
