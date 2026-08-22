# Claude Notify

Notification system for Claude Code sessions. Provides visual and audio feedback for session state changes (Working, Finished, WaitingForUser, Idle) across multiple concurrent tmux panes.

## Current Version

**v4** (`release_v4/`) - deployed as a Claude Code plugin via `claude-templates-dev` marketplace.

Previous versions (v2, v3) are not present in this directory - do not reference them.

## Architecture

One unified bash script (`notify`) handles all commands. Each renderer lives in its own folder under `renderers.d/`, self-contained: its own executable, its own settings, and (optionally) its own deploy step - so different renderers can be maintained independently without touching shared files.

### Source tree

```
notify/
├-- release_v4/                       # The Claude Code plugin (deployed via install.sh)
|   ├-- .claude-plugin/plugin.json    # Plugin manifest (hooks, metadata)
|   ├-- notify                        # Main CLI and hook handler
|   ├-- renderers.d/
|   |   ├-- sound-bell/
|   |   |   ├-- main                  # Terminal bell (configurable count per state)
|   |   |   '-- settings.json         # This renderer's own default settings (unwrapped)
|   |   ├-- sound-tts/
|   |   |   ├-- main                  # Emits an iTerm2 Custom control sequence -
|   |   |   |                         #   actual speech happens on the Mac side
|   |   |   ├-- settings.json
|   |   |   ├-- notify_tts_async_say.py  # The Mac-side listener (see below)
|   |   |   ├-- resolve_claude_session_name.py  # Looks up a session's custom
|   |   |   |                         #   title from its JSONL transcript by UUID
|   |   |   ├-- install.sh            # Deploys notify_tts_async_say.py to iTerm2's
|   |   |   |                         #   AutoLaunch dir; run by the top-level install.sh
|   |   |   '-- INSTALL.md            # Remaining manual, GUI-only setup steps
|   |   ├-- terminal-title/
|   |   |   ├-- main                  # Aggregated emoji icons in terminal tab title
|   |   |   '-- settings.json
|   |   ├-- tmux-pane-bg/
|   |   |   ├-- main                  # Tmux pane background color per state
|   |   |   '-- settings.json
|   |   '-- template/                 # Reference skeleton for writing a new renderer.
|   |       ├-- main                  #   Deliberately kept non-executable - never
|   |       '-- settings.json         #   discovered/invoked as a real renderer.
|   !-- tmux/
|       --- tmux-hooks.conf           # Injected into ~/.tmux.conf by `notify init`
├-- install.sh                        # Deploys release_v4/ as a user-scope Claude Code
|                                     # plugin, then runs any renderers.d/*/install.sh
|                                     # it finds. Idempotent, safe to re-run after any edit.
└-- TODO.md                           # Open issues and deferred work, with rationale
```

`notify_tts_async_say/` as a top-level sibling directory no longer exists - it moved into `renderers.d/sound-tts/`, since it's specific to that one renderer, not a separate component.

### Runtime state tree (on disk, not in this repo)

```
/tmp/claude-notify-$USER/
├-- notify.log                        # Every command + render event, timestamped
├-- .last_refresh                     # Debounce marker for the periodic background refresh
└-- <shell_pid>/                      # One directory per active session (RENDER_PID = shell pid)
    ├-- static.env                    # Session metadata: CLAUDE_UUID, CLAUDE_WD, CLAUDE_PID,
    |                                 #   SESSION_TMUX_PANE/WINDOW/SESSION
    ├-- state.env                     # Current CLAUDE_STATE and USER_STATE
    '-- renderers.d/                  # Session-level renderer overrides - same layout as the
        '-- <renderer>/               #   source tree's renderers.d/<name>/, one dir per renderer
            '-- settings.json         #   (unwrapped, mirrors renderers.d/<name>/settings.json);
                                       #   created on first `notify <renderer> ...` write without
                                       #   --global. Room for a renderer to keep other per-session
                                       #   files here later, not just settings.
```

Deployed plugin files live at `~/.claude-templates-dev/components/plugins/notify/` (mirrors the source tree above, including per-renderer `renderers.d/<name>/settings.json`). `renderers.d/sound-tts/notify_tts_async_say.py` additionally gets copied out to `~/Library/Application Support/iTerm2/Scripts/AutoLaunch/notify_tts_async_say.py` - that's the one file living outside the plugin's own deployed tree, since iTerm2 requires it there.

## Deployment

Two independent deployment surfaces - don't conflate them:

1. **The Claude Code plugin** (`release_v4/`): run `./install.sh` after any edit. It copies `release_v4/` to the deployed location, writes the marketplace manifest, (idempotently) registers + enables the plugin via `claude plugin marketplace add` / `claude plugin install`, `chmod +x`s every `renderers.d/*/main` except `template/`, then runs any `renderers.d/*/install.sh` it finds (currently just `sound-tts/install.sh`). Safe to re-run any time, including on a fresh machine.
   - **Deployed copy**: `~/.claude-templates-dev/components/plugins/notify/` (copied, not symlinked)
   - **PATH access**: `~/.local/bin/notify` symlink, created by `notify init` on SessionStart
   - **Plugin registration**: `~/.claude-templates-dev/components/.claude-plugin/marketplace.json`, `extraKnownMarketplaces`/`enabledPlugins` in `~/.claude/settings.json`
   - Hooks are frozen into a session at session start - a plugin/hook-command change requires restarting any already-running Claude Code session.

2. **`notify_tts_async_say.py`** (the Mac-side TTS listener, `renderers.d/sound-tts/`): its file copy is now automated via `sound-tts/install.sh` (part of the main `./install.sh` run). What's still separate, manual, per-machine setup: GUI steps (enable iTerm2's Python API, `tic`-fix macOS's terminfo gap, `allow-passthrough on` in `~/.tmux.conf`) that can't be scripted at all. See `renderers.d/sound-tts/INSTALL.md`.

**tmux hooks management**: `notify init` manages `tmux-hooks.conf`'s content in `~/.tmux.conf` via `deploy_managed_block` (box-delimited, `sha256`-verified - same mechanism as `bootstrap-home`'s dotfile blocks, kept in sync deliberately). Unlike the old marker-only scheme, this one *does* re-sync on every `notify init` run: if `tmux/tmux-hooks.conf` changes, the next `notify init` removes and reconstructs the block automatically (no manual patching needed), then reloads via `tmux source-file`. If someone hand-edits the block in `~/.tmux.conf` directly, the embedded hash won't match on the next `init` - it prints a diff and leaves the file untouched instead of overwriting the edit.

**tmux `run-shell` PATH caveat**: `tmux run-shell` spawns a non-interactive, non-login shell that does **not** source `~/.zshrc` (or equivalent) - so `~/.local/bin` is missing from its `PATH` even though it's on `PATH` in every normal interactive shell (confirmed via `tmux run-shell "echo \$PATH"`). A bare `notify` in any `tmux-hooks.conf` command (the `after-select-pane` hook, the notification menu) silently fails with "command not found" - silently because `run-shell`'s failure output only surfaces as a transient tmux status-line message, easy to miss, and produces **no** `notify.log` entry at all (the command never got far enough to run `log()`). Every `notify` invocation in `tmux-hooks.conf` therefore uses the absolute path `$HOME/.local/bin/notify` instead of relying on `PATH`.

**`MouseDown1Pane` rebind**: `after-select-pane` only fires when tmux's pane selection actually changes - clicking a pane that's already the active one (the common case: one pane per window) is a no-op for tmux, so the hook never fires and that pane's `USER_STATE` never updates to `Acknowledged`. `tmux-hooks.conf` therefore also rebinds `MouseDown1Pane` itself (preserving tmux's default `select-pane -t = \; send-keys -M`, appending a `run-shell` call to `notify user-focus` with `#{mouse_pane}`), so every click acknowledges its pane regardless of whether it was already active. Confirmed live: `after-select-pane` produced zero log output on a same-pane re-select even after the `PATH` fix above, while the `MouseDown1Pane` rebind fixed it.

## State Model

`status` and `state` are deliberately different words for different things in this codebase:
- **`status`** = the diagnostic *report* (`notify status`, `cmd_status`) - like `git status`.
- **`state`** = the two tracked *values* below (`CLAUDE_STATE`/`USER_STATE`) - like a state machine's state.

Two independent state dimensions per session:

| Dimension | Values | Set by |
|-----------|--------|--------|
| `CLAUDE_STATE` | Working, Finished, WaitingForUser, Idle | Plugin hooks (automatic) |
| `USER_STATE` | Pending, Seen, Acknowledged, OnHold | tmux focus/menu (user action) |

**Guardrails** in `update_state_and_render`:
- Changing claude state: move user state back to pending, except if manually put on hold
- Never downgrade a user state from acknowledged to seen
- Never downgrade an on-hold state to seen or acknowledged, even if user clicks on pane or window

State files live in `/tmp/claude-notify-$USER/<shell_pid>/` - see the runtime state tree above.

