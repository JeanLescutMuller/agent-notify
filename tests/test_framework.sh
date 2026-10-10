#!/bin/bash
# Integration tests for adapter -> framework -> renderer boundaries.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_helpers.sh"
TEST_ROOT="$(mktemp -d /tmp/notify-tests.XXXXXX)"
export TEST_ROOT
TEST_PIDS=""
cleanup() {
  local pid
  for pid in $TEST_PIDS; do kill "$pid" 2>/dev/null || true; done
  for pid in $TEST_PIDS; do wait "$pid" 2>/dev/null || true; done
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

run_notify() {
  local root="$1" adapter="$2" render_pid="$3"
  shift 3
  mkdir -p "$root"
  date '+%s' > "$root/.last_refresh"
  if [ "$adapter" = "claude" ]; then
    HOME="$TEST_ROOT/home" \
      CLAUDE_CODE_SESSION_ID="claude-test-session" \
      CLAUDE_PROJECT_DIR="$PROJECT_DIR" \
      NOTIFY_ROOT_DATA_DIR="$root" \
      NOTIFY_CONFIG_DIR="$TEST_ROOT/config" \
      NOTIFY_RENDER_PID="$render_pid" \
      bash "$NOTIFY" "$@" 2>/dev/null
  else
    HOME="$TEST_ROOT/home" \
      NOTIFY_AGENT_TYPE="$adapter" \
      NOTIFY_AGENT_SESSION_ID="${adapter}-test-session" \
      NOTIFY_AGENT_WD="$PROJECT_DIR" \
      NOTIFY_AGENT_PID="9001" \
      NOTIFY_ROOT_DATA_DIR="$root" \
      NOTIFY_CONFIG_DIR="$TEST_ROOT/config" \
      NOTIFY_RENDER_PID="$render_pid" \
      bash "$NOTIFY" "$@" 2>/dev/null
  fi
}

test_lifecycle() {
  local adapter="$1" root="$TEST_ROOT/state-$adapter" render_pid
  case "$adapter" in
    generic) render_pid=71001 ;;
    codex) render_pid=71002 ;;
    claude) render_pid=71003 ;;
  esac

  run_notify "$root" "$adapter" "$render_pid" session-start
  assert_file_contains "$root/$render_pid/static.env" "AGENT_TYPE=$adapter" "$adapter adapter selected"
  if [ "$adapter" = "codex" ]; then
    assert_file_contains "$root/$render_pid/static.env" "AGENT_SESSION_ID=codex-test-session" \
      "codex adapter persists the wrapper-provided session id"
    assert_file_contains "$root/$render_pid/static.env" "AGENT_WD=$PROJECT_DIR" \
      "codex adapter persists the wrapper-provided working directory"
  fi

  run_notify "$root" "$adapter" "$render_pid" event Working
  assert_file_contains "$root/$render_pid/state.env" "AGENT_STATE=Working" "$adapter Working state"
  assert_file_contains "$root/$render_pid/state.env" "USER_STATE=Pending" "$adapter Working resets user state"

  run_notify "$root" "$adapter" "$render_pid" update USER_STATE OnHold
  # Re-selecting the active popup state is an idempotent success, not a tmux
  # run-shell error.
  run_notify "$root" "$adapter" "$render_pid" update USER_STATE OnHold
  run_notify "$root" "$adapter" "$render_pid" event WaitingForUser
  assert_file_contains "$root/$render_pid/state.env" "AGENT_STATE=WaitingForUser" "$adapter waiting state"
  assert_file_contains "$root/$render_pid/state.env" "USER_STATE=OnHold" "$adapter OnHold guardrail"

  run_notify "$root" "$adapter" "$render_pid" update USER_STATE Pending
  run_notify "$root" "$adapter" "$render_pid" event Finished
  assert_file_contains "$root/$render_pid/state.env" "AGENT_STATE=Finished" "$adapter Finished state"
  assert_file_contains "$root/$render_pid/state.env" "USER_STATE=Pending" "$adapter Finished user state"

  # An automatic-style Seen request is rejected once USER_STATE is
  # Acknowledged - even a deliberate `update` call (force=true), since the
  # "never downgrade acknowledged to seen" guard has no force exception,
  # unlike the OnHold guard right below it in update_state_and_render. This
  # locks down that asymmetry as current behavior, not a claim it's correct.
  run_notify "$root" "$adapter" "$render_pid" update USER_STATE Acknowledged
  run_notify "$root" "$adapter" "$render_pid" update USER_STATE Seen
  assert_file_contains "$root/$render_pid/state.env" "USER_STATE=Acknowledged" \
    "$adapter Acknowledged not downgraded to Seen even via deliberate update"

  # v4 compatibility: `update CLAUDE_STATE ...` is accepted as an alias for
  # AGENT_STATE.
  run_notify "$root" "$adapter" "$render_pid" update CLAUDE_STATE Idle
  assert_file_contains "$root/$render_pid/state.env" "AGENT_STATE=Idle" \
    "$adapter CLAUDE_STATE alias maps to AGENT_STATE"

  for renderer in sound-bell sound-tts terminal-title tmux-pane-bg; do
    assert_log_contains "$root/notify.log" "RENDER AGENT_STATE_UPDATE $renderer" \
      "$adapter framework dispatches $renderer"
  done

  run_notify "$root" "$adapter" "$render_pid" session-end
  [ ! -d "$root/$render_pid" ] || fail "$adapter session-end removes state"
  pass "$adapter lifecycle and renderer dispatch"
}

