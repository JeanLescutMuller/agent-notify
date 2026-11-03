#!/bin/bash
# End-to-end scenarios for Claude subagent completion tracking: a Stop hook's
# stdin JSON lists `background_tasks`; a running subagent there defers
# Finished, and the parent's next turn (Claude wakes it when the subagent
# ends) brings its own Working and Finished. Payload shapes are the ones
# measured on Claude Code 2.1.317 (2026-11-03). Automates TESTING.md's live
# T1/T2/T3/T5 shapes; see tests/AGENTS.md scenarios 5-8.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_helpers.sh"
TEST_ROOT="$(mktemp -d /tmp/notify-tests.XXXXXX)"
trap 'rm -rf "$TEST_ROOT"' EXIT

SESSION_ID="subagent-test-session"
NEXT_PID=81000

# --- payloads ---------------------------------------------------------------
# task ID TYPE STATUS -> one background_tasks entry
task() { printf '{"id":"%s","type":"%s","status":"%s","description":"t"}' "$1" "$2" "$3"; }
# stop_payload [ENTRY,ENTRY...] -> a Stop hook's stdin JSON
stop_payload() {
  printf '{"session_id":"%s","transcript_path":"/tmp/x.jsonl","cwd":"/tmp","hook_event_name":"Stop","stop_hook_active":false,"background_tasks":[%s]}' \
    "$SESSION_ID" "${1:-}"
}

# --- runners ----------------------------------------------------------------
# Each scenario gets its own root data dir and render pid. The last refresh is
# stamped "now" so no debounced background refresh interferes.
new_session() {
  NEXT_PID=$((NEXT_PID + 1))
  RENDER_PID=$NEXT_PID
  ROOT="$TEST_ROOT/$1"
  mkdir -p "$ROOT"
  date '+%s' > "$ROOT/.last_refresh"
}

# run_as ADAPTER ARGS... ; stdin is passed through (the hook payload).
run_as() {
  local adapter="$1"; shift
  local -a env_args=(
    HOME="$TEST_ROOT/home"
    NOTIFY_ROOT_DATA_DIR="$ROOT"
    NOTIFY_CONFIG_DIR="$TEST_ROOT/config"
    NOTIFY_RENDER_PID="$RENDER_PID"
  )
  case "$adapter" in
    claude) env_args+=(CLAUDE_CODE_SESSION_ID="$SESSION_ID" CLAUDE_PROJECT_DIR="$PROJECT_DIR") ;;
    *)      env_args+=(NOTIFY_AGENT_TYPE="$adapter" NOTIFY_AGENT_SESSION_ID="$SESSION_ID") ;;
  esac
  ${STDIN_VIA[@]+"${STDIN_VIA[@]}"} env -u CLAUDE_CODE_SESSION_ID -u NOTIFY_AGENT_TYPE "${env_args[@]}" bash "$NOTIFY" "$@" 2>/dev/null
}
claude()      { run_as claude "$@"; }
# A hook with no payload at all (CLI, tmux menu): stdin is not a pipe.
claude_bare() { run_as claude "$@" </dev/null; }
# STDIN_VIA: optional command prefix that supplies stdin (see on_socket).
STDIN_VIA=()
# on_socket PAYLOAD HOLD_SECS CMD...: runs CMD with stdin on a Unix socket, the
# way Claude Code (Node) passes hook stdin; writes PAYLOAD, keeps the socket
# open HOLD_SECS more, then closes it.
# The seconds notify itself ran go to $ROOT/socket_secs.
SOCKET_PY='import os,socket,subprocess,sys,time
a,b=socket.socketpair(); t0=time.time(); p=subprocess.Popen(sys.argv[3:],stdin=b); b.close()
a.sendall(sys.argv[1].encode()); end=t0+float(sys.argv[2])
while p.poll() is None and time.time()<end: time.sleep(0.05)
done=p.poll() is not None; secs=time.time()-t0
a.close(); rc=p.wait(); secs=secs if done else time.time()-t0
open(os.environ["SOCKET_SECS_FILE"],"w").write("%.2f"%secs); sys.exit(rc)'
on_socket() { local payload="$1" hold="$2"; shift 2; SOCKET_SECS_FILE="$ROOT/socket_secs" python3 -c "$SOCKET_PY" "$payload" "$hold" "$@"; }
# stop JSON: the Stop hook, payload on a pipe.
stop()        { printf '%s' "$1" | claude event Finished; }