## Commands

| Command | Description |
|---------|-------------|
| `notify` or `notify status` | Show current session status report |
| `notify init` | Bootstrap: Ensure ~/.local/bin symlink exists + inject tmux hooks |
| `notify update CLAUDE_STATE <val>` | Update CLAUDE_STATE (used by hooks) |
| `notify update USER_STATE <val>` | Update USER_STATE (used by tmux menu) |
| `notify user-focus` | Technical. Called by tmux on pane switch (Acknowledged/Seen) |
| `notify refresh` | Refresh statics and re-render for the current session |
| `notify refresh --all` | Refresh statics and re-render for ALL sessions. Clean up all session state, deleting stale/zombie files on disk |
| `notify wipe` | Technical. Called by SessionEnd hook (session cleanup) |
| `notify wipe --all` | Could be used to remove ALL folders of ALL sessions, regardless if they are considered active or not (stale/zombie) |
| `notify <renderer> [on\|off\|enable\|disable\|key=val] [--global]` | Configure a renderer, e.g. `notify sound-tts enable`, `notify sound-bell Finished=2` |

The renderer name **is** the command - no separate verb (`notify sound-tts enable`, not `notify config sound-tts enable`). `cmd_settings` validates `$CMD` against an actual executable in `renderers.d/<name>/main` before doing anything, so a typo'd/unknown renderer name fails with a clear error rather than silently creating a bogus settings entry. `on`/`enable` and `off`/`disable` are aliases - both write `"enabled": true`/`false`, matching the JSON key name exactly (no vocabulary mismatch either way you type it). `update` stays a separate, explicit verb since `CLAUDE_STATE`/`USER_STATE` are a small, fixed set, not open-ended like renderer names.

## PID Resolution

The script identifies the correct session by walking the process tree from `$PPID` upward, looking for the first shell PID that has a session directory in `/tmp/claude-notify-$USER/`. Three contexts to handle:

1. **Plugin hooks** (`${CLAUDE_PLUGIN_ROOT}/notify`): walks past Claude processes, finds the pane's root shell
2. **`! notify` from inside Claude**: walks past the `!` subshell, finds the pane's root shell with session dir
3. **tmux `run-shell`** (menu actions): no shell in the tree at all (tmux execs directly via shebang), falls back to `TMUX_PANE` env var to look up pane_pid

**Login shells**: `ps -o comm=` reports a login shell as `-zsh`/`-bash` (leading dash - standard convention, not macOS-specific). The shell-name match strips a leading `-` before comparing; without that, the walk never recognizes a login shell (the default in a fresh iTerm2 tab) and falls through to "No active session found." Normally masked by the tmux `TMUX_PANE` fallback; only surfaces when running outside tmux.

