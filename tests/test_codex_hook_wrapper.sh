#!/bin/bash
# Codex stdin translation and fail-open wrapper behavior.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_helpers.sh"
TEST_ROOT="$(mktemp -d /tmp/notify-codex-wrapper-tests.XXXXXX)"
trap 'rm -rf "$TEST_ROOT"' EXIT

runtime="$TEST_ROOT/runtime"
root_data="$TEST_ROOT/state"
capture="$TEST_ROOT/context"
stdout_capture="$TEST_ROOT/stdout"
stderr_capture="$TEST_ROOT/stderr"
mkdir -p "$runtime/app" "$root_data"

printf '%s\n' \
  '#!/bin/bash' \
  'printf "%s\n" "SESSION_ID=${NOTIFY_AGENT_SESSION_ID:-}" "WD=${NOTIFY_AGENT_WD:-}" "TRANSCRIPT=${NOTIFY_TRANSCRIPT_PATH:-}" "TYPE=${NOTIFY_AGENT_TYPE:-}" > "$FAKE_CAPTURE"' \
  'printf "runtime stdout"' \
  'printf "runtime stderr" >&2' \
  'exit 7' > "$runtime/app/notify"
chmod +x "$runtime/app/notify"

set +e
printf '%s\n' '{"session_id":"codex-session","cwd":"/tmp/project with spaces","transcript_path":"/tmp/rollout.jsonl","hook_event_name":"Stop"}' \
  | HOME="$TEST_ROOT/home" NOTIFY_RUNTIME_DIR="$runtime" NOTIFY_ROOT_DATA_DIR="$root_data" \
      NOTIFY_CODEX_TRACE=true FAKE_CAPTURE="$capture" \
      bash "$PROJECT_DIR/release/codex/notify" event Finished \
      > "$stdout_capture" 2> "$stderr_capture"
wrapper_status=$?
set -e

[ "$wrapper_status" -eq 0 ] || fail "codex wrapper fails open when the runtime exits non-zero"
[ ! -s "$stdout_capture" ] || fail "codex wrapper emits no stdout"
[ ! -s "$stderr_capture" ] || fail "codex wrapper emits no stderr"
assert_file_contains "$capture" "SESSION_ID=codex-session" "codex stdin session_id reaches the adapter contract"
assert_file_contains "$capture" "WD=/tmp/project with spaces" "codex stdin cwd reaches the adapter contract"
assert_file_contains "$capture" "TRANSCRIPT=/tmp/rollout.jsonl" "codex stdin transcript reaches the adapter contract"
assert_file_contains "$capture" "TYPE=codex" "codex wrapper always selects the codex adapter"

trace="$root_data/codex-hook-trace.jsonl"
[ "$(jq -r '.event' "$trace")" = "Stop" ] || fail "codex trace records the native event"
[ "$(jq -r '.status' "$trace")" = "7" ] || fail "codex trace records the swallowed runtime status"
[ "$(jq -r '.stdout_bytes' "$trace")" = "14" ] || fail "codex trace records suppressed stdout bytes"
[ "$(jq -r '.stderr_bytes' "$trace")" = "14" ] || fail "codex trace records suppressed stderr bytes"
[ "$(jq -r '.stderr_preview' "$trace")" = "runtime stderr" ] || fail "codex trace preserves bounded failure detail"
pass "codex wrapper translates stdin, suppresses output, traces diagnostics, and fails open"

printf '%s\n' \
  '#!/bin/bash' \
  'sleep 4' > "$runtime/app/notify"
chmod +x "$runtime/app/notify"
started="$(date '+%s')"
printf '%s\n' '{"session_id":"slow-session","cwd":"/tmp/project","hook_event_name":"Interrupt"}' \
  | HOME="$TEST_ROOT/home" NOTIFY_RUNTIME_DIR="$runtime" NOTIFY_ROOT_DATA_DIR="$root_data" \
      NOTIFY_CODEX_TRACE=true bash "$PROJECT_DIR/release/codex/notify" event Idle \
      > "$stdout_capture" 2> "$stderr_capture"
elapsed=$(( $(date '+%s') - started ))
[ "$elapsed" -lt 3 ] || fail "codex wrapper bounds a stuck Interrupt runtime before Codex's 3s deadline"
[ ! -s "$stdout_capture" ] || fail "timed-out codex wrapper emits no stdout"
[ ! -s "$stderr_capture" ] || fail "timed-out codex wrapper emits no stderr"
[ "$(tail -n 1 "$trace" | jq -r '.status')" = "124" ] || fail "codex trace identifies its internal timeout"
pass "codex wrapper cuts off a stuck runtime before the outer hook deadline"

printf '\nAll %s Codex-wrapper scenarios passed.\n' "$pass_count"
