# agent-notify

Agent-neutral terminal notifications for concurrent coding sessions. A small lifecycle API records
agent and user state; independent renderers turn that state into tmux pane colors, terminal-title
icons, bells, and optional macOS text-to-speech. The CLI it ships is called `notify`.

Claude Code support is included, but the core does not depend on Claude's state names or hook
format. Other agents can call the same CLI through the generic adapter or add a native adapter.

## Install

```bash
./install.sh
```

The installer is safe to re-run and deploys:

| Purpose | Location |
|---|---|
| Runtime code | `~/opt/agent-notify/app/` |
| Persistent global settings | `~/opt/agent-notify/config/renderers.d/` |
| CLI | `~/.local/bin/notify` → runtime code |
| Runtime session state and log | `/tmp/agent-notify-$USER/` |
| Claude plugin, when Claude is installed | `~/.claude-templates-dev/components/plugins/notify` → runtime code |
| Codex plugin, when Codex is installed | local `notify-local` marketplace → runtime code |

Claude and Codex registration are automatic when their CLIs are on `PATH`. Use
`NOTIFY_INSTALL_CLAUDE=false` or `NOTIFY_INSTALL_CODEX=false` to skip either integration. On
non-macOS systems, the iTerm2 TTS listener is skipped.

## Lifecycle API

```bash
notify session-start
notify event Working
notify event WaitingForUser
notify event Finished
notify event Idle
notify session-end
```

Agent integrations provide normalized context through an adapter. See [INTEGRATIONS.md](INTEGRATIONS.md)
for the generic environment contract and native adapter interface.

## State model

| Dimension | Values | Updated by |
|---|---|---|
| `AGENT_STATE` | `Working`, `Finished`, `WaitingForUser`, `Idle` | Agent integration |
| `USER_STATE` | `Pending`, `Seen`, `Acknowledged`, `OnHold` | tmux focus/menu or CLI |

An agent-state change normally resets the user state to `Pending`. `OnHold` survives automatic
focus updates until it is changed deliberately.

## Commands

| Command | Purpose |
|---|---|
| `notify` / `notify status` | Show the current session and renderer configuration |
| `notify init` | Ensure the CLI symlink and managed tmux hooks are installed |
| `notify refresh [--all]` | Refresh metadata, render again, and prune dead sessions |
| `notify update AGENT_STATE VALUE` | Set normalized agent state manually |
| `notify update USER_STATE VALUE` | Set user state manually |
| `notify user-focus` | Apply tmux focus-derived user state |
| `notify wipe [--all]` | Remove session runtime state and reset renderers |
| `notify RENDERER enable\|disable` | Toggle a renderer |
| `notify RENDERER key=value [--global]` | Set a session or persistent global override |

Examples:

```bash
notify sound-tts disable --global
notify sound-bell Finished=2
notify tmux-pane-bg Finished.Pending=#0a2e0a --global
```

Settings merge in this order: renderer defaults from the deployed app, persistent global
overrides, then per-session overrides. Reinstalling replaces the app but preserves global settings.

## Renderers

- `sound-bell`: configurable bell count per agent state.
- `sound-tts`: iTerm2 relay to macOS `say`; see
  [sound-tts installation](release/renderers.d/sound-tts/INSTALL.md).
- `terminal-title`: aggregated state icons for every notify-managed pane in a tmux session.
- `tmux-pane-bg`: pane background color by combined agent/user state.

Copy `release/renderers.d/template/` to add another renderer. Renderers receive only normalized
environment variables; agent-native parsing belongs in `adapters.d/`.

## Current limitations

- State transitions are not yet locked against concurrent hook processes.
- Runtime `static.env` and `state.env` files are sourced as trusted shell code. This is an accepted
  single-user limitation, not safe for untrusted adapter metadata.
- Claude's subagent completion handling currently uses a bounded transcript scan pending validation
  of newer documented lifecycle hooks.

See [TODO.md](TODO.md) for rationale and planned work, and [TESTING.md](TESTING.md) for regression
checks.
