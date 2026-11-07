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
same root shell. In the normal shell/tmux case, PID discovery is enough. Only the adapter, the session id and the title are stored (v5.15): `NOTIFY_AGENT_WD` and `NOTIFY_AGENT_PID` apply to the call that carries them with the same session id; otherwise the working directory comes from agent-tracker (when installed) or tmux's `pane_current_path` ("Session fields: stored or derived" below):

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
| `NOTIFY_TRANSCRIPT_PATH` | Optional native transcript path of this hook call, passed to `adapter_has_pending_work`; not stored |
| `NOTIFY_RENDER_PID` | Root shell PID when process-tree/tmux discovery is unavailable |
| `NOTIFY_ROOT_DATA_DIR` | Test/advanced override for runtime state root |
| `NOTIFY_CONFIG_DIR` | Test/advanced override for persistent configuration root |

Metadata currently enters trusted shell-backed runtime files. Do not pass untrusted values; see
the accepted limitation in Todoist (`Repo: agent-notify`).

## Native adapter contract

Create `release/adapters.d/<agent>/main`. It is sourced by the core and must define:

```bash
adapter_load_context
adapter_resolve_agent_pid <shell-pid>
adapter_resolve_session_name <native-session-id>
adapter_has_pending_work <transcript-path>
```

- `adapter_load_context` may set `AGENT_SESSION_ID`, `AGENT_WD`, `AGENT_PID`, and
  `ADAPTER_TRANSCRIPT_PATH`. These describe the invoking call only: the core stores the session id,
  and uses the directory and PID only for that same session ("Session fields: stored or derived" below).
- PID and session-name resolvers print their value or print nothing.
- Optional `adapter_refresh_session_name` updates the loaded session's `SESSION_NAME` before
  status output and changed-agent-state rendering. The default is a no-op; adapters can cache
  expensive lookups under `SESSION_DATA_DIR`. The core persists changed names as escaped shell
  assignments. The callback must use the loaded session's identity, not the invoker's context.
- `adapter_has_pending_work` is asked only for a Finished request. It returns success while work
  remains outstanding (Finished is then dropped, nothing is stored: the agent must send a new
  Finished later) and failure otherwise. It may read the hook's own stdin payload; the core keeps
  stdin untouched for it (renderers get `/dev/null`). It must fail open, never read a terminal, and return within 1 s (Claude Code passes stdin
  on a socket, not a pipe).
- Agent-specific helpers belong beside the adapter, not under a renderer.

The core snapshots the invoking adapter's identity once before loading any saved
sessions. Both explicit `refresh --all` and detached periodic sweeps retain that
snapshot; reading a neighboring session must never replace the caller's identity.

Renderers receive only normalized fields such as `AGENT_TYPE`, `AGENT_SESSION_ID`, `AGENT_WD`,
`AGENT_PID`, `SESSION_NAME`, `AGENT_STATE`, and `USER_STATE`. They must not inspect native hook
input, native environment variables, or transcript formats.

## Session fields: stored or derived

`/tmp/agent-notify-$USER/<shell-pid>/static.env` keeps only what agent-notify needs and nothing else gives; every other field is derived when it is read, by `derive_session_context` in `release/notify`. agent-tracker is optional: without it, tmux and the hook's own context give everything renderers use.

| Field (v5.14 `static.env`) | Read by, when | Now | Source at that moment |
|---|---|---|---|
| `SHELL_PID` | `resolve_client_tty` fallback (`ps -o tty=`), each render | dropped | `RENDER_PID` (the folder name) |
| `SESSION_TMUX_PANE` | `tmux-pane-bg`, `sound-tts` (pane title), each render | dropped | `tmux list-panes -a`: the pane whose `pane_pid` is `RENDER_PID`; else the invoking process's `$TMUX_PANE` (its own shell only); else agent-tracker's `pane_id`, if tmux still has that pane |
| `SESSION_TMUX_SESSION` | `terminal-title`, `resolve_client_tty`, each render | dropped | same tmux line (`session_name`); a copy went stale on `tmux rename-session` (2026-08-18) |
| `SESSION_TMUX_WINDOW` | no renderer (renderer contract only) | dropped | same tmux line (`window_id`) |
| `AGENT_WD` | `sound-tts` name fallback, `status` | dropped | the invoking hook's context (`CLAUDE_PROJECT_DIR`, Codex stdin `cwd`) when it is this very session; else agent-tracker's `cwd`; else tmux `pane_current_path` |
| `AGENT_PID` | `status` only | dropped | invoking context; else agent-tracker's `pid` if alive; `status` then asks the adapter's process-tree lookup |
| `TRANSCRIPT_PATH` | `adapter_has_pending_work` argument; no adapter reads it since v5.12 | dropped | the invoking hook's own `transcript_path` (`ADAPTER_TRANSCRIPT_PATH`) |
| `TIMESTAMP` | nobody | dropped | `notify.log` has the times |
| `AGENT_TYPE` | `load_adapter` for neighbor sessions (`--all`, `user-focus`, the tmux menu), `status` | **kept** | nothing else says which adapter owns a shell; agent-tracker does not see Codex panes |
| `AGENT_SESSION_ID` | `cmd_refresh` (a new agent session in the same shell wipes the old state), title lookup, agent-tracker lookup | **kept** | the previous id of this shell is agent-notify's own state: the hook gives only the new one |
| `SESSION_NAME` | `sound-tts`, `status` | **kept** (cache) | Claude: a Python scan of the transcript; generic: given once at `session-start`; Codex refreshes its own cache |

Derived fields are exported to renderers under the same names (`renderers.d/template/main`). Old files are read without their dropped keys and rewritten with three keys at the next refresh (at most 300 s).

## Claude integration

`./install.sh` registers the Claude plugin automatically when `claude` is available. The plugin
directory is a symlink to the shared runtime; Claude-specific parsing remains under
`adapters.d/claude/`.

The adapter takes its session from Claude's environment variables. For the `Stop` hook it reads the
stdin JSON ([Claude hook documentation](https://code.claude.com/docs/en/hooks)): a running
`subagent` in `background_tasks` defers Finished until Claude's wake-up turn (v5.12, measured on
Claude Code 2.1.317; HISTORY.md "Subagent completion tracking").

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
