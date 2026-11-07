#!/bin/bash
# v5.15 (agent-tracker v1): static.env no longer copies the pane, tmux
# window/session, working directory, agent PID, shell PID or transcript path.
# They are derived when read: tmux by the shell PID, the invoking hook's own
# context, agent-tracker's last_seen.json when present. These scenarios run a
# REAL tmux server in a test-only socket folder (test_helpers.sh unsets $TMUX),
# so the user's own server and panes are never touched.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_helpers.sh"
TEST_ROOT="$(mktemp -d /tmp/notify-derive.XXXXXX)"
export TMUX_TMPDIR="$TEST_ROOT/tmux"
mkdir -p "$TMUX_TMPDIR" && chmod 700 "$TMUX_TMPDIR"
TEST_PIDS=""
cleanup() {
  local pid
  tmux kill-server 2>/dev/null || true
  for pid in $TEST_PIDS; do kill "$pid" 2>/dev/null || true; done
  for pid in $TEST_PIDS; do wait "$pid" 2>/dev/null || true; done
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT
command -v tmux >/dev/null 2>&1 || { echo "SKIP: tmux not installed"; exit 0; }

ROOT="$TEST_ROOT/state"
TRACKER="$TEST_ROOT/agent-tracker"
mkdir -p "$ROOT" "$TEST_ROOT/home" "$TEST_ROOT/work dir" "$TEST_ROOT/tracker cwd"
date '+%s' > "$ROOT/.last_refresh"

# One tmux session (a name with a space) whose single pane runs a plain shell
# in "work dir": that shell's PID is the session key, as for a real pane.
tmux -f /dev/null new-session -d -s "derive test" -c "$TEST_ROOT/work dir" -x 80 -y 24 "exec /bin/sh"
PANE_ID="$(tmux list-panes -t "derive test" -F '#{pane_id}')"
PANE_PID="$(tmux list-panes -t "derive test" -F '#{pane_pid}')"
[ -n "$PANE_ID" ] && [ -n "$PANE_PID" ] || fail "precondition: the test tmux server has a pane"
WORK_DIR="$(tmux display-message -t "$PANE_ID" -p '#{pane_current_path}')"

# Claude adapter env, as a hook of session claude-derive in that pane.
notify_as() {
  local render_pid="$1"; shift
  HOME="$TEST_ROOT/home" NOTIFY_ROOT_DATA_DIR="$ROOT" NOTIFY_CONFIG_DIR="$TEST_ROOT/config" \
    AGENT_TRACKER_HOME="$TRACKER" NOTIFY_RENDER_PID="$render_pid" "$@"
}
hook() { local pid="$1"; shift; notify_as "$pid" env CLAUDE_CODE_SESSION_ID=claude-derive CLAUDE_PROJECT_DIR=/proj/hook bash "$NOTIFY" "$@" 2>/dev/null; }
plain() { local pid="$1"; shift; notify_as "$pid" bash "$NOTIFY" "$@" 2>/dev/null; }
status_field() { grep -E "^  $1 " | sed -E "s/^  $1 +//"; }
pane_style() { tmux show-options -p -t "$PANE_ID" -v window-style 2>/dev/null || true; }

# 1. agent-tracker absent: the pane comes from tmux by shell PID alone, and
#    pane colors are still set through it.
hook "$PANE_PID" session-start
[ "$(grep -c . "$ROOT/$PANE_PID/static.env")" -eq 3 ] || fail "static.env holds three keys"
for key in AGENT_TYPE AGENT_SESSION_ID SESSION_NAME; do
  grep -q "^$key=" "$ROOT/$PANE_PID/static.env" || fail "static.env keeps $key"
done
hook "$PANE_PID" event Working
[ "$(pane_style)" = "bg=#0a1028" ] || fail "Working colors the pane found by shell PID (got '$(pane_style)')"
plain "$PANE_PID" status > "$TEST_ROOT/s1"
[ "$(status_field TMUX_PANE < "$TEST_ROOT/s1")" = "$PANE_ID" ] || fail "status shows the derived pane"
[ "$(status_field TMUX_SESSION < "$TEST_ROOT/s1")" = "derive test" ] || fail "status shows the derived tmux session (with its space)"
# A plain `notify status` is not the session's own hook: the directory is
# tmux's view of the pane, not the invoker's $PWD.
[ "$(status_field AGENT_WD < "$TEST_ROOT/s1")" = "$WORK_DIR" ] || fail "neighbor directory falls back to tmux pane_current_path"
hook "$PANE_PID" status > "$TEST_ROOT/s1h"
[ "$(status_field AGENT_WD < "$TEST_ROOT/s1h")" = "/proj/hook" ] || fail "the session's own hook context gives its directory"
pass "no agent-tracker: pane, tmux session and directory derived; pane colored"

# 2. A renamed tmux session is seen at once: nothing stored to go stale
#    (the v5.10 bug class of notify.log 2026-08-18).
tmux rename-session -t "derive test" "renamed now"
plain "$PANE_PID" status > "$TEST_ROOT/s2"
[ "$(status_field TMUX_SESSION < "$TEST_ROOT/s2")" = "renamed now" ] || fail "a tmux rename is picked up without any refresh"
pass "tmux rename picked up without a refresh"

# 3. A v5.14 static.env with stale copies: the stale values are ignored on
#    load and dropped at the next rewrite.
printf '%s\n' "TIMESTAMP=2026-11-01T00:00:00" "SHELL_PID=$PANE_PID" "AGENT_TYPE=claude" \
  "AGENT_SESSION_ID=claude-derive" "AGENT_WD=/stale/dir" "AGENT_PID=1" "SESSION_NAME=" \
  "SESSION_TMUX_PANE=%999" "SESSION_TMUX_WINDOW=@999" "SESSION_TMUX_SESSION=stale" \
  "TRANSCRIPT_PATH=/stale.jsonl" > "$ROOT/$PANE_PID/static.env"
plain "$PANE_PID" status > "$TEST_ROOT/s3"
[ "$(status_field TMUX_PANE < "$TEST_ROOT/s3")" = "$PANE_ID" ] || fail "a stale stored pane is ignored"
[ "$(status_field AGENT_WD < "$TEST_ROOT/s3")" = "$WORK_DIR" ] || fail "a stale stored directory is ignored"
plain "$PANE_PID" refresh > /dev/null
[ "$(grep -c . "$ROOT/$PANE_PID/static.env")" -eq 3 ] || fail "refresh rewrites a v5.14 file down to three keys"
pass "v5.14 static.env: stale copies ignored, then dropped"

# 4. agent-tracker present: a neighbor's directory and agent PID come from its
#    last_seen.json; a malformed file or an unsafe session id is ignored.
sleep 60 & AGENT=$!
TEST_PIDS="$TEST_PIDS $AGENT"
mkdir -p "$TRACKER/data/sessions/claude-derive"
jq -cn --arg cwd "$TEST_ROOT/tracker cwd" --argjson pid "$AGENT" --arg pane "$PANE_ID" \
  '{ts:1,dt:"x",agent:"claude",uuid:"claude-derive",pid:$pid,pane_id:$pane,cwd:$cwd}' \
  > "$TRACKER/data/sessions/claude-derive/last_seen.json"
plain "$PANE_PID" status > "$TEST_ROOT/s4"
[ "$(status_field AGENT_WD < "$TEST_ROOT/s4")" = "$TEST_ROOT/tracker cwd" ] || fail "agent-tracker's cwd wins over tmux's pane path"
[ "$(status_field AGENT_PID < "$TEST_ROOT/s4")" = "$AGENT" ] || fail "agent-tracker's live pid is the agent PID"
printf '{not json' > "$TRACKER/data/sessions/claude-derive/last_seen.json"
plain "$PANE_PID" status > "$TEST_ROOT/s4b"
[ "$(status_field AGENT_WD < "$TEST_ROOT/s4b")" = "$WORK_DIR" ] || fail "a malformed last_seen.json falls back to tmux"
mkdir -p "$TEST_ROOT/x"
jq -cn --arg cwd /escaped '{cwd:$cwd}' > "$TEST_ROOT/x/last_seen.json"
printf '%s\n' "AGENT_TYPE=claude" "AGENT_SESSION_ID=../../../x" "SESSION_NAME=" > "$ROOT/$PANE_PID/static.env"
plain "$PANE_PID" status > "$TEST_ROOT/s4c"
[ "$(status_field AGENT_WD < "$TEST_ROOT/s4c")" = "$WORK_DIR" ] || fail "an unsafe session id never reads outside agent-tracker's folder"
pass "agent-tracker present: cwd and pid used; malformed file and unsafe id ignored"

# 5. A session whose shell is not a pane's root process (e.g. a pane started
#    straight on an agent): its own hook uses $TMUX_PANE; a later call with no
#    $TMUX_PANE finds the pane through agent-tracker; a dead pane is refused.
sleep 60 & SHELL2=$!
TEST_PIDS="$TEST_PIDS $SHELL2"
mkdir -p "$TRACKER/data/sessions/claude-other"
notify_as "$SHELL2" env CLAUDE_CODE_SESSION_ID=claude-other TMUX_PANE="$PANE_ID" bash "$NOTIFY" session-start 2>/dev/null
notify_as "$SHELL2" env CLAUDE_CODE_SESSION_ID=claude-other TMUX_PANE="$PANE_ID" bash "$NOTIFY" event Finished 2>/dev/null </dev/null
[ "$(pane_style)" = "bg=#0a2e0a" ] || fail "\$TMUX_PANE of the invoking hook colors its pane (got '$(pane_style)')"
plain "$SHELL2" status > "$TEST_ROOT/s5"
[ "$(status_field TMUX_PANE < "$TEST_ROOT/s5")" = "(none)" ] || fail "without agent-tracker or \$TMUX_PANE no pane is invented"
jq -cn --arg pane "$PANE_ID" '{pane_id:$pane}' > "$TRACKER/data/sessions/claude-other/last_seen.json"
plain "$SHELL2" status > "$TEST_ROOT/s5b"
[ "$(status_field TMUX_PANE < "$TEST_ROOT/s5b")" = "$PANE_ID" ] || fail "agent-tracker's pane_id is used when tmux has no pane for the shell"
[ "$(status_field TMUX_SESSION < "$TEST_ROOT/s5b")" = "renamed now" ] || fail "the tmux session follows agent-tracker's pane"
jq -cn '{pane_id:"%424242"}' > "$TRACKER/data/sessions/claude-other/last_seen.json"
plain "$SHELL2" status > "$TEST_ROOT/s5c"
[ "$(status_field TMUX_PANE < "$TEST_ROOT/s5c")" = "(none)" ] || fail "a pane tmux no longer knows is refused"
pass "non-root shell: \$TMUX_PANE for its own hook, agent-tracker's pane otherwise"

# 6. Dead shells are still pruned by refresh --all, keyed by the folder name.
sleep 0.1 & DEAD=$!
wait "$DEAD" 2>/dev/null || true
mkdir -p "$ROOT/$DEAD"
printf '%s\n' "AGENT_TYPE=claude" "AGENT_SESSION_ID=gone" "SESSION_NAME=" > "$ROOT/$DEAD/static.env"
plain "$PANE_PID" refresh --all > /dev/null
[ ! -d "$ROOT/$DEAD" ] || fail "a dead shell's folder is pruned"
[ -d "$ROOT/$PANE_PID" ] || fail "a live shell's folder is kept"
pass "dead shells pruned by folder name"

printf '\nAll %s derived-context scenarios passed.\n' "$pass_count"