state_is()      { assert_file_contains "$ROOT/$RENDER_PID/state.env" "AGENT_STATE=$1" "$2"; }
user_state_is() { assert_file_contains "$ROOT/$RENDER_PID/state.env" "USER_STATE=$1" "$2"; }
finished_applied() { grep -cE "\[$RENDER_PID\] update AGENT_STATE Finished$" "$ROOT/notify.log" 2>/dev/null || true; }
deferred_count()   { count_log_occurrences "$ROOT/notify.log" "[$RENDER_PID] update AGENT_STATE Finished deferred (subagents still running)"; }
state_renders()    { count_log_occurrences "$ROOT/notify.log" "[$RENDER_PID] RENDER AGENT_STATE_UPDATE sound-bell"; }
no_marker() { [ ! -e "$ROOT/$RENDER_PID/pending_finish" ] || fail "$1: no pending_finish marker is ever written"; }

start_working() { claude_bare session-start; claude_bare event Working; }

# === A. Lifecycle shapes (the live T1/T2/T3/T5 scenarios) ====================

test_t1_single_subagent() {
  new_session t1; start_working
  local renders_before; renders_before=$(state_renders)

  stop "$(stop_payload "$(task a1 subagent running)")"
  state_is Working "T1 Stop while the subagent runs: still Working"
  assert_log_contains "$ROOT/notify.log" "running subagents: 1" "T1 the check logs what it saw"
  [ "$(deferred_count)" -eq 1 ] || fail "T1 deferral logged once"
  [ "$(state_renders)" -eq "$renders_before" ] || fail "T1 a deferred Finished renders nothing"
  no_marker T1

  # Claude wakes the parent: UserPromptSubmit (Working), then Stop, list empty.
  claude_bare event Working
  stop "$(stop_payload "")"
  state_is Finished "T1 Finished once the subagent is gone"
  [ "$(finished_applied)" -eq 1 ] || fail "T1 exactly one Finished ($(finished_applied))"
  [ "$(state_renders)" -eq $((renders_before + 1)) ] || fail "T1 exactly one new state render"
  pass "T1: one subagent defers Finished; the wake-up turn finishes once"
}

test_t2_parallel_subagents() {
  new_session t2; start_working
  stop "$(stop_payload "$(task p1 subagent running),$(task p2 subagent running),$(task p3 subagent running)")"
  claude_bare event Working
  stop "$(stop_payload "$(task p1 subagent completed),$(task p2 subagent running),$(task p3 subagent running)")"
  claude_bare event Working
  stop "$(stop_payload "$(task p3 subagent running)")"
  state_is Working "T2 still Working while one of three runs"
  [ "$(finished_applied)" -eq 0 ] || fail "T2 no premature Finished"
  [ "$(deferred_count)" -eq 3 ] || fail "T2 three deferrals ($(deferred_count))"
  claude_bare event Working
  stop "$(stop_payload "")"
  state_is Finished "T2 Finished after the last subagent"
  [ "$(finished_applied)" -eq 1 ] || fail "T2 exactly one Finished"
  pass "T2: parallel subagents: Finished only after the last one"
}

test_t3_background_parent_idle() {
  new_session t3; start_working
  stop "$(stop_payload "$(task b1 subagent running)")"
  # The parent says nothing more while the subagent runs: refreshes must not
  # invent a Finished (nothing is polled any more).
  local i; for i in 1 2 3; do claude_bare refresh >/dev/null; done
  state_is Working "T3 refresh never turns a deferred Finished into Finished"
  [ "$(finished_applied)" -eq 0 ] || fail "T3 no Finished from refresh"
  claude_bare event Working
  stop "$(stop_payload "")"
  state_is Finished "T3 the wake-up turn brings Finished"
  pass "T3: silent background subagent: Finished comes with Claude's wake-up turn"
}

test_subagent_tool_calls_while_deferred() {
  new_session subtools; start_working
  stop "$(stop_payload "$(task s1 subagent running)")"
  # A subagent's own tool calls fire the parent's PreToolUse (with agent_id).
  printf '{"hook_event_name":"PreToolUse","agent_id":"s1","tool_name":"Bash"}' | claude event Working
  printf '{"hook_event_name":"PreToolUse","agent_id":"s1","tool_name":"Bash"}' | claude event Working
  state_is Working "subagent tool calls keep the parent Working"
  stop "$(stop_payload "")"
  state_is Finished "then Finished"
  pass "subagent tool calls during a deferral keep Working"
}

test_t5_hung_subagent_then_idle() {
  new_session t5; start_working
  stop "$(stop_payload "$(task h1 subagent running)")"
  # The subagent never ends (or Claude never wakes the parent): Claude's own
  # idle_prompt Notification (60 s) still moves the pane on, straight to Idle,
  # with no stale Finished rendered first (old task "new activity supersedes
  # a pending finish": now moot).
  claude_bare event Idle
  state_is Idle "T5 idle_prompt applies after a deferral"
  [ "$(finished_applied)" -eq 0 ] || fail "T5 no stale Finished before Idle"
  pass "T5: hung subagent: Idle still arrives, no stale Finished"
}

