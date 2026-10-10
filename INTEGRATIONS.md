# Agent integrations

agent-notify exposes one normalized lifecycle regardless of the native agent:

```bash
notify session-start
notify event Working
notify event WaitingForUser
notify event Finished
notify event Idle
notify session-end
```

The bundled Claude and Codex plugins map their native hooks to these commands. Other tools can use
the generic adapter or add a native adapter under `release/adapters.d/`.

## Generic adapter

Provide context as environment variables on `session-start`:

```bash
NOTIFY_AGENT_TYPE=generic \
NOTIFY_AGENT_SESSION_ID="$native_session_id" \
NOTIFY_AGENT_WD="$PWD" \
NOTIFY_AGENT_PID="$native_agent_pid" \
NOTIFY_SESSION_NAME="$optional_title" \
NOTIFY_RENDER_PID="$pane_root_shell_pid" \
notify session-start
```

Use the same context for later lifecycle calls when the hook process cannot be resolved back to the
same root shell. In the normal shell/tmux case, persisted metadata and PID discovery are enough:

```bash
NOTIFY_AGENT_TYPE=generic notify event Working
NOTIFY_AGENT_TYPE=generic notify event Finished
```

Variables:

| Variable | Meaning |
|---|---|
| `NOTIFY_AGENT_TYPE` | Adapter directory name; defaults to `generic` |
| `NOTIFY_AGENT_SESSION_ID` | Native session identifier |
| `NOTIFY_AGENT_WD` | Agent working directory |
| `NOTIFY_AGENT_PID` | Native agent process PID, if useful diagnostically |
| `NOTIFY_SESSION_NAME` | Optional human-readable title |
| `NOTIFY_TRANSCRIPT_PATH` | Optional native transcript used by a custom pending-work adapter |
| `NOTIFY_RENDER_PID` | Root shell PID when process-tree/tmux discovery is unavailable |
| `NOTIFY_ROOT_DATA_DIR` | Test/advanced override for runtime state root |
| `NOTIFY_CONFIG_DIR` | Test/advanced override for persistent configuration root |

Metadata currently enters trusted shell-backed runtime files. Do not pass untrusted values; see
the accepted limitation in `TODO.md`.

## Native adapter contract

Create `release/adapters.d/<agent>/main`. It is sourced by the core and must define:

```bash
adapter_load_context
adapter_resolve_agent_pid <shell-pid>
adapter_resolve_session_name <native-session-id>
adapter_has_pending_work <transcript-path>
```

- `adapter_load_context` may set `AGENT_SESSION_ID`, `AGENT_WD`, `AGENT_PID`, and
  `ADAPTER_TRANSCRIPT_PATH`.
- PID and session-name resolvers print their value or print nothing.
- Optional `adapter_refresh_session_name` updates the loaded session's `SESSION_NAME` before
  status output and changed-agent-state rendering. The default is a no-op; adapters can cache
  expensive lookups under `SESSION_DATA_DIR`. The core persists changed names as escaped shell
  assignments. The callback must use the loaded session's identity, not the invoker's context.
- `adapter_has_pending_work` returns success while work remains outstanding and failure otherwise.
- Agent-specific helpers belong beside the adapter, not under a renderer.

The core snapshots the invoking adapter's identity once before loading any saved
sessions. Both explicit `refresh --all` and detached periodic sweeps retain that
snapshot; reading a neighboring session must never replace the caller's identity.

Renderers receive only normalized fields such as `AGENT_TYPE`, `AGENT_SESSION_ID`, `AGENT_WD`,
`AGENT_PID`, `SESSION_NAME`, `AGENT_STATE`, and `USER_STATE`. They must not inspect native hook
input, native environment variables, or transcript formats.

## Claude integration

`./install.sh` registers the Claude plugin automatically when `claude` is available. The plugin
directory is a symlink to the shared runtime; Claude-specific parsing remains under
`adapters.d/claude/`.

The current adapter uses Claude environment variables and a bounded transcript scan for dispatched
subagent completion. Current [Claude hook documentation](https://code.claude.com/docs/en/hooks)
describes stdin JSON and native subagent lifecycle hooks; validating and adopting those is tracked
in `TODO.md` rather than assumed from documentation alone.

## Codex integration

`./install.sh` registers the local `notify-local` Codex marketplace and installs its `notify`
plugin automatically when `codex` is available. Codex lifecycle hooks map session start/end,
prompt submission, tool use, permission requests, stop, and interrupt events to normalized notify
states. Its thin plugin wrapper lives under `release/codex/`; the adapter, state framework, and
renderers remain shared with Claude. The wrapper consumes Codex's stdin JSON and translates
`session_id`, `cwd`, and `transcript_path` into normalized adapter context. It is fail-open because
notifications are advisory: runtime output is suppressed, failures are traced, and a watchdog
finishes before the outer Codex deadline. Start a new Codex session after installation so the hooks
are loaded. During an upgrade, the installer preserves old Codex plugin-cache roots as symlinks to
the live wrapper so already-open sessions do not start failing at their frozen `PLUGIN_ROOT` path.
Notify does not install a Codex skill or slash command; invoke the CLI from agent chat with `!
notify` when shell-command execution is supported.

The Codex adapter resolves `SESSION_NAME` from the last matching `thread_name` in
`${CODEX_HOME:-$HOME/.codex}/session_index.jsonl`. It caches the name per notify session and
reparses only when the index's inode, size or precise modification time changes. Start/resume,
`notify status`, and changed agent states check the name; repeated tool events that leave the
state unchanged do not. Titles generated or renamed after startup are picked up on the next
check. Missing/unreadable data yields no name, malformed lines are ignored, and normal TTS
fallbacks remain available. An explicit sound-tts `name` setting still has highest priority,
followed by the Codex session title, tmux pane title, and working-directory name. The index is a
local Codex implementation detail, not a guaranteed hook API.

## v4 compatibility

The first v5 invocation moves `/tmp/claude-notify-$USER` to `/tmp/agent-notify-$USER` when the new
path does not exist. Old `CLAUDE_*` fields and `notify update CLAUDE_STATE VALUE` remain readable
during migration; all new writes and renderer triggers use `AGENT_*` names.
