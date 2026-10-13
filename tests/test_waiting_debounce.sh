#!/bin/bash
# End-to-end scenario for the WaitingForUser debounce in sound-bell/sound-tts
# (tests/AGENTS.md: see also the 2026-09-16 investigation in HISTORY.md - Codex's
# PermissionRequest hook fires WaitingForUser even when auto-approved within
# seconds, with no payload signal to tell that apart from a real wait). The
# debounce lives entirely inside the two sound renderers, not the core: a
# WaitingForUser still writes state.env and renders terminal-title/tmux-pane-bg
# immediately, only the actual ring/speak is held back and re-checked against
# disk state before firing.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_helpers.sh"
TEST_ROOT="$(mktemp -d /tmp/notify-tests.XXXXXX)"
trap 'rm -rf "$TEST_ROOT"' EXIT

ROOT_DATA_DIR="$TEST_ROOT/state"
CONFIG_DIR="$TEST_ROOT/config"
BIN="$TEST_ROOT/bin"
FAKE_TTY="$TEST_ROOT/tty"
mkdir -p "$ROOT_DATA_DIR" "$BIN"
date '+%s' > "$ROOT_DATA_DIR/.last_refresh"
: > "$FAKE_TTY"

# Same fake tmux technique as test_renderer_settings.sh: just enough for
# resolve_client_tty to hand sound-bell/sound-tts a writable "tty".
printf '%s\n' '#!/bin/bash' \
  'case "$1" in' \
  '  display-message) printf "%s\n" "debounce-test-session" ;;' \
  '  list-clients) printf "100 %s\n" "$FAKE_TTY" ;;' \
  'esac' > "$BIN/tmux"
chmod +x "$BIN/tmux"
export FAKE_TTY

run_notify() {
  local render_pid="$1"; shift
  HOME="$TEST_ROOT/home" PATH="$BIN:$PATH" TMUX_PANE="%1" \
    NOTIFY_AGENT_TYPE=generic NOTIFY_AGENT_SESSION_ID="debounce-test-$render_pid" \
    NOTIFY_AGENT_WD="$PROJECT_DIR" NOTIFY_AGENT_PID="$render_pid" \
    NOTIFY_ROOT_DATA_DIR="$ROOT_DATA_DIR" NOTIFY_CONFIG_DIR="$CONFIG_DIR" \
    NOTIFY_RENDER_PID="$render_pid" \
    bash "$NOTIFY" "$@" 2>/dev/null
}

DEBOUNCE_SECS=1
SETTLE_SECS=2  # > DEBOUNCE_SECS, with margin for scheduling jitter

# --- Scenario 1: fast auto-clear never rings/speaks -----------------------
PID_FAST=93001
run_notify "$PID_FAST" session-start
run_notify "$PID_FAST" sound-bell waiting_debounce_secs=$DEBOUNCE_SECS
run_notify "$PID_FAST" sound-tts waiting_debounce_secs=$DEBOUNCE_SECS

run_notify "$PID_FAST" event WaitingForUser
assert_log_contains "$ROOT_DATA_DIR/notify.log" "sound-bell: debounce ${DEBOUNCE_SECS}s before ringing" \
  "fast-clear: sound-bell debounces instead of ringing immediately"
assert_log_contains "$ROOT_DATA_DIR/notify.log" "sound-tts: debounce ${DEBOUNCE_SECS}s before speaking" \
  "fast-clear: sound-tts debounces instead of speaking immediately"

# terminal-title/tmux-pane-bg are NOT sound renderers - they must still
# reflect WaitingForUser right away, proving the debounce is scoped to the
# two sound renderers only, not the whole notify state.
assert_file_contains "$ROOT_DATA_DIR/$PID_FAST/state.env" "AGENT_STATE=WaitingForUser" \
  "fast-clear: state.env updates immediately, unaffected by the sound-renderer debounce"

# The auto-approval clears well inside the debounce window.
run_notify "$PID_FAST" event Working
sleep "$SETTLE_SECS"

assert_log_not_contains "$ROOT_DATA_DIR/notify.log" "sound-bell: ring count=2" \
  "fast-clear: sound-bell never rings once state moved on within the debounce window"
assert_log_not_contains "$ROOT_DATA_DIR/notify.log" "sound-tts: speak" \
  "fast-clear: sound-tts never speaks once state moved on within the debounce window"
assert_log_contains "$ROOT_DATA_DIR/notify.log" "sound-bell: debounce cancelled" \
  "fast-clear: sound-bell logs the cancellation"