test_popup_targeting() {
  local hooks="$PROJECT_DIR/release/tmux/tmux-hooks.conf"
  local count
  count=$(grep -c 'NOTIFY_RENDER_PID=#{pane_pid} NOTIFY_REQUIRE_SESSION=true' "$hooks")
  [ "$count" -eq 3 ] || fail "all popup state actions target the pane PID"

  # tmux run-shell spawns a non-interactive, non-login shell that never loads
  # PATH from ~/.zshrc, so every single run-shell command in this file - not
  # just the 3 popup-menu ones above - must use the absolute
  # $HOME/.local/bin/notify path, never a bare `notify`.
  local run_shell_lines total_absolute
  run_shell_lines=$(grep -cE "run-shell [\"']" "$hooks")
  total_absolute=$(grep -cE "run-shell [\"'].*\\\$HOME/\\.local/bin/notify" "$hooks")
  [ "$run_shell_lines" -eq "$total_absolute" ] || \
    fail "every run-shell invocation in tmux-hooks.conf uses the absolute notify path ($total_absolute/$run_shell_lines)"

  local root="$TEST_ROOT/missing-session"
  mkdir -p "$root"
  date '+%s' > "$root/.last_refresh"
  if HOME="$TEST_ROOT/home" NOTIFY_ROOT_DATA_DIR="$root" NOTIFY_CONFIG_DIR="$TEST_ROOT/config" \
    NOTIFY_RENDER_PID=74001 NOTIFY_REQUIRE_SESSION=true \
    bash "$NOTIFY" update USER_STATE OnHold > "$TEST_ROOT/missing.out" 2>&1; then
    fail "popup targeting rejects a pane without an agent session"
  fi
  grep -qF 'No active session found.' "$TEST_ROOT/missing.out" || \
    fail "missing popup session has a clear error"
  [ ! -d "$root/74001" ] || fail "popup does not create state for a plain shell pane"
  pass "popup PID targeting and idempotency"
}

