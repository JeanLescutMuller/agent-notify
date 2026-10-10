#!/bin/bash
# Codex title -> saved metadata -> TTS, including renames and unavailable data.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_helpers.sh"
TEST_ROOT="$(mktemp -d /tmp/notify-name-tests.XXXXXX)"
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/home" "$TEST_ROOT/codex-data" "$TEST_ROOT/state"
index="$TEST_ROOT/codex-data/session_index.jsonl"
statics="$TEST_ROOT/state/75001/static.env"
real_jq="$(command -v jq)"
date '+%s' > "$TEST_ROOT/state/.last_refresh"
: > "$TEST_ROOT/tty"
: > "$TEST_ROOT/lookups"

# Count index parses independently of all the core's renderer/settings jq calls.
printf '%s\n' '#!/bin/bash' \
  'for arg in "$@"; do' \
  '  case "$arg" in */session_index.jsonl) printf "lookup\n" >> "$TITLE_LOOKUPS" ;; esac' \
  'done' \
  'exec "$REAL_JQ" "$@"' > "$TEST_ROOT/bin/jq"
printf '%s\n' '#!/bin/bash' \
  'case "$1" in' \
  '  list-clients) printf "1 %s\n" "$TEST_TTY" ;;' \
  '  display-message)' \
  '    case "${!#}" in' \
  '      "#{pane_title}") printf "Wrong pane title\n" ;;' \
  '      "#S") printf "test-session\n" ;;' \
  '      "#{window_id}") printf "@1\n" ;;' \
  '    esac ;;' \
  'esac' > "$TEST_ROOT/bin/tmux"
chmod +x "$TEST_ROOT/bin/jq" "$TEST_ROOT/bin/tmux"
for renderer in sound-bell terminal-title tmux-pane-bg; do
  mkdir -p "$TEST_ROOT/config/renderers.d/$renderer"
  printf '{"enabled":false}\n' > "$TEST_ROOT/config/renderers.d/$renderer/settings.json"
done

notify_env=(HOME="$TEST_ROOT/home" CODEX_HOME="$TEST_ROOT/codex-data"
  PATH="$TEST_ROOT/bin:$PATH" REAL_JQ="$real_jq" TITLE_LOOKUPS="$TEST_ROOT/lookups"
  TEST_TTY="$TEST_ROOT/tty" TMUX_PANE=%1 NOTIFY_AGENT_TYPE=codex
  NOTIFY_AGENT_SESSION_ID=codex-name-test NOTIFY_AGENT_WD="$PROJECT_DIR"
  NOTIFY_RENDER_PID=75001 NOTIFY_ROOT_DATA_DIR="$TEST_ROOT/state"
  NOTIFY_CONFIG_DIR="$TEST_ROOT/config")
run() { env "${notify_env[@]}" bash "$NOTIFY" "$@"; }
append_title() {
  "$real_jq" -cn --arg id "${2:-codex-name-test}" --arg name "$1" \
    '{id:$id,thread_name:$name}' >> "$index"
}
saved_name() { bash -c 'source "$1"; printf "%s" "$SESSION_NAME"' _ "$statics"; }

# Titles may contain spaces, quotes and shell syntax: none may execute when
# static.env or the name cache is loaded by a later notify invocation.
printf -v title 'Run test "quoted" $(touch %s/unexpected)' "$TEST_ROOT"
append_title 'Old title'
append_title "$title"
append_title 'Another session' codex-other
run session-start
run status > "$TEST_ROOT/status"
[ "$(saved_name)" = "$title" ] || fail 'Codex title survives metadata reload exactly'
assert_log_contains "$TEST_ROOT/status" "TTS_NAME: '$title'" 'session title takes priority over pane title'
assert_log_contains "$TEST_ROOT/status" 'agent adapter session name' 'status explains the correct name source'
run event Finished
assert_log_contains "$TEST_ROOT/tty" "Custom=id=tts:[[volm 0.7]] $title" 'actual TTS sequence uses Codex title'
run event Working
run event Working
[ "$(count_log_occurrences "$TEST_ROOT/lookups" lookup)" = 1 ] || fail 'unchanged index is parsed once across hooks and status'
[ ! -e "$TEST_ROOT/unexpected" ] || fail 'title shell syntax executed'
run sound-tts name=Explicit
run status > "$TEST_ROOT/status"
assert_log_contains "$TEST_ROOT/status" "TTS_NAME: 'Explicit'" 'explicit sound-tts name still overrides session title'
run sound-tts name=
pass 'Codex title reaches status and speech, survives reload safely, and is cached'

# No sleep: appends within one second must invalidate the cache too.
append_title 'Renamed session'
: > "$TEST_ROOT/tty"
run event Finished
[ "$(saved_name)" = 'Renamed session' ] || fail 'next state change sees renamed title'
assert_log_contains "$TEST_ROOT/tty" 'Custom=id=tts:[[volm 0.7]] Renamed session' 'speech uses rename without restart'
[ "$(count_log_occurrences "$TEST_ROOT/lookups" lookup)" = 2 ] || fail 'rename reparses index once'
append_title 'New status title'
run status > "$TEST_ROOT/status"
assert_log_contains "$TEST_ROOT/status" "TTS_NAME: 'New status title'" 'status also detects renamed title'
pass 'renames update saved metadata and TTS without waiting for periodic refresh'

# A missing index or a session not yet named leaves the standard fallback.
mv "$index" "$TEST_ROOT/saved-index"
run status > "$TEST_ROOT/status"
assert_log_contains "$TEST_ROOT/status" "TTS_NAME: 'Wrong pane title'" 'missing index falls back to pane title'
[ -z "$(saved_name)" ] || fail 'missing index leaves normalized name empty'
printf 'incomplete JSON\n' > "$index"
append_title 'Another session' codex-other
run status > "$TEST_ROOT/status"
assert_log_contains "$TEST_ROOT/status" "TTS_NAME: 'Wrong pane title'" 'malformed and unrelated records do not supply a name'
append_title 'Created after startup'
run status > "$TEST_ROOT/status"
[ "$(saved_name)" = 'Created after startup' ] || fail 'late-generated name replaces fallback'
printf '{"id":"codex-name-test","thread_name":42}\n' >> "$index"
run status > "$TEST_ROOT/status"
[ "$(saved_name)" = 'Created after startup' ] || fail 'invalid name type must not replace last valid name'
env "${notify_env[@]}" NOTIFY_AGENT_SESSION_ID=codex-other bash "$NOTIFY" session-start
[ "$(saved_name)" = 'Another session' ] || fail 'reused pane loads the new session title'
# The target saved session must win over the invoking environment/session id.
run status > "$TEST_ROOT/status"
assert_log_contains "$TEST_ROOT/status" "TTS_NAME: 'Another session'" 'status resolves the target session, not the invoker'
pass 'missing/malformed index, late titles and session reuse preserve correct fallback and identity'

printf '\nAll %s Codex-name scenarios passed.\n' "$pass_count"
