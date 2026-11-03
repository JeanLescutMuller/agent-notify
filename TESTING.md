# Testing

## Automated checks

Run the complete local suite from the repository root:

```bash
bash -n install.sh release/notify release/codex/notify release/adapters.d/*/main release/renderers.d/*/main release/renderers.d/*/install.sh
find release -name '*.json' -print0 | xargs -0 -n1 jq empty
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v
for t in tests/test_*.sh; do "$t"; done
claude plugin validate release
# Codex validates its manifest and hook schema while installing the local plugin.
git diff --check
```

All `tests/test_*.sh` scripts are isolated from real runtime state (throwaway `$HOME`/root-data
dirs, stub `tmux`/`claude`/`codex` binaries where needed) and are end-to-end scenarios, not a
branch-by-branch unit-test decomposition — see `tests/AGENTS.md` for the full map and rationale.

| File | Scenarios |
|---|---|
| `test_framework.sh` | Adapter selection (generic/codex/claude) × full state lifecycle, `USER_STATE` reset/`OnHold`/`Acknowledged` guardrails, `CLAUDE_STATE` v4 alias, tmux popup PID targeting + idempotency, absolute-path use in every `tmux-hooks.conf` `run-shell` line, `refresh --all` isolation including a later-visited invoker and detached refresh after status, all four renderers' literal output, a session-disabled renderer being skipped by the core dispatcher |
| `test_subagent_tracking.sh` | Stop-hook payloads (`background_tasks`) for the live T1/T2/T3/T5 shapes: one subagent, three staggered ones, a silent parent (refresh never invents Finished), a hung subagent then `idle_prompt`, subagent tool calls during a deferral; every payload variant (empty, missing, null, wrong type, junk entries, shells only, ended subagents in 5 statuses, unknown types, malformed, empty stdin, 400 entries); no stdin, a pipe that never closes (returns within the 2 s hook timeout), timing; a first event with no session dir and a renderer that reads stdin; only Finished deferred; OnHold kept; manual Finished never deferred; generic/codex adapters never defer; a v5.11 leftover `pending_finish` ignored |
| `test_log_cap.sh` | `notify.log` cap: over the cap keeps the newest half with whole lines and logs it once; under the cap untouched; never trimmed between debounced refreshes; a non-numeric cap or a missing log is harmless; the real 100 MB default on a 106 MB file, trimmed in the background while the hook returns at once |
| `test_tmux_focus.sh` | `user-focus` pane switching: focused pane → `Acknowledged`, other known panes → `Seen`, a plain shell pane untouched, `OnHold`/`Acknowledged` immune to the automatic path, empty `$TMUX_PANE` is a no-op |
| `test_renderer_settings.sh` | The real three-file settings merge (default < global < session) reaching actual renderer dispatch, and a session-scoped `enabled=false` overriding a default-enabled renderer |
| `test_waiting_debounce.sh` | `sound-bell`/`sound-tts`'s `waiting_debounce_secs` (see HISTORY.md's 2026-09-16 resolved entry): a `WaitingForUser` cleared within the window never rings/speaks, one that outlives it still does, `state.env`/other renderers update immediately regardless, `waiting_debounce_secs=0` stays fully synchronous, and background work never holds a piped hook's stdout/stderr (Codex `Hook failed`, HISTORY.md 2026-10-06) |
| `test_codex_hook_wrapper.sh` | Codex stdin JSON → normalized adapter context; runtime stdout/stderr suppression; non-zero runtime failures becoming traced, fail-open hook success; a stuck runtime being cut off before Codex's outer deadline |
| `test_codex_session_name.sh` | Codex title index → escaped metadata → actual TTS output; explicit-name priority; unchanged-index cache hits; rapid renames and late-generated titles; missing/malformed data; pane reuse and target-session identity |
| `test_cli_confirmations.sh` | One-line stdout confirmation from `update` (changed/unchanged), `wipe`, `refresh` and renderer settings (session/global scope, no-op); silence of `session-start`/`event`/`session-end`/`init` and of `NOTIFY_QUIET=true` callers |
| `test_notify_init.sh` | The managed tmux-hooks block lifecycle: `CLAUDE-NOTIFY`→`AGENT-NOTIFY` label migration, fresh deploy, idempotent redeploy, a real content change producing exactly one backup, and a hand-edited block being refused rather than clobbered |
| `test_install.sh` | Fresh install / idempotent reinstall / preserved `config/` / clean `app/` replacement; old-plugin-dir settings migration (migrated once, never re-migrated or clobbered); Claude/Codex plugin registration; compatibility links keeping already-open Codex sessions on the live wrapper |
| `test_manifests.sh` | Static `jq`/grep checks on both plugin manifests: absolute hook paths, event-appropriate timeouts, the documented `AskUserQuestion`/catch-all `PreToolUse` overlap, `NOTIFY_AGENT_TYPE=codex` always present, hook-event coverage matching this file's own mapping table |
| `test_known_issues.sh` | Opt-in (`RUN_KNOWN_ISSUES=1`) tripwires for two currently-accepted Todoist (`Repo: agent-notify`)/CLAUDE.md risks: the unlocked concurrent state-update race (informational — reproducing a real race black-box is probabilistic, so it never fails the suite by itself) and the shell-metadata trust boundary (deterministic) |