test_refresh_all_isolation() {
  local root="$TEST_ROOT/refresh-all" first second
  sleep 30 & first=$!
  sleep 30 & second=$!
  TEST_PIDS="$TEST_PIDS $first $second"
  mkdir -p "$root/$first" "$root/$second"
  date '+%s' > "$root/.last_refresh"
  printf '%s\n' \
    "SHELL_PID=$first" "AGENT_TYPE=codex" "AGENT_SESSION_ID=codex-one" \
    "AGENT_WD=/tmp/codex-one" "AGENT_PID=101" "SESSION_NAME=codex-one-name" \
    "SESSION_TMUX_PANE=" "SESSION_TMUX_WINDOW=" "SESSION_TMUX_SESSION=" \
    "TRANSCRIPT_PATH=/tmp/codex-one.jsonl" > "$root/$first/static.env"
  printf '%s\n' \
    "SHELL_PID=$second" "AGENT_TYPE=claude" "AGENT_SESSION_ID=claude-two" \
    "AGENT_WD=/tmp/claude-two" "AGENT_PID=202" "SESSION_NAME=claude-two-name" \
    "SESSION_TMUX_PANE=" "SESSION_TMUX_WINDOW=" "SESSION_TMUX_SESSION=" \
    "TRANSCRIPT_PATH=/tmp/claude-two.jsonl" > "$root/$second/static.env"
  printf '%s\n' 'AGENT_STATE=Finished' 'USER_STATE=Pending' > "$root/$first/state.env"
  printf '%s\n' 'AGENT_STATE=Working' 'USER_STATE=Seen' > "$root/$second/state.env"

  HOME="$TEST_ROOT/home" NOTIFY_ROOT_DATA_DIR="$root" NOTIFY_CONFIG_DIR="$TEST_ROOT/config" \
    bash "$NOTIFY" refresh --all

  assert_file_contains "$root/$first/static.env" "AGENT_TYPE=codex" "refresh-all preserves first adapter"
  assert_file_contains "$root/$first/static.env" "TRANSCRIPT_PATH=/tmp/codex-one.jsonl" "refresh-all preserves first transcript"
  assert_file_contains "$root/$second/static.env" "AGENT_TYPE=claude" "refresh-all preserves second adapter"
  assert_file_contains "$root/$second/static.env" "TRANSCRIPT_PATH=/tmp/claude-two.jsonl" "refresh-all preserves second transcript"
  # Only CURRENT_PID's own agent metadata may be refreshed from the invoking
  # process's own $PWD/env - a `refresh --all` sweep must not overwrite every
  # OTHER session's AGENT_PID/SESSION_NAME with whatever the invoker's
  # process happens to report either.
  assert_file_contains "$root/$first/static.env" "AGENT_PID=101" "refresh-all preserves first AGENT_PID"
  assert_file_contains "$root/$first/static.env" "SESSION_NAME=codex-one-name" "refresh-all preserves first SESSION_NAME"
  assert_file_contains "$root/$second/static.env" "AGENT_PID=202" "refresh-all preserves second AGENT_PID"
  assert_file_contains "$root/$second/static.env" "SESSION_NAME=claude-two-name" "refresh-all preserves second SESSION_NAME"

  # The invoker must itself be in the sweep, AFTER another session. Otherwise
  # loading a neighbor never exercises the current-session metadata branch.
  local current neighbor
  current=$(printf '%s\n' "$first" "$second" | LC_ALL=C sort | tail -1)
  neighbor=$(printf '%s\n' "$first" "$second" | LC_ALL=C sort | head -1)
  cp "$root/$neighbor/static.env" "$TEST_ROOT/neighbor-before"
  HOME="$TEST_ROOT/home" NOTIFY_ROOT_DATA_DIR="$root" NOTIFY_CONFIG_DIR="$TEST_ROOT/config" \
    NOTIFY_RENDER_PID="$current" NOTIFY_AGENT_TYPE=generic \
    NOTIFY_AGENT_SESSION_ID=current-session NOTIFY_AGENT_WD=/tmp/current \
    NOTIFY_AGENT_PID=9191 NOTIFY_SESSION_NAME=current-name \
    NOTIFY_TRANSCRIPT_PATH=/tmp/current.jsonl \
    bash "$NOTIFY" refresh --all
  assert_file_contains "$root/$current/static.env" 'AGENT_TYPE=generic' 'sweep keeps the invoking adapter'
  assert_file_contains "$root/$current/static.env" 'AGENT_SESSION_ID=current-session' 'sweep keeps the invoking session id'
  assert_file_contains "$root/$current/static.env" 'AGENT_WD=/tmp/current' 'sweep keeps the invoking directory'
  assert_file_contains "$root/$current/static.env" 'AGENT_PID=9191' 'sweep keeps the invoking agent PID'
  assert_file_contains "$root/$current/static.env" 'SESSION_NAME=current-name' 'sweep keeps the invoking name'
  assert_file_contains "$root/$current/static.env" 'TRANSCRIPT_PATH=/tmp/current.jsonl' 'sweep keeps the invoking transcript'
  diff <(sed '/^TIMESTAMP=/d' "$TEST_ROOT/neighbor-before") \
    <(sed '/^TIMESTAMP=/d' "$root/$neighbor/static.env") || fail 'sweep changes only its invoking session identity'

  # A detached periodic sweep must also retain the original invocation, not
  # re-import metadata exported by the last STATUS renderer in the parent.
  printf '0\n' > "$root/.last_refresh"
  HOME="$TEST_ROOT/home" NOTIFY_ROOT_DATA_DIR="$root" NOTIFY_CONFIG_DIR="$TEST_ROOT/config" \
    NOTIFY_RENDER_PID="$neighbor" NOTIFY_AGENT_TYPE=generic \
    NOTIFY_AGENT_SESSION_ID=background-caller NOTIFY_AGENT_WD=/tmp/background \
    AGENT_PID=8181 NOTIFY_SESSION_NAME=background-name \
    bash "$NOTIFY" status --all > "$TEST_ROOT/background-status"
  local attempt
  for attempt in {1..50}; do
    grep -q '^AGENT_PID=8181$' "$root/$neighbor/static.env" 2>/dev/null && break
    sleep 0.1
  done
  assert_file_contains "$root/$neighbor/static.env" 'AGENT_SESSION_ID=background-caller' 'detached sweep keeps invoking session id'
  assert_file_contains "$root/$neighbor/static.env" 'AGENT_PID=8181' 'detached sweep keeps invoking PID before STATUS changed exports'
  assert_file_contains "$root/$current/static.env" 'AGENT_SESSION_ID=current-session' 'detached sweep preserves its other session'
  pass "refresh --all keeps sessions isolated"
}