**Non-login shells**: separately, `ps -o comm=` can report a *non-login* shell as a full path instead of a bare name - e.g. `/bin/zsh` instead of `zsh` (observed on macOS for a `claude` process launched under a plain, non-login zsh, as opposed to the `-zsh` a fresh iTerm2 tab starts). The walk strips any leading `dir/` (`${walk_cmd##*/}`) before the login-shell dash-strip, so both `/bin/zsh` and `-zsh` collapse to `zsh`. Without this, the walk climbs straight past that shell without recognizing it and (outside tmux, so the `TMUX_PANE` fallback can't mask it either) falls through to "No active session found," even for a brand-new session where hooks and registration are otherwise fine.

**`CLIENT_TTY` resolution** (`resolve_client_tty`, used by `sound-bell`/`sound-tts`/`terminal-title`): inside tmux, resolved via `tmux list-clients`. Outside tmux, via `ps -o tty= -p "$SHELL_PID"` (prefixed `/dev/`) - portable across macOS (BSD `ps`) and Linux (GNU `ps`). Do **not** use `/proc/$SHELL_PID/fd/0`; `/proc` doesn't exist on macOS.

## Renderer Settings

Each renderer owns its own `renderers.d/<name>/settings.json` (unwrapped - just that renderer's own keys, no `"<name>"` wrapper, since the folder already establishes identity). The session override mirrors this exactly - same `renderers.d/<name>/` layout, rooted under the session dir instead of the source tree: `/tmp/claude-notify-$USER/<pid>/renderers.d/<name>/settings.json`, also unwrapped. Global and override are the same shape and the same relative path, just different roots - and a renderer that ever needs to keep other per-session state has an obvious place for it (its own `renderers.d/<name>/` dir), no new convention needed. `resolve_renderer_settings` loops the renderer folders, merges each renderer's global file with its own override file (if one exists), and wraps the per-renderer results into one combined `{"<name>": {...}, ...}` object at runtime (`RENDERER_SETTINGS`). Top-level (not nested) since it has two callers: `call_all_renderers` and `cmd_status`.

`--global` writes **directly** to that renderer's own `renderers.d/<name>/settings.json` in the source tree. Without it, writes to that renderer's own `settings.json` under the session's `renderers.d/<name>/` dir. Same read/write code path either way - no wrapped-vs-unwrapped branching needed in `cmd_settings` since both are unwrapped now.

**Enable/disable**: `notify <renderer> on|off|enable|disable` toggles that renderer's `"enabled"` key. This is checked **once, at the framework level**, in `call_all_renderers` - a disabled renderer is never invoked at all. Individual renderers must not re-check `enabled` themselves.

`cmd_status` (`notify status`) prints each renderer under a `== <name>: enabled|disabled ==` header (computed the same way `call_all_renderers` gates execution, so the header always matches what will actually happen), then its own `renderers.d/<name>/settings.json` (global, compact one-line JSON via `jq -c`) under a `-- Global --` line, then its session-side override under `-- Override --` if one exists - the raw settings key/values are enough to tell what a renderer will do. On top of that, it invokes every renderer with `TRIGGER=STATUS` and prints whatever it prints to stdout (if anything) under a `-- Status --` line - this is opt-in per renderer (most don't implement a `STATUS` case, so it's a harmless no-op for them). Unlike the settings dump, this is for a renderer to surface something it *computed* that isn't just sitting in a settings file - e.g. `sound-tts` prints `TTS_NAME: '...'` / `TTS_NAME_REASON: '...'` (see `resolve_tts_name()`). No fixed convention beyond "print however many lines you want, or print nothing" - deliberately not the old `ACTIVE=yes|no`/`LABEL=`/`VALUE=`/`REASON=` KEY=VALUE parsing scheme, which added structure nothing needed.

**jq caveat**: The `//` (alternative) operator treats `false` as falsy. Use `has("key")` instead of `// default` when checking boolean fields that can be `false`.

## Known Issues

See `TODO.md` for the false "Finished" notifications during subagent dispatch.

## Development Notes

- Renderers dispatch on the outer `case "$TRIGGER" in` - **not** `$1`, renderers take no positional args. Valid values: `CLAUDE_STATE_UPDATE`, `USER_STATE_UPDATE`, `REFRESH`, `STATUS`. The `_UPDATE` suffix on the first two is deliberate - it distinguishes the *event* from the `$CLAUDE_STATE`/`$USER_STATE` *variables* they describe, which hold the actual values (Working/Finished/WaitingForUser/Idle/Pending/Acknowledged/Seen/OnHold), checked *inside* the relevant case. `STATUS` is optional (see Renderer Settings) - only implement it if the renderer has something computed worth surfacing in `notify status`.
- Renderers receive all state via exported vars (see `renderers.d/template/main` for the full list)
- Renderers must NOT source env files directly (except `terminal-title` which aggregates across panes)
- Renderers must NOT re-check the `enabled` flag - the framework already gates on it before invoking any renderer, for any trigger (see Renderer Settings)
- `sound-tts`'s `resolve_tts_name()` picks the spoken name via a priority chain: `sound-tts` settings' `name` key, then the Claude session's custom title (looked up by UUID via `resolve_claude_session_name.py` - see that file's docstring for the full problem writeup and benchmark behind its backward-chunked-scan approach), then the tmux pane title (ignored if it's still tmux's un-set default, which is just the machine hostname), then the working directory basename, then a hardcoded fallback.
- To add a new renderer: copy `renderers.d/template/` to `renderers.d/<name>/`, fill in `main`, `chmod +x` it (or just re-run `install.sh`, which does this for every folder except `template/`). Add `install.sh` in that same folder only if the renderer needs extra machine-level setup beyond being present as a file.
- Use `printf -v` instead of `eval` for dynamic variable assignment
- Log file: `/tmp/claude-notify-$USER/notify.log`
- `notify`'s `log()` is `export -f`'d, so every renderer subprocess inherits it directly (bash propagates exported functions to child bash processes the same way it propagates exported variables). A renderer's own `rlog()` is just a one-line wrapper adding its name as a prefix (e.g. `rlog() { log "${RENDER_PID:--}" "    sound-bell: $1"; }`) - it must NOT reimplement the timestamp/printf/redirect logic itself.