These suites call the adapters directly (or through hand-built hook payloads standing in for a real
Claude session) with representative native context. They deliberately do not pretend to test
whether Claude or Codex fired the native hook; use the live checks below for that boundary.

For an isolated installer smoke test that does not register Claude or touch the real home:

```bash
test_home=$(mktemp -d)
HOME="$test_home" NOTIFY_INSTALL_CLAUDE=false NOTIFY_INSTALL_CODEX=false ./install.sh
HOME="$test_home" NOTIFY_INSTALL_CLAUDE=false NOTIFY_INSTALL_CODEX=false ./install.sh
test -L "$test_home/.local/bin/notify"
test -x "$test_home/opt/agent-notify/app/notify"
rm -rf "$test_home"
```

The second install verifies idempotency. The full migration scenario — seeding an old plugin
directory with a modified renderer settings file and confirming it lands under
`~/opt/agent-notify/config/renderers.d/` after installation, without ever being re-migrated or
clobbered — is automated in `tests/test_install.sh`.

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

For Codex, "Resume after answering/approving" is driven by its `PostToolUse` hook (mapped to
`event Working` in `release/codex/hooks/hooks.json`), which fires the instant the tool actually
finishes — whether a permission request was approved by a human or auto-resolved by
`approvals_reviewer = "auto_review"` in `~/.codex/config.toml`. Before this was wired (resolved
2026-09-03), nothing cleared `WaitingForUser` until the *next*, unrelated `PreToolUse`, so an
auto-approved request could sit rendered as a wait for minutes. If Codex's `WaitingForUser` starts
lingering again, check `PostToolUse` coverage first (`tests/test_manifests.sh` asserts it) before
assuming it's a payload/timing issue.

The Codex wrapper is deliberately fail-open: it consumes the documented hook JSON from stdin,
suppresses all runtime output, records non-zero exits in
`/tmp/agent-notify-$USER/codex-hook-trace.jsonl`, and returns a clean hook result. To trace every
successful call temporarily, create `/tmp/agent-notify-$USER/.trace_codex_hooks`; remove it after
the live check.

Separately, `sound-bell`/`sound-tts` hold `WaitingForUser` for `waiting_debounce_secs` (default
8s) before actually ringing/speaking, re-checking `state.env` first - so during a live check, an
auto-approved permission request may show `WaitingForUser` in `notify status`/the tmux pane color
for a moment with no sound at all, while a real wait still alerts after the short delay. See
HISTORY.md's 2026-09-16 resolved entry and `tests/test_waiting_debounce.sh`.

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

These scenarios exercise Claude's real hooks. `tests/test_subagent_tracking.sh` replays their
Stop payloads; what it cannot prove is that the deployed Claude CLI still sends `background_tasks`
on the Stop hook's stdin and still wakes the parent when a subagent ends. Re-run T1-T3 after a
Claude Code upgrade, in a disposable session.

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

Expected log (the subagent runs in the background, so the first Stop comes before it ends):

```text
update AGENT_STATE Working
update AGENT_STATE Finished deferred (subagents still running)
update AGENT_STATE Finished
```

One audible/visual Finished, after the subagent ends. No `pending_finish` file is ever written.

### T2 — parallel dispatched subagents

Prompt:

> Dispatch three subagents in parallel. Their only tool calls are respectively `sleep 3`,
> `sleep 7`, and `sleep 12`. Wait for all three, then answer with “T2 complete.”

Expected: one or more `deferred` lines, no intermediate Finished renderer pass, and exactly one
final Finished after the longest task. This also stresses the still-open unlocked writer path;
inspect the log for interleaved `RENDER` groups or corrupted `state.env`.

### T3 — silent background completion

Prompt:

> Dispatch one background subagent whose only tool call is `sleep 20`, then end the parent turn
> immediately and do not poll it.

Expected: the parent Stop is deferred; when the subagent ends, Claude wakes the parent, whose new
turn logs `update AGENT_STATE Finished` within a few seconds. There is no polling any more.

### T4 — AskUserQuestion hook overlap

Trigger Claude's `AskUserQuestion` tool and inspect the same session's log. Until the TODO item is
fixed, both `WaitingForUser` and catch-all `Working` hook commands may run, in nondeterministic order.
Record the result when changing the plugin manifest; the eventual fix should emit only
`WaitingForUser` for this tool.

### T5 — hung or killed subagent

If a subagent never ends, or ends without Claude waking the parent (a killed or failed subagent
was not measured on 2.1.317), the pane stays Working until Claude's `idle_prompt` Notification
sets Idle about 60 s after the last Stop. Check that Idle arrives and no stale Finished precedes it.

## Manual renderer checks

- `notify status` should show Default, optional Global override, and optional Session override.
- Change a session setting, reinstall, and confirm the session override remains in `/tmp`.
- Change a global setting, reinstall twice, and confirm it remains under `~/opt/agent-notify/config`.
- On Debian, installation must print that the iTerm2 TTS listener was skipped and must not create
  `~/Library/Application Support/iTerm2/`.
- On macOS/iTerm2, use the raw control sequence in
  `release/renderers.d/sound-tts/INSTALL.md` to verify the listener independently of Claude.