test_renderers() {
  local bin="$TEST_ROOT/bin" tty="$TEST_ROOT/tty" calls="$TEST_ROOT/tmux.calls"
  local state_root="$TEST_ROOT/renderer-state" render_pid=73001
  mkdir -p "$bin" "$state_root/$render_pid"
  : > "$tty"
  : > "$calls"
  printf '%s\n' '#!/bin/bash' \
    'case "$1" in' \
    '  list-panes) printf "%%1 %s\\n" "$TEST_RENDER_PID" ;;' \
    '  display-message) printf "%s\\n" "pane-test" ;;' \
    '  set-option) printf "%s\\n" "$*" >> "$TMUX_CALLS" ;;' \
    'esac' > "$bin/tmux"
  chmod +x "$bin/tmux"

  printf '%s\n' "SHELL_PID=$render_pid" "AGENT_TYPE=codex" > "$state_root/$render_pid/static.env"
  printf '%s\n' 'AGENT_STATE=Finished' 'USER_STATE=Pending' > "$state_root/$render_pid/state.env"

  export PATH="$bin:$PATH" TMUX_CALLS="$calls" TEST_RENDER_PID="$render_pid"
  export ROOT_DATA_DIR="$state_root" RENDER_PID="$render_pid" SESSION_DATA_DIR="$state_root/$render_pid"
  export SESSION_TMUX_PANE="%1" SESSION_TMUX_SESSION="test-session" CLIENT_TTY="$tty"
  export AGENT_STATE="Finished" USER_STATE="Pending" AGENT_WD="$PROJECT_DIR" SESSION_NAME=""
  export TRIGGER="AGENT_STATE_UPDATE"
  export RENDERER_SETTINGS='{"sound-bell":{"Finished":1},"sound-tts":{"Finished":0.7,"name":"renderer-test"},"terminal-title":{"Finished.Pending":"G"},"tmux-pane-bg":{"Finished.Pending":"#123456"}}'
  log() { printf '%s\n' "$2" >> "$TEST_ROOT/renderer.log"; }
  export -f log

  bash "$PROJECT_DIR/release/renderers.d/sound-bell/main" 2>/dev/null || fail "sound-bell executes"
  [ "$(od -An -tu1 "$tty" | tr -d ' ')" = "7" ] || fail "sound-bell writes BEL"

  : > "$tty"
  bash "$PROJECT_DIR/release/renderers.d/sound-tts/main" 2>/dev/null || fail "sound-tts executes"
  grep -aqF 'Custom=id=tts:[[volm 0.7]] renderer-test' "$tty" || fail "sound-tts writes iTerm2 sequence"

  : > "$tty"
  bash "$PROJECT_DIR/release/renderers.d/terminal-title/main" || fail "terminal-title executes"
  grep -aqF 'G test-session' "$tty" || fail "terminal-title writes aggregated title"

  bash "$PROJECT_DIR/release/renderers.d/tmux-pane-bg/main" || fail "tmux-pane-bg executes"
  grep -qF 'window-style bg=#123456' "$calls" || fail "tmux-pane-bg sets inactive style"
  grep -qF 'window-active-style bg=#123456' "$calls" || fail "tmux-pane-bg sets active style"

  # AGENT_STATE empty (e.g. right after a wipe) forces an immediate reset to
  # "default" regardless of configured settings, via `tmux set-option -u`,
  # not by setting a literal "bg=default".
  : > "$calls"
  AGENT_STATE="" USER_STATE="" bash "$PROJECT_DIR/release/renderers.d/tmux-pane-bg/main" || \
    fail "tmux-pane-bg executes with no agent state"
  grep -qF -- '-u window-style' "$calls" || fail "tmux-pane-bg unsets inactive style on empty AGENT_STATE"
  grep -qF -- '-u window-active-style' "$calls" || fail "tmux-pane-bg unsets active style on empty AGENT_STATE"
  pass "all renderer outputs"
}

