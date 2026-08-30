#!/bin/bash
# Opt-in scenarios documenting currently-accepted bugs/risk from TODO.md and
# CLAUDE.md (tests/AGENTS.md scenarios 15-16). These are tripwires, not
# correctness assertions: scenario 16 is deterministic and safe to run
# anytime; scenario 15 demonstrates a real, currently-unfixed race and is
# inherently probabilistic to reproduce black-box, so it never fails the
# suite on its own - it just reports what it observed. Not part of the
# default test run; opt in with:
#   RUN_KNOWN_ISSUES=1 ./tests/test_known_issues.sh
set -euo pipefail

if [ "${RUN_KNOWN_ISSUES:-0}" != "1" ]; then
  echo "skipped (set RUN_KNOWN_ISSUES=1 to run - see the header comment in this file)"
  exit 0
fi

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_helpers.sh"
TEST_ROOT="$(mktemp -d /tmp/notify-tests.XXXXXX)"
trap 'rm -rf "$TEST_ROOT"' EXIT

test_concurrent_update_race() {
  # TODO.md ("Serialize overlapping state updates"): update_state_and_render
  # does an unlocked read/modify/write/render sequence, so concurrent hook
  # commands can read the same old state and overwrite each other's
  # state.env. This burns many bursts of truly concurrent conflicting
  # updates against the SAME render pid and checks state.env for structural
  # corruption (duplicate keys / extra lines) each time - the actual
  # observable symptom of two processes' separate `>`/`>>` write sequences
  # interleaving. Reproducing this black-box (without instrumenting the
  # script to force an exact interleaving) is probabilistic, so this never
  # fails the suite by itself; it reports whether it reproduced the race.
  local root="$TEST_ROOT/race" render_pid=95001
  mkdir -p "$root"
  date '+%s' > "$root/.last_refresh"
  local env=(HOME="$TEST_ROOT/home" NOTIFY_AGENT_TYPE=generic NOTIFY_AGENT_SESSION_ID=race-test
    NOTIFY_AGENT_WD="$PROJECT_DIR" NOTIFY_AGENT_PID="$render_pid" NOTIFY_ROOT_DATA_DIR="$root"
    NOTIFY_CONFIG_DIR="$TEST_ROOT/config" NOTIFY_RENDER_PID="$render_pid")
  env "${env[@]}" bash "$NOTIFY" session-start >/dev/null 2>&1

  local burst reproduced=0 burst_count=25 concurrency=12
  for burst in $(seq 1 "$burst_count"); do
    local i pids=()
    for i in $(seq 1 "$concurrency"); do
      if [ $((i % 2)) -eq 0 ]; then
        env "${env[@]}" bash "$NOTIFY" update AGENT_STATE Working >/dev/null 2>&1 &
      else
        env "${env[@]}" bash "$NOTIFY" update AGENT_STATE Finished >/dev/null 2>&1 &
      fi
      pids+=("$!")
    done
    local pid
    for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done

    local lines agent_lines user_lines
    lines=$(wc -l < "$root/$render_pid/state.env" | tr -d ' ')
    agent_lines=$(grep -c '^AGENT_STATE=' "$root/$render_pid/state.env" || true)
    user_lines=$(grep -c '^USER_STATE=' "$root/$render_pid/state.env" || true)
    if [ "$lines" != "2" ] || [ "$agent_lines" != "1" ] || [ "$user_lines" != "1" ]; then
      reproduced=1
      break
    fi
  done

  if [ "$reproduced" -eq 1 ]; then
    echo "REPRODUCED: concurrent updates corrupted state.env (TODO.md's unlocked read/modify/write race)"
  else
    echo "NOT REPRODUCED this run: state.env stayed well-formed across $burst_count bursts of $concurrency concurrent updates"
  fi
  pass "concurrent update race harness ran to completion (informational, see above)"
}

test_trust_boundary_shell_injection() {
  # CLAUDE.md's "Accepted trust boundary": static.env/state.env are unquoted
  # shell assignments that get sourced later, so shell syntax in adapter
  # metadata executes. This is a tripwire, not a bug to fix here - if
  # someone quietly makes the sourcing safe without updating CLAUDE.md/
  # TODO.md, this test starts failing and flags the drift.
  local root="$TEST_ROOT/trust" render_pid=95002 marker="$TEST_ROOT/pwned"
  mkdir -p "$root"
  date '+%s' > "$root/.last_refresh"
  rm -f "$marker"

  HOME="$TEST_ROOT/home" NOTIFY_AGENT_TYPE=generic NOTIFY_AGENT_SESSION_ID=trust-test \
    NOTIFY_AGENT_WD="\$(touch $marker)" NOTIFY_AGENT_PID="$render_pid" \
    NOTIFY_ROOT_DATA_DIR="$root" NOTIFY_CONFIG_DIR="$TEST_ROOT/config" \
    NOTIFY_RENDER_PID="$render_pid" \
    bash "$NOTIFY" session-start >/dev/null 2>&1

  assert_file_contains "$root/$render_pid/static.env" "AGENT_WD=\$(touch $marker)" \
    "the injection payload is stored verbatim, unescaped, in static.env"
  [ ! -f "$marker" ] || fail "writing static.env must not itself execute the payload"

  # Any command that re-sources static.env (here, `notify status`) executes
  # the payload purely by reading stored session metadata.
  HOME="$TEST_ROOT/home" NOTIFY_ROOT_DATA_DIR="$root" NOTIFY_CONFIG_DIR="$TEST_ROOT/config" \
    NOTIFY_RENDER_PID="$render_pid" \
    bash "$NOTIFY" status >/dev/null 2>&1

  [ -f "$marker" ] || fail "sourcing static.env executed the injected command (accepted risk not reproduced - has the sourcing changed?)"
  pass "trust boundary: metadata containing shell syntax still executes on source (accepted risk, as documented)"
}

test_concurrent_update_race
test_trust_boundary_shell_injection
printf '\nAll %s known-issue scenarios ran.\n' "$pass_count"
