# Notify development guide

Notify is an agent-neutral terminal notification system. The core tracks normalized agent and user
state; adapters translate native agent context, and renderers provide visual/audio output. Claude
Code is the first bundled integration, not the core's identity.

## Current version

The agent-neutral layout is **v5** under `release/`. Older source trees are not present. The v4
Claude-only runtime directory and state keys remain readable solely for in-place migration.

## Source tree

```text
notify/
├── release/
│   ├── .claude-plugin/plugin.json       # Claude integration manifest
│   ├── notify                           # Agent-neutral CLI/runtime
│   ├── adapters.d/
│   │   ├── generic/main                 # NOTIFY_* environment contract
│   │   └── claude/
│   │       ├── main                     # Claude context/pending-work adapter
│   │       └── resolve_session_name.py  # Claude transcript title lookup
│   ├── renderers.d/
│   │   ├── sound-bell/
│   │   ├── sound-tts/
│   │   ├── terminal-title/
│   │   ├── tmux-pane-bg/
│   │   └── template/                    # Non-executable renderer skeleton
│   └── tmux/tmux-hooks.conf
├── tests/
├── install.sh
├── README.md
├── INTEGRATIONS.md
├── TESTING.md
└── TODO.md
```

Each renderer directory owns its executable, immutable default `settings.json`, and optional
platform installer. Renderers must not inspect Claude variables or another agent's native format.

## Deployment

Run `./install.sh` after any edit. It is idempotent and self-migrates the old Claude-only layout.

| Surface | Location |
|---|---|
| Replaceable application | `~/opt/notify/app/` |
| Persistent global settings | `~/opt/notify/config/renderers.d/` |
| CLI symlink | `~/.local/bin/notify` |
| Claude marketplace plugin symlink | `~/.claude-templates-dev/components/plugins/notify` |
| macOS iTerm2 TTS listener | `~/Library/Application Support/iTerm2/Scripts/AutoLaunch/notify_tts_async_say.py` |

Claude registration runs only when `claude` is available, unless overridden with
`NOTIFY_INSTALL_CLAUDE=true|false`. Renderer installers must perform their own OS/capability check;
`sound-tts/install.sh` skips non-macOS hosts.

The installer replaces `app/` cleanly so removed adapters/renderers do not survive deployment. It
does not replace `config/`. During the first v5 install, settings that differ between the old
deployed plugin and current defaults are migrated into the persistent configuration.

Hooks are frozen into an active Claude session at session start; restart existing sessions after a
manifest or hook-command change.

## Runtime state

```text
/tmp/agent-notify-$USER/
├── notify.log
├── .last_refresh
└── <shell-pid>/
    ├── static.env
    ├── state.env
    ├── pending_finish                  # Claude adapter only, when applicable
    └── renderers.d/<renderer>/settings.json
```

`RENDER_PID` is the pane's root shell PID. Static metadata is normalized as `AGENT_TYPE`,
`AGENT_SESSION_ID`, `AGENT_WD`, `AGENT_PID`, `SESSION_NAME`, and tmux identifiers. State is
`AGENT_STATE` plus `USER_STATE`.

### Accepted trust boundary

`static.env` and `state.env` are unquoted assignments that are later sourced. Spaces can break
parsing and shell syntax in metadata can execute. This is deliberately accepted while the project
is single-user and all adapters/session names are trusted. Do not expose it to untrusted metadata
without replacing the files with JSON or safe serialization. The issue is tracked in `TODO.md`.

## Lifecycle and commands

Integrations call:

```text
notify session-start
notify event Working|Finished|WaitingForUser|Idle
notify session-end
```

User/technical commands:

| Command | Description |
|---|---|
| `notify status [--all]` | Diagnostic report |
| `notify init` | CLI symlink plus managed tmux hooks |
| `notify refresh [--all]` | Refresh/render and prune dead sessions |
| `notify update AGENT_STATE VALUE` | Manual normalized agent state |
| `notify update USER_STATE VALUE` | Manual user state |
| `notify user-focus` | tmux-derived Acknowledged/Seen update |
| `notify wipe [--all]` | Remove runtime session data and reset renderers |
| `notify <renderer> enable\|disable\|key=value [--global]` | Renderer settings |

