#!/bin/bash
# End-to-end scenario for renderer settings precedence (tests/AGENTS.md
# scenario 10): default settings.json < persistent global override <
# per-session override, verified through the real merge in
# resolve_renderer_settings via `notify <renderer> key=value [--global]` and
# `notify status`/`notify event` - not a hand-built RENDERER_SETTINGS var.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_helpers.sh"
TEST_ROOT="$(mktemp -d /tmp/notify-tests.XXXXXX)"
trap 'rm -rf "$TEST_ROOT"' EXIT

ROOT_DATA_DIR="$TEST_ROOT/state"
CONFIG_DIR="$TEST_ROOT/config"
BIN="$TEST_ROOT/bin"
FAKE_TTY="$TEST_ROOT/tty"
RENDER_PID=92001
mkdir -p "$ROOT_DATA_DIR" "$BIN"
date '+%s' > "$ROOT_DATA_DIR/.last_refresh"
: > "$FAKE_TTY"

# A real tty is required for sound-bell to actually ring - resolve_client_tty
# needs a tmux session to resolve one deterministically in a headless test,
# so fake just enough tmux to satisfy it (same technique test_renderers uses).
printf '%s\n' '#!/bin/bash' \
  'case "$1" in' \
  '  display-message) printf "%s\n" "settings-test-session" ;;' \
  '  list-clients) printf "100 %s\n" "$FAKE_TTY" ;;' \
  'esac' > "$BIN/tmux"
chmod +x "$BIN/tmux"
export FAKE_TTY

run_notify() {
  HOME="$TEST_ROOT/home" PATH="$BIN:$PATH" TMUX_PANE="%1" \
    NOTIFY_AGENT_TYPE=generic NOTIFY_AGENT_SESSION_ID=settings-test \
    NOTIFY_AGENT_WD="$PROJECT_DIR" NOTIFY_AGENT_PID="$RENDER_PID" \
    NOTIFY_ROOT_DATA_DIR="$ROOT_DATA_DIR" NOTIFY_CONFIG_DIR="$CONFIG_DIR" \
    NOTIFY_RENDER_PID="$RENDER_PID" \
    bash "$NOTIFY" "$@" 2>/dev/null
}

run_notify session-start

# sound-bell's shipped default is {"Finished":1,"WaitingForUser":2}.
DEFAULT_FINISHED=$(jq -r '.Finished' "$PROJECT_DIR/release/renderers.d/sound-bell/settings.json")
[ "$DEFAULT_FINISHED" = "1" ] || fail "precondition: sound-bell default Finished is 1"

# Global override changes "Finished" only; session override changes
# "WaitingForUser" only - proves each layer's OWN key wins without needing
# to touch the other layers' keys.
run_notify sound-bell Finished=5 --global
run_notify sound-bell WaitingForUser=9

status_out="$(run_notify status)"
echo "$status_out" | grep -qF '"Finished":1' || fail "status shows the unmodified default file"
echo "$status_out" | grep -qF '"Finished":5' || fail "status shows the global override"
echo "$status_out" | grep -qF '"WaitingForUser":9' || fail "status shows the session override"

# The merge must actually flow through to renderer dispatch, not just to
# `status` display: Finished should ring 5 times (global), WaitingForUser
# should ring 9 times (session) - i.e. resolve_renderer_settings itself,
# not a hand-built settings blob.
run_notify event Finished
assert_log_contains "$ROOT_DATA_DIR/notify.log" "sound-bell: ring count=5" \
  "global override reaches the actual renderer for Finished"

run_notify update USER_STATE Pending
run_notify event WaitingForUser
assert_log_contains "$ROOT_DATA_DIR/notify.log" "sound-bell: ring count=9" \
  "session override reaches the actual renderer for WaitingForUser, taking priority over the global layer"

pass "renderer settings: default < global < session merge reaches real dispatch"

# `enabled=false` at session scope must override a default-enabled renderer,
# both in `notify status`'s label and in actual dispatch - this is exactly
# the has("enabled") vs `//` distinction CLAUDE.md warns about, since a
# default settings.json has no "enabled" key at all.
run_notify sound-bell enabled=false
status_out="$(run_notify status)"
echo "$status_out" | grep -qF '== sound-bell: disabled ==' || fail "status labels a session-disabled renderer as disabled"

before_rings=$(count_log_occurrences "$ROOT_DATA_DIR/notify.log" "sound-bell: ring")
run_notify update USER_STATE Seen
run_notify update AGENT_STATE Working
after_rings=$(count_log_occurrences "$ROOT_DATA_DIR/notify.log" "sound-bell: ring")
[ "$before_rings" -eq "$after_rings" ] || fail "a session-disabled renderer must not ring on a later state change"
assert_log_contains "$ROOT_DATA_DIR/notify.log" "RENDER AGENT_STATE_UPDATE sound-bell skip (disabled)" \
  "the dispatcher itself skips the disabled renderer"

pass "renderer settings: session-scoped enabled=false overrides a default-enabled renderer"

printf '\nAll %s renderer-settings scenarios passed.\n' "$pass_count"
