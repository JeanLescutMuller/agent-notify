# Testing

## Automated checks

Run the complete local suite from the repository root:

```bash
bash -n install.sh release/notify release/codex/notify release/adapters.d/*/main release/renderers.d/*/main release/renderers.d/*/install.sh
find release -name '*.json' -print0 | xargs -0 -n1 jq empty
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v
./tests/test_framework.sh
claude plugin validate release
# Codex validates its manifest and hook schema while installing the local plugin.
git diff --check
```

`test_framework.sh` is isolated from real runtime state and tests:

| Boundary | Coverage |
|---|---|
| Adapter → framework | Generic, Codex, and Claude adapter selection; `Working`, `WaitingForUser`, `Finished`, and `Idle`; `USER_STATE` reset and `OnHold` guardrails; session cleanup |
| Framework isolation | `refresh --all` cannot leak adapter or transcript metadata between sessions |
| tmux popup | Direct pane-PID targeting, no state creation for plain shell panes, and idempotent selections |
| Framework → renderers | Every adapter dispatches all four renderers on agent-state changes |
| Renderer output | BEL byte, iTerm2 TTS sequence, aggregated terminal title, and both tmux pane-style options |

This suite calls the adapters directly with representative native context. It deliberately does
not pretend to test whether Claude or Codex fired the native hook; use the live checks below for
that boundary.

For an isolated installer smoke test that does not register Claude or touch the real home:

```bash
test_home=$(mktemp -d)
HOME="$test_home" NOTIFY_INSTALL_CLAUDE=false NOTIFY_INSTALL_CODEX=false ./install.sh
HOME="$test_home" NOTIFY_INSTALL_CLAUDE=false NOTIFY_INSTALL_CODEX=false ./install.sh
test -L "$test_home/.local/bin/notify"
test -x "$test_home/opt/agent-notify/app/notify"
rm -rf "$test_home"
```

The second install verifies idempotency. A complete migration test should additionally seed an old
real plugin directory with a modified renderer settings file and confirm it appears under
`~/opt/agent-notify/config/renderers.d/` after installation.

## Live adapter → framework checks

Run `./install.sh`, then start **new** Claude and Codex sessions in separate tmux panes. Hooks are
loaded when a session starts. In Codex, use `/hooks` to confirm the `notify` hooks are enabled and
trusted. In either pane, record its shell PID and watch only its state:

```bash
render_pid=$(tmux display-message -p '#{pane_pid}')
state_file="/tmp/agent-notify-$USER/$render_pid/state.env"
log_file="/tmp/agent-notify-$USER/notify.log"
while true; do
  clear
  printf '\nSTATE\n'
  sed -n '1,20p' "$state_file"
  printf '\nLOG\n'
  grep "\[$render_pid\]" "$log_file" | tail -20
  sleep 0.2
done
```

Use another pane to interact with the test session. Expected native mappings are:

| Action | Claude expected state | Codex expected state |
|---|---|---|
| Start a new session | session directory created | session directory created |
| Submit a prompt | `Working` | `Working` |
| Agent asks a question / requests permission | `WaitingForUser` | `WaitingForUser` |
| Resume after answering/approving | `Working` | `Working` |
| Turn completes | `Finished` | `Finished` |
| Codex turn is interrupted | n/a | `Idle` |
| Agent process exits | session directory removed | session directory removed |

For Claude, `AskUserQuestion` still has the known catch-all `PreToolUse` overlap described in T4
below; if the final state is incorrectly `Working`, capture the bounded log before changing hooks.

After `Finished`, run the tmux menu acknowledgement (`Ctrl-B`, then `A`). `USER_STATE` should become
`Acknowledged`, and the command must not print `No active session found`.

## Live framework → renderer checks

Keep the state/log watcher above running. For reproducible manual transitions inside either agent
pane, use:

```bash
NOTIFY_RENDER_PID="$render_pid" notify event Working
NOTIFY_RENDER_PID="$render_pid" notify event WaitingForUser
NOTIFY_RENDER_PID="$render_pid" notify event Finished
NOTIFY_RENDER_PID="$render_pid" notify update USER_STATE Seen
NOTIFY_RENDER_PID="$render_pid" notify update USER_STATE OnHold
NOTIFY_RENDER_PID="$render_pid" notify event Idle
```

Expected default visuals:

| State | Pane background | Terminal-title icon |
|---|---|---|
| `Working` | `#0a1028` | 🔵 |
| `WaitingForUser` | `#2e2e0a` | 🟡 |
| `Finished.Pending` | `#0a2e0a` | 🟢 |
| `Finished.Seen` | default | ⚪ |
| `Finished.Acknowledged` | default | no icon |
| `Finished.OnHold` | `#200a1a` | 🟣 |
| `Idle.Pending` | `#0a2e0a` | 🟢 |

Verify the actual tmux options, independently of what the pane looks like:

```bash
tmux show-options -p -t "$TMUX_PANE" window-style
tmux show-options -p -t "$TMUX_PANE" window-active-style
grep "\[$render_pid\].*terminal-title: title\|\[$render_pid\].*tmux-pane-bg:" "$log_file" | tail -20
```

`WaitingForUser` should ring twice and speak once; `Finished` should ring once and speak once with
the configured volume. Audio/TTS are state-change renderers, so `USER_STATE` changes and `refresh`
must not replay them. Disable audio temporarily if needed with:

```bash
NOTIFY_RENDER_PID="$render_pid" notify sound-bell disable
NOTIFY_RENDER_PID="$render_pid" notify sound-tts disable
```

Run the live checks once from Claude and once from Codex. The framework and renderers are shared,
but testing both proves that each native hook reaches the same normalized path.

## Live Claude subagent regression

These scenarios exercise Claude's real hook and transcript behavior, which is not reproduced by
the unit tests. Use a disposable Claude session.

### Bound a log window

`notify.log` is shared by all sessions:

```bash
render_pid=<RENDER_PID from `notify status`>
log=/tmp/agent-notify-$USER/notify.log
mark() { printf '%s [%s] ==== %s ====\n' "$(date +%FT%T)" "$render_pid" "$1" >> "$log"; }
mark "T1 START"
# Run scenario.
mark "T1 END"
```

Filter a session with:

```bash
grep "\[$render_pid\]" /tmp/agent-notify-$USER/notify.log
```

New logs use `update AGENT_STATE ...`; `CLAUDE_STATE` appears only in migrated v4 files.

### T1 — one dispatched subagent

Prompt:

> Dispatch one subagent whose only tool call is `sleep 5`, then wait for its result and answer with
> “T1 complete.”

Expected behavior:

```text
update AGENT_STATE Working
update AGENT_STATE Finished suppressed (agent still has pending work)
pending_finish resolved (subagents cleared) - applying Finished
```

There should be one audible/visual Finished transition, after the dispatched work clears.

### T2 — parallel dispatched subagents

Prompt:

> Dispatch three subagents in parallel. Their only tool calls are respectively `sleep 3`,
> `sleep 7`, and `sleep 12`. Wait for all three, then answer with “T2 complete.”

Expected: no intermediate Finished renderer pass and exactly one final Finished after the longest
task. This also stresses the still-open unlocked writer path; inspect the log for interleaved
`RENDER` groups or corrupted `state.env`.

### T3 — silent background completion

Prompt:

> Dispatch one background subagent whose only tool call is `sleep 20`, then end the parent turn
> immediately and do not poll it.

Expected: the parent Stop is suppressed while the transcript reports pending work. After completion,
the shortened refresh interval should resolve Finished without another parent-side prompt. Allow up
to roughly 15 seconds after completion for the poll.

### T4 — AskUserQuestion hook overlap

Trigger Claude's `AskUserQuestion` tool and inspect the same session's log. Until the TODO item is
fixed, both `WaitingForUser` and catch-all `Working` hook commands may run, in nondeterministic order.
Record the result when changing the plugin manifest; the eventual fix should emit only
`WaitingForUser` for this tool.

### T5 — long/orphaned background tool

The historical 90-second background Bash scenario once left the Claude subagent without a final
completion signal. Repeat only when investigating the external orphan issue in `TODO.md`; an orphan
will intentionally leave `pending_finish` unresolved.

## Manual renderer checks

- `notify status` should show Default, optional Global override, and optional Session override.
- Change a session setting, reinstall, and confirm the session override remains in `/tmp`.
- Change a global setting, reinstall twice, and confirm it remains under `~/opt/agent-notify/config`.
- On Debian, installation must print that the iTerm2 TTS listener was skipped and must not create
  `~/Library/Application Support/iTerm2/`.
- On macOS/iTerm2, use the raw control sequence in
  `release/renderers.d/sound-tts/INSTALL.md` to verify the listener independently of Claude.