`notify update CLAUDE_STATE VALUE` is accepted only for v4 compatibility.

### Invocation terminology

Notify is a CLI, not a Claude or Codex skill, and it does not provide `/notify` or `$notify`. In an
agent chat that supports direct shell commands, invoke it as `! notify`. If the user refers to the
"notify skill" or `/notify`, first ask them to reconfirm whether they mixed it up with invoking
`! notify` directly in the agent chat.

## State guardrails

| Dimension | Values |
|---|---|
| `AGENT_STATE` | `Working`, `Finished`, `WaitingForUser`, `Idle` |
| `USER_STATE` | `Pending`, `Seen`, `Acknowledged`, `OnHold` |

- An agent-state change resets user state to `Pending`, except from `OnHold`.
- Automatic focus updates never downgrade `Acknowledged` to `Seen`.
- Automatic focus updates do not clear `OnHold`; deliberate `update USER_STATE` commands can.

State transitions are currently not locked across concurrent processes. Do not describe them as
race-free; the open hook overlap and writer lock work is in `TODO.md`.

## PID and TTY resolution

The core walks from `$PPID` toward the root, normalizing full-path and login-shell command names,
and selects the first shell with a runtime session directory. If a tmux `run-shell` command has no
useful shell ancestor, `TMUX_PANE` resolves the exact pane root PID. Explicit integrations can set
numeric `NOTIFY_RENDER_PID`.

Inside tmux, `CLIENT_TTY` comes from the most recently active client. Outside tmux it falls back to
portable `ps -o tty= -p "$SHELL_PID"`; never use `/proc`, which does not exist on macOS.

Every `notify` call in `tmux-hooks.conf` uses `$HOME/.local/bin/notify`: tmux `run-shell` does not
load interactive shell PATH configuration. The `MouseDown1Pane` rebind preserves tmux's default
selection/mouse forwarding and adds acknowledgement for clicks on an already-active pane.

## Claude adapter notes

The Claude adapter currently derives transcript context from `CLAUDE_CODE_SESSION_ID` and
`CLAUDE_PROJECT_DIR`. `adapter_has_pending_work` compares dispatched Agent IDs with completion
queue entries in a bounded transcript tail. A `Stop`-requested `Finished` is suppressed while work
remains and represented by `pending_finish`; later updates or debounced `refresh --all` resolve it.

This reflects behavior verified during the 2026-08-27 investigation. Newer Claude documentation
advertises stdin context and native `SubagentStart`/`SubagentStop`; validate that against the
deployed CLI before replacing the working fallback. See `TODO.md` and `TESTING.md`.

## Renderer settings

Settings merge from lowest to highest precedence:

1. `release/renderers.d/<renderer>/settings.json` — immutable default.
2. `~/opt/notify/config/renderers.d/<renderer>/settings.json` — persistent global override.
3. `/tmp/agent-notify-$USER/<pid>/renderers.d/<renderer>/settings.json` — session override.

The core checks `enabled` once before invoking a renderer. Renderers must not check it again. When
testing boolean presence with jq, use `has("key")`; `//` treats `false` as a fallback condition.

Renderer triggers are `AGENT_STATE_UPDATE`, `USER_STATE_UPDATE`, `REFRESH`, and optional `STATUS`.
Renderers take no positional arguments and consume only exported fields documented in
`renderers.d/template/main`.

## Development checks

```bash
bash -n install.sh release/notify release/adapters.d/*/main release/renderers.d/*/main
find release -name '*.json' -print0 | xargs -0 -n1 jq empty
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v
claude plugin validate release
git diff --check
```

Use `printf -v` rather than `eval`. A renderer's `rlog()` must delegate to the exported core
`log()` function instead of reimplementing timestamp/file logic.
