#!/bin/bash
# iterm-status with its shipped default settings and several panes in one tmux
# session: the dot takes the most urgent category's color (priority order), the
# subtitle counts every category, Seen panes do not count.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_helpers.sh"
TEST_ROOT="$(mktemp -d /tmp/notify-tests.XXXXXX)"
trap 'rm -rf "$TEST_ROOT"' EXIT

state_root="$TEST_ROOT/state" tty="$TEST_ROOT/tty" bin="$TEST_ROOT/bin"
mkdir -p "$bin"
: > "$tty"

# pane %1..%5 -> shell pid 81001..81005, one per state below
printf '%s\n' '#!/bin/bash' \
  '[ "$1" = list-panes ] && printf "%%1 81001\n%%2 81002\n%%3 81003\n%%4 81004\n%%5 81005\n"' \
  'exit 0' > "$bin/tmux"
chmod +x "$bin/tmux"
pane() { # <pid> <agent state> <user state>
  mkdir -p "$state_root/$1"
  printf 'AGENT_TYPE=claude\n' > "$state_root/$1/static.env"
  printf 'AGENT_STATE=%s\nUSER_STATE=%s\n' "$2" "$3" > "$state_root/$1/state.env"
}

run_renderer() {
  : > "$tty"
  PATH="$bin:$PATH" ROOT_DATA_DIR="$state_root" RENDER_PID=81001 TRIGGER=REFRESH \
    SESSION_TMUX_SESSION=multi CLIENT_TTY="$tty" \
    RENDERER_SETTINGS="$(jq '{"iterm-status": .}' "$PROJECT_DIR/release/renderers.d/iterm-status/settings.json")" \
    bash "$PROJECT_DIR/release/renderers.d/iterm-status/main"
  sed $'s/\033\\]/\\n/g; s/\a//g' "$tty" | grep '^21337;'
}
log() { :; }
export -f log

pane 81001 Finished Pending
pane 81002 Working Pending
pane 81003 WaitingForUser Pending
pane 81004 Finished Seen
pane 81005 Idle OnHold
out=$(run_renderer)
[ "$out" = "21337;status=1 waiting · 1 working · 1 done · 1 on hold;indicator=#5f87ff;status-color=#5f87ff" ] || \
  fail "waiting wins the dot, every category counted, Seen left out (got: $out)"

pane 81003 Finished Seen
out=$(run_renderer)
[ "$out" = "21337;status=1 working · 1 done · 1 on hold;indicator=#ff9500;status-color=#ff9500" ] || \
  fail "working wins once nothing waits (got: $out)"

for pid in 81001 81002 81005; do pane "$pid" Finished Acknowledged; done
out=$(run_renderer)
[ "$out" = "21337;status=;indicator=;status-color=" ] || fail "nothing counts: tab status cleared (got: $out)"

pass "iterm-status: priority, counts and clearing with the shipped defaults"
