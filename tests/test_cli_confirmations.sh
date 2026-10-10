#!/bin/bash
# End-to-end scenario for the one-line stdout confirmation printed by the
# commands a human types (update, wipe, refresh, <renderer>), and for the
# silence of every hook-driven command (session-start, event, session-end,
# init) and of NOTIFY_QUIET=true callers such as the tmux popup menu.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_helpers.sh"
TEST_ROOT="$(mktemp -d /tmp/notify-tests.XXXXXX)"
trap 'rm -rf "$TEST_ROOT"' EXIT

ROOT_DATA_DIR="$TEST_ROOT/state"
CONFIG_DIR="$TEST_ROOT/config"
BIN="$TEST_ROOT/bin"
mkdir -p "$ROOT_DATA_DIR" "$BIN" "$TEST_ROOT/home"
date '+%s' > "$ROOT_DATA_DIR/.last_refresh"
# Keep the real tmux out of the test; init then skips the hooks block.
printf '%s\n' '#!/bin/bash' 'exit 1' > "$BIN/tmux"
chmod +x "$BIN/tmux"

# A live process the session can belong to, so refresh does not prune it.
sleep 300 &
RENDER_PID=$!
trap 'kill "$RENDER_PID" 2>/dev/null; rm -rf "$TEST_ROOT"' EXIT

run_notify() {
  HOME="$TEST_ROOT/home" PATH="$BIN:$PATH" TMUX_PANE="" \
    NOTIFY_AGENT_TYPE=generic NOTIFY_AGENT_SESSION_ID=confirm-test \
    NOTIFY_AGENT_WD="$PROJECT_DIR" NOTIFY_AGENT_PID="$RENDER_PID" \
    NOTIFY_ROOT_DATA_DIR="$ROOT_DATA_DIR" NOTIFY_CONFIG_DIR="$CONFIG_DIR" \
    NOTIFY_RENDER_PID="$RENDER_PID" \
    bash "$NOTIFY" "$@" 2>/dev/null
}

expect_out() {
  local expected="$1"; shift
  local out; out=$(run_notify "$@")
  [ "$out" = "$expected" ] || fail "notify $* prints '$expected' (got '$out')"
}

expect_silent() {
  local out; out=$(run_notify "$@")
  [ -z "$out" ] || fail "notify $* stays silent (got '$out')"
}

expect_silent session-start
expect_silent event Working
expect_silent init
pass "hook-driven commands print nothing"

expect_out "USER_STATE=OnHold (session $RENDER_PID)" update USER_STATE OnHold
expect_out "USER_STATE already OnHold (session $RENDER_PID)" update USER_STATE OnHold
expect_out "AGENT_STATE=Idle (session $RENDER_PID)" update AGENT_STATE Idle
pass "update confirms a change and an unchanged value"

expect_out "sound-tts: enabled=false (session $RENDER_PID)" sound-tts disable
expect_out "sound-tts: enabled=true (global, all sessions)" sound-tts enable --global
expect_out "sound-bell: Finished=3 WaitingForUser=4 (session $RENDER_PID)" sound-bell Finished=3 WaitingForUser=4
expect_out "sound-tts: nothing changed (expected enable, disable or key=value)" sound-tts bogus
pass "renderer settings confirm scope and every key written"

[ "$(NOTIFY_QUIET=true run_notify update USER_STATE Pending)" = "" ] || fail "NOTIFY_QUIET=true silences update"
[ "$(NOTIFY_QUIET=true run_notify sound-tts disable --global)" = "" ] || fail "NOTIFY_QUIET=true silences renderer settings"
pass "NOTIFY_QUIET=true silences confirmations (tmux popup menu)"

expect_out "refreshed (session $RENDER_PID)" refresh
expect_out "wiped (session $RENDER_PID)" wipe
pass "refresh and wipe confirm"

run_notify session-start >/dev/null
expect_silent session-end
pass "session-end (hook) stays silent"

echo "All $pass_count CLI confirmation checks passed."
