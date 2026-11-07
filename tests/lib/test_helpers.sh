#!/bin/bash
# Shared harness for agent-notify shell test scripts. Sourced, not executed.
# Provides PROJECT_DIR/NOTIFY, pass/fail bookkeeping, and small grep-based
# assertion helpers used across tests/test_*.sh.

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Never talk to the user's own tmux server or Claude session from a test, even
# when the suite is started from inside one: $TMUX names the live server's
# socket and $TMUX_PANE a live pane (tmux-pane-bg would recolor it). Every
# tmux call goes to a test-only socket folder instead; a test that needs a real
# server starts it there and kills it. agent-tracker's files likewise point to
# a folder that does not exist unless a test creates its own.
unset TMUX TMUX_PANE CLAUDE_CODE_SESSION_ID CLAUDE_PROJECT_DIR
export TMUX_TMPDIR="/tmp/notify-tests-tmux-$(id -u)"
mkdir -p "$TMUX_TMPDIR" && chmod 700 "$TMUX_TMPDIR"
export AGENT_TRACKER_HOME="/tmp/notify-tests-no-agent-tracker-$(id -u)"
NOTIFY="$PROJECT_DIR/release/notify"

pass_count=0
pass() { printf 'PASS: %s\n' "$1"; pass_count=$((pass_count + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

assert_file_contains() {
  local file="$1" expected="$2" label="$3"
  grep -qxF "$expected" "$file" 2>/dev/null || fail "$label (missing '$expected' in $file)"
}

assert_file_not_contains() {
  local file="$1" expected="$2" label="$3"
  if grep -qxF "$expected" "$file" 2>/dev/null; then
    fail "$label (unexpectedly found '$expected' in $file)"
  fi
}

assert_log_contains() {
  local file="$1" expected="$2" label="$3"
  grep -qF "$expected" "$file" 2>/dev/null || fail "$label (missing '$expected' in $file)"
}

assert_log_not_contains() {
  local file="$1" expected="$2" label="$3"
  if grep -qF "$expected" "$file" 2>/dev/null; then
    fail "$label (unexpectedly found '$expected' in $file)"
  fi
}

# Prints how many lines in $1 match the fixed string $2. Never fails/exits
# under `set -e` when the count is zero (a bare `grep -c` would exit 1).
count_log_occurrences() {
  grep -cF "$2" "$1" 2>/dev/null || true
}