# === B. Payload variants =======================================================

expect_finished() {   # expect_finished NAME PAYLOAD
  new_session "$1"; start_working
  printf '%s' "$2" | claude event Finished
  state_is Finished "$1: Finished applies at once"
  [ "$(deferred_count)" -eq 0 ] || fail "$1: nothing deferred"
}
expect_deferred() {   # expect_deferred NAME PAYLOAD
  new_session "$1"; start_working
  printf '%s' "$2" | claude event Finished
  state_is Working "$1: Finished deferred"
  [ "$(deferred_count)" -eq 1 ] || fail "$1: one deferral logged"
}

test_payload_variants() {
  expect_finished empty-list "$(stop_payload "")"
  expect_finished no-field '{"session_id":"x","hook_event_name":"Stop"}'
  expect_finished null-field '{"hook_event_name":"Stop","background_tasks":null}'
  expect_finished not-a-list '{"hook_event_name":"Stop","background_tasks":"running"}'
  expect_finished junk-entries '{"hook_event_name":"Stop","background_tasks":[1,"subagent",null]}'
  expect_finished shell-only "$(stop_payload "$(task sh1 shell running)")"
  local st
  for st in completed failed killed stopped cancelled; do
    expect_finished "subagent-$st" "$(stop_payload "$(task x1 subagent "$st")")"
  done
  expect_finished unknown-type "$(stop_payload "$(task u1 cron running)")"
  expect_finished malformed '{"background_tasks":[{"type":"subagent","status":"running"'
  expect_finished empty-stdin ''
  pass "payload variants that must not defer: empty, missing, null, wrong type, shells, ended subagents, malformed, empty"

  expect_deferred shell-plus-subagent "$(stop_payload "$(task sh1 shell running),$(task a1 subagent running)")"
  expect_deferred mixed-ended "$(stop_payload "$(task a1 subagent completed),$(task a2 subagent running)")"
  local big="" i
  for i in $(seq 1 400); do big+="$(task "sh$i" shell running),"; done
  expect_deferred large-payload "$(stop_payload "${big}$(task last subagent running)")"
  pass "payload variants that defer: subagent among shells, among ended ones, at the end of 400 entries"
}

test_payload_on_socket() {
  # Claude Code passes hook stdin on a socket, not a pipe: the case a pipe-only
  # draft of v5.12 missed live.
  new_session socket; start_working
  STDIN_VIA=(on_socket "$(stop_payload "$(task k1 subagent running)")" 0)
  claude event Finished
  STDIN_VIA=()
  state_is Working "socket payload with a running subagent: deferred"
  STDIN_VIA=(on_socket "$(stop_payload "")" 0)
  claude event Finished
  STDIN_VIA=()
  state_is Finished "socket payload with an empty list: Finished"
  # tmux run-shell's stdin is a socket that gives end-of-file at once.
  new_session socket-empty; start_working
  STDIN_VIA=(on_socket "" 0)
  claude event Finished
  STDIN_VIA=()
  state_is Finished "empty socket (tmux run-shell): Finished at once"
  # A socket held open with no data must not hang past the hook timeout.
  new_session socket-open; start_working
  STDIN_VIA=(on_socket "" 4)
  claude event Finished
  STDIN_VIA=()
  awk -v s="$(cat "$ROOT/socket_secs")" 'BEGIN { exit !(s <= 2) }' \
    || fail "open socket: notify ran $(cat "$ROOT/socket_secs") s (Stop hook timeout is 2 s)"
  state_is Finished "open socket with no data: Finished (fail open)"
  pass "payload on a socket (Claude Code), empty socket (tmux), open socket: all handled"
}

test_no_stdin() {
  new_session nostdin; start_working
  claude_bare event Finished
  state_is Finished "no payload (CLI, tmux menu): Finished at once"
  pass "no stdin: Finished at once"
}

test_open_pipe_never_hangs() {
  new_session openpipe; start_working
  local t0 t1
  t0=$(date '+%s')
  { sleep 4; } | { claude event Finished; date '+%s' > "$ROOT/t1"; }
  t1=$(cat "$ROOT/t1")
  [ $((t1 - t0)) -le 2 ] || fail "open pipe: notify returned after $((t1 - t0)) s (Stop hook timeout is 2 s)"
  state_is Finished "open pipe with no data: Finished (fail open)"
  pass "a pipe that never closes: returns within the hook timeout, Finished"
}