assert_log_contains "$ROOT_DATA_DIR/notify.log" "sound-tts: debounce cancelled" \
  "fast-clear: sound-tts logs the cancellation"

pass "sound-bell/sound-tts: a WaitingForUser cleared within the debounce window never rings or speaks"

# --- Scenario 2: a real, sustained wait still alerts -----------------------
PID_REAL=93002
run_notify "$PID_REAL" session-start
run_notify "$PID_REAL" sound-bell waiting_debounce_secs=$DEBOUNCE_SECS
run_notify "$PID_REAL" sound-tts waiting_debounce_secs=$DEBOUNCE_SECS

run_notify "$PID_REAL" event WaitingForUser
sleep "$SETTLE_SECS"

assert_log_contains "$ROOT_DATA_DIR/notify.log" "sound-bell: ring count=2" \
  "sustained-wait: sound-bell rings once the debounce window elapses with nothing superseding it"
assert_log_contains "$ROOT_DATA_DIR/notify.log" "sound-tts: speak" \
  "sustained-wait: sound-tts speaks once the debounce window elapses with nothing superseding it"

pass "sound-bell/sound-tts: a WaitingForUser that outlives the debounce window still rings and speaks"

# --- Scenario 3: waiting_debounce_secs=0 stays fully synchronous ----------
PID_ZERO=93003
run_notify "$PID_ZERO" session-start
run_notify "$PID_ZERO" sound-bell waiting_debounce_secs=0
run_notify "$PID_ZERO" event WaitingForUser
assert_log_contains "$ROOT_DATA_DIR/notify.log" "[$PID_ZERO]     sound-bell: ring count=2" \
  "waiting_debounce_secs=0: sound-bell rings synchronously, no debounce log line"
assert_log_not_contains "$ROOT_DATA_DIR/notify.log" "[$PID_ZERO]     sound-bell: debounce" \
  "waiting_debounce_secs=0: no debounce path is taken at all"

pass "sound-bell: waiting_debounce_secs=0 preserves the old fully-synchronous behavior"

# --- Scenario 4: background work never holds the hook's pipes -------------
# Codex waits for EOF on a hook's stdout/stderr, not just for its exit: a
# debounce subshell (or the debounced `refresh --all`) still holding those
# pipes kept PermissionRequest running past its 2s deadline ("Hook failed",
# 2026-10-06) and got killed before ringing. Reproduce that runner shape by
# piping both streams into cat, with the periodic refresh also due.
PID_PIPE=93004
PIPE_DEBOUNCE_SECS=4
run_notify "$PID_PIPE" session-start
run_notify "$PID_PIPE" sound-bell waiting_debounce_secs=$PIPE_DEBOUNCE_SECS
run_notify "$PID_PIPE" sound-tts waiting_debounce_secs=$PIPE_DEBOUNCE_SECS
echo 0 > "$ROOT_DATA_DIR/.last_refresh"

started=$(date '+%s')
HOME="$TEST_ROOT/home" PATH="$BIN:$PATH" TMUX_PANE="%1" \
  NOTIFY_AGENT_TYPE=generic NOTIFY_AGENT_SESSION_ID="debounce-test-$PID_PIPE" \
  NOTIFY_AGENT_WD="$PROJECT_DIR" NOTIFY_AGENT_PID="$PID_PIPE" \
  NOTIFY_ROOT_DATA_DIR="$ROOT_DATA_DIR" NOTIFY_CONFIG_DIR="$CONFIG_DIR" \
  NOTIFY_RENDER_PID="$PID_PIPE" \
  bash "$NOTIFY" event WaitingForUser 2>&1 | cat > /dev/null
elapsed=$(( $(date '+%s') - started ))
[ "$elapsed" -lt 3 ] \
  || fail "piped-hook: event WaitingForUser held its pipes ${elapsed}s (debounce ${PIPE_DEBOUNCE_SECS}s leaked into the hook)"

# Let the detached job finish inside TEST_ROOT before the EXIT trap removes it.
run_notify "$PID_PIPE" event Working
sleep $((PIPE_DEBOUNCE_SECS + 1))
assert_log_contains "$ROOT_DATA_DIR/notify.log" "[$PID_PIPE]     sound-bell: debounce cancelled" \
  "piped-hook: the detached sound-bell debounce still runs to completion"

pass "sound-bell/sound-tts/refresh: background work is detached from the hook's stdout/stderr"

printf '\nAll %s waiting-debounce scenarios passed.\n' "$pass_count"
