#!/bin/bash
# End-to-end scenarios for Claude subagent completion tracking
# (adapter_has_pending_work / pending_finish), automating TESTING.md's live
# T1/T2/T3/T5 scenarios against hand-built fixture transcripts instead of a
# real Claude session. See tests/AGENTS.md scenarios 5-8.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_helpers.sh"
TEST_ROOT="$(mktemp -d /tmp/notify-tests.XXXXXX)"
trap 'rm -rf "$TEST_ROOT"' EXIT

SESSION_ID="subagent-test-session"
# Mirrors the claude adapter's own fast-path guess:
#   $HOME/.claude/projects/-<CLAUDE_PROJECT_DIR with / -> ->/$SESSION_ID.jsonl
HOME_DIR="$TEST_ROOT/home"
PROJECT_ENCODED="-$(printf '%s' "${PROJECT_DIR#/}" | tr '/' '-')"
TRANSCRIPT_DIR="$HOME_DIR/.claude/projects/$PROJECT_ENCODED"
TRANSCRIPT="$TRANSCRIPT_DIR/$SESSION_ID.jsonl"

dispatched_line() {
  printf '{"type":"tool_result","content":"...agentId: %s..."}\n' "$1"
}
completed_line() {
  printf '{"type":"queue-operation","operation":"enqueue","content":"...<task-id>%s</task-id>...<status>completed</status>..."}\n' "$1"
}

# Runs `notify` as the claude adapter against a fresh root data dir, its own
# transcript fixture, and its own render pid - callers pass the render pid so
# each scenario gets full isolation from the others.
run_claude() {
  local root="$1" render_pid="$2"
  shift 2
  mkdir -p "$root"
  date '+%s' > "$root/.last_refresh"
  HOME="$HOME_DIR" \
    CLAUDE_CODE_SESSION_ID="$SESSION_ID" \
    CLAUDE_PROJECT_DIR="$PROJECT_DIR" \
    NOTIFY_ROOT_DATA_DIR="$root" \
    NOTIFY_CONFIG_DIR="$TEST_ROOT/config" \
    NOTIFY_RENDER_PID="$render_pid" \
    bash "$NOTIFY" "$@" 2>/dev/null
}

test_t1_single_subagent() {
  local root="$TEST_ROOT/t1" render_pid=81001
  mkdir -p "$TRANSCRIPT_DIR"
  dispatched_line "aaaaaaaaaaaa" > "$TRANSCRIPT"

  run_claude "$root" "$render_pid" session-start
  run_claude "$root" "$render_pid" event Working

  # Finished is requested while the dispatched subagent hasn't completed yet
  # (per the transcript) - it must be suppressed, not applied.
  run_claude "$root" "$render_pid" event Finished
  assert_file_contains "$root/$render_pid/state.env" "AGENT_STATE=Working" \
    "T1 Finished suppressed while subagent pending"
  [ -f "$root/$render_pid/pending_finish" ] || fail "T1 pending_finish marker created"
  assert_log_contains "$root/notify.log" \
    "update AGENT_STATE Finished suppressed (agent still has pending work)" \
    "T1 suppression logged"

  # The dispatched agent completes. Resolution happens reactively: the very
  # next hook event (here, an unrelated Idle) first resolves the suppressed
  # Finished, THEN applies its own request - locking down the documented,
  # currently-undecided ordering from TODO.md ("Decide how new activity
  # supersedes a pending finish") as today's actual behavior.
  completed_line "aaaaaaaaaaaa" >> "$TRANSCRIPT"
  run_claude "$root" "$render_pid" event Idle

  assert_log_contains "$root/notify.log" \
    "pending_finish resolved (subagents cleared) - applying Finished" \
    "T1 pending_finish resolved reactively"
  [ -f "$root/$render_pid/pending_finish" ] && fail "T1 pending_finish marker cleared"
  assert_file_contains "$root/$render_pid/state.env" "AGENT_STATE=Idle" \
    "T1 the new Idle request still applies after the stale Finished"

  local state_updates
  state_updates=$(count_log_occurrences "$root/notify.log" "RENDER AGENT_STATE_UPDATE sound-bell")
  [ "$state_updates" -ge 2 ] || fail "T1 both the resolved Finished and the new Idle rendered ($state_updates)"
  pass "T1: single dispatched subagent suppresses then resolves Finished"
}

test_t2_parallel_subagents() {
  local root="$TEST_ROOT/t2" render_pid=81002
  mkdir -p "$TRANSCRIPT_DIR"
  {
    dispatched_line "111111111111"
    dispatched_line "222222222222"
    dispatched_line "333333333333"
  } > "$TRANSCRIPT"

  run_claude "$root" "$render_pid" session-start
  run_claude "$root" "$render_pid" event Working
  run_claude "$root" "$render_pid" event Finished
  [ -f "$root/$render_pid/pending_finish" ] || fail "T2 pending_finish marker created"

  # Complete them one at a time via `refresh` (the proactive/no-new-hook
  # path) - no Finished render must appear until the LAST one clears.
  completed_line "111111111111" >> "$TRANSCRIPT"
  run_claude "$root" "$render_pid" refresh
  [ -f "$root/$render_pid/pending_finish" ] || fail "T2 still pending after first completion"
  assert_log_not_contains "$root/notify.log" "pending_finish resolved" \
    "T2 no premature resolution after first completion"

  completed_line "222222222222" >> "$TRANSCRIPT"
  run_claude "$root" "$render_pid" refresh
  [ -f "$root/$render_pid/pending_finish" ] || fail "T2 still pending after second completion"
  assert_log_not_contains "$root/notify.log" "pending_finish resolved" \
    "T2 no premature resolution after second completion"

  completed_line "333333333333" >> "$TRANSCRIPT"
  run_claude "$root" "$render_pid" refresh
  [ -f "$root/$render_pid/pending_finish" ] && fail "T2 resolved after the last completion"
  assert_log_contains "$root/notify.log" "pending_finish resolved" \
    "T2 resolves only once all three subagents clear"
  assert_file_contains "$root/$render_pid/state.env" "AGENT_STATE=Finished" \
    "T2 Finished applied after the last completion"

  local resolutions
  resolutions=$(count_log_occurrences "$root/notify.log" "pending_finish resolved")
  [ "$resolutions" -eq 1 ] || fail "T2 exactly one resolution across all three completions ($resolutions)"
  pass "T2: parallel subagents block Finished until the last one clears"
}

test_t3_silent_background_completion() {
  local root="$TEST_ROOT/t3" render_pid=81003
  mkdir -p "$TRANSCRIPT_DIR"
  dispatched_line "bbbbbbbbbbbb" > "$TRANSCRIPT"

  run_claude "$root" "$render_pid" session-start
  run_claude "$root" "$render_pid" event Working
  # The parent's own Stop fires (-> Finished) before the background task
  # completes.
  run_claude "$root" "$render_pid" event Finished
  [ -f "$root/$render_pid/pending_finish" ] || fail "T3 pending_finish marker created"

  # Completion appears, but - unlike T1 - the parent issues NO further hook
  # event at all. Resolution must come purely from a periodic `refresh`
  # (what the debounced background refresh in release/notify performs on
  # its own), not from any adapter-driven event.
  completed_line "bbbbbbbbbbbb" >> "$TRANSCRIPT"
  run_claude "$root" "$render_pid" refresh

  assert_log_contains "$root/notify.log" "pending_finish resolved" \
    "T3 resolves via refresh alone, with no further hook event"
  assert_file_contains "$root/$render_pid/state.env" "AGENT_STATE=Finished" \
    "T3 Finished applied via refresh"
  pass "T3: silent background completion resolves via refresh polling alone"
}

test_orphaned_subagent_never_resolves() {
  local root="$TEST_ROOT/orphan" render_pid=81004
  mkdir -p "$TRANSCRIPT_DIR"
  dispatched_line "cccccccccccc" > "$TRANSCRIPT"

  run_claude "$root" "$render_pid" session-start
  run_claude "$root" "$render_pid" event Working
  run_claude "$root" "$render_pid" event Finished
  [ -f "$root/$render_pid/pending_finish" ] || fail "orphan pending_finish marker created"

  # No completion entry is ever added (the historical orphaned-background-tool
  # case from TODO.md's "external issue" section). Repeated refreshes must
  # leave the marker in place forever - this is documented, accepted
  # behavior, not a bug this test is trying to fix.
  local i
  for i in 1 2 3; do
    run_claude "$root" "$render_pid" refresh
  done

  [ -f "$root/$render_pid/pending_finish" ] || fail "orphan pending_finish never expires on its own"
  assert_file_contains "$root/$render_pid/state.env" "AGENT_STATE=Working" \
    "orphan AGENT_STATE never silently becomes Finished"
  assert_log_not_contains "$root/notify.log" "pending_finish resolved" \
    "orphan never resolves"
  pass "orphaned subagent: pending_finish stays pending forever (documented limitation)"
}

test_t1_single_subagent
test_t2_parallel_subagents
test_t3_silent_background_completion
test_orphaned_subagent_never_resolves
printf '\nAll %s subagent-tracking scenarios passed.\n' "$pass_count"