test_stop_hook_fast() {
  new_session timing; start_working
  local t0 t1
  t0=$(date '+%s')
  stop "$(stop_payload "$(task f1 subagent running)")"
  t1=$(date '+%s')
  [ $((t1 - t0)) -le 1 ] || fail "deferral took $((t1 - t0)) s"
  pass "a deferral with a payload returns at once"
}

# === C. Interplay with the rest of notify =====================================

test_fresh_session_first_event_is_stop() {
  # No session dir yet: cmd_refresh runs the renderers before the check, and
  # they must not eat the payload. A scratch copy of release/ gets an extra
  # renderer that reads all of its stdin, as a careless renderer would.
  local real_notify="$NOTIFY" copy="$TEST_ROOT/release-copy"
  cp -R "$PROJECT_DIR/release" "$copy"
  mkdir -p "$copy/renderers.d/zz-eats-stdin"
  printf '#!/bin/bash\ncat >/dev/null\n' > "$copy/renderers.d/zz-eats-stdin/main"
  chmod +x "$copy/renderers.d/zz-eats-stdin/main"
  NOTIFY="$copy/notify"
  new_session fresh
  stop "$(stop_payload "$(task a1 subagent running)")"
  NOTIFY="$real_notify"
  assert_log_contains "$ROOT/notify.log" "RENDER REFRESH zz-eats-stdin" "fresh session: the stdin-reading renderer ran first"
  [ "$(deferred_count)" -eq 1 ] || fail "fresh session: payload still reaches the adapter after renderers ran"
  pass "fresh session: renderers (even one reading stdin) do not consume the hook payload"
}

test_only_finished_is_deferred() {
  new_session wait; start_working
  printf '%s' "$(stop_payload "$(task a1 subagent running)")" | claude event WaitingForUser
  state_is WaitingForUser "WaitingForUser applies while a subagent runs"
  printf '%s' "$(stop_payload "$(task a1 subagent running)")" | claude event Idle
  state_is Idle "Idle applies while a subagent runs"
  pass "only Finished is deferred; WaitingForUser and Idle apply"
}

test_onhold_survives() {
  new_session onhold; start_working
  claude_bare update USER_STATE OnHold >/dev/null
  stop "$(stop_payload "$(task a1 subagent running)")"
  user_state_is OnHold "OnHold kept across a deferral"
  stop "$(stop_payload "")"
  state_is Finished "Finished applied"
  user_state_is OnHold "OnHold kept across the final Finished"
  pass "USER_STATE OnHold survives a deferral and the final Finished"
}

test_manual_finished_overrides() {
  new_session manual; start_working
  stop "$(stop_payload "$(task a1 subagent running)")"
  claude_bare update AGENT_STATE Finished >/dev/null
  state_is Finished "a manual update AGENT_STATE Finished applies during a deferral"
  pass "manual Finished (CLI/tmux menu) is never deferred"
}

test_other_adapters_ignore_payload() {
  local adapter
  for adapter in generic codex; do
    new_session "adapter-$adapter"
    run_as "$adapter" session-start </dev/null
    run_as "$adapter" event Working </dev/null
    printf '%s' "$(stop_payload "$(task a1 subagent running)")" | run_as "$adapter" event Finished
    state_is Finished "$adapter adapter: Finished at once"
  done
  pass "generic and codex adapters never defer"
}

test_v511_leftover_marker_ignored() {
  # A session upgraded in place from v5.11 may still hold pending_finish.
  new_session leftover; start_working
  touch "$ROOT/$RENDER_PID/pending_finish"
  claude_bare refresh >/dev/null
  state_is Working "a leftover marker never applies Finished"
  # It no longer shortens the 300 s refresh to 15 s.
  echo $(( $(date '+%s') - 20 )) > "$ROOT/.last_refresh"
  local stamp; stamp=$(cat "$ROOT/.last_refresh")
  claude_bare event Working
  [ "$(cat "$ROOT/.last_refresh")" = "$stamp" ] || fail "leftover marker still triggers the 15 s refresh"
  pass "v5.11 leftover pending_finish is ignored (no Finished, no 15 s refresh)"
}

test_t1_single_subagent
test_t2_parallel_subagents
test_t3_background_parent_idle
test_subagent_tool_calls_while_deferred
test_t5_hung_subagent_then_idle
test_payload_variants
test_payload_on_socket
test_no_stdin
test_open_pipe_never_hangs
test_stop_hook_fast
test_fresh_session_first_event_is_stop
test_only_finished_is_deferred
test_onhold_survives
test_manual_finished_overrides
test_other_adapters_ignore_payload
test_v511_leftover_marker_ignored
printf '\nAll %s subagent-tracking scenarios passed.\n' "$pass_count"