test_renderer_disabled_is_skipped() {
  # A renderer disabled at any settings layer must never be invoked by the
  # core dispatcher - exercised through `notify event`, not by calling the
  # renderer's own main directly, since the skip decision belongs entirely
  # to the core (`call_all_renderers`), not to the renderer itself.
  local root="$TEST_ROOT/renderer-disable" render_pid=73002
  mkdir -p "$root"
  date '+%s' > "$root/.last_refresh"
  local env=(HOME="$TEST_ROOT/home" NOTIFY_AGENT_TYPE=generic NOTIFY_AGENT_SESSION_ID=disable-test
    NOTIFY_AGENT_WD="$PROJECT_DIR" NOTIFY_AGENT_PID=9002 NOTIFY_ROOT_DATA_DIR="$root"
    NOTIFY_CONFIG_DIR="$TEST_ROOT/config-disable" NOTIFY_RENDER_PID="$render_pid")
  env "${env[@]}" bash "$NOTIFY" session-start 2>/dev/null
  env "${env[@]}" bash "$NOTIFY" sound-bell disable 2>/dev/null
  env "${env[@]}" bash "$NOTIFY" event Finished 2>/dev/null

  assert_log_contains "$root/notify.log" "RENDER AGENT_STATE_UPDATE sound-bell skip (disabled)" \
    "a session-disabled renderer is skipped by the core dispatcher"
  assert_log_not_contains "$root/notify.log" "sound-bell: ring" \
    "a disabled renderer's own logic never runs"
  pass "disabled renderer is skipped by the core dispatcher"
}

for adapter in generic codex claude; do test_lifecycle "$adapter"; done
test_popup_targeting
test_refresh_all_isolation
test_renderers
test_renderer_disabled_is_skipped
printf '\nAll %s integration groups passed.\n' "$pass_count"
