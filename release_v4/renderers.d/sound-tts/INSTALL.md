# notify_tts_async_say - iTerm2 install

What this is: the local, MacBook-side listener that catches the `Custom=id=tts:<name>`
escape sequence sent by the notify plugin's `sound-tts` renderer, and speaks it via
macOS `say`. It's a separate component from `release_v4/` (the Claude Code plugin) -
this only lives on the Mac, as an iTerm2 AutoLaunch Python script.

## Prerequisites

- macOS with iTerm2 installed.
- `say` (built-in on macOS, nothing to install).
- tmux, if you want notifications to work through tmux panes - needs one config line, see "tmux passthrough" below.

## Steps

**Automated - run `./install.sh` from the project root** (or `renderers.d/sound-tts/install.sh` directly): creates `~/Library/Application Support/iTerm2/Scripts/AutoLaunch/` if missing and copies `notify_tts_async_say.py` there. Source of truth stays at `release_v4/renderers.d/sound-tts/notify_tts_async_say.py` - re-run `./install.sh` any time it's edited (no iTerm2 restart needed, see step 4 below).

**Manual - GUI-only actions, one-time per machine:**

1. iTerm2 → Preferences (⌘,) → General → Magic → check **"Enable Python API"**.
2. iTerm2 → Scripts → AutoLaunch → click **`notify_tts_async_say.py`** to launch it manually (avoids a full iTerm2 restart - useful if a Claude Code session is running directly in an iTerm2 tab, not inside tmux, since quitting iTerm2 would kill it).
3. First launch triggers iTerm2's **"Download Python Runtime?"** dialog (~178MB, one-time, official iTerm2 download) - click OK.

## Verification

- iTerm2 → Scripts → Script Console shows `notify_tts_async_say` running.
- Log file `~/Library/Application Support/iTerm2/Scripts/AutoLaunch/notify_tts_async_say.log` shows `listener-start` then `listener-ready`.
- Sent a raw test sequence from a plain (non-tmux) iTerm2 tab:
  ```
  printf '\033]1337;Custom=id=tts:%s\a' "rung two direct test"
  ```
  Heard it spoken; log showed `received` → `queued` → `speak-start` → `speak-end`. **Confirmed working.**

## Re-running after edits

Per iTerm2's own docs, no restart is ever required after editing an AutoLaunch script - re-run `./install.sh` and click it again in the Scripts menu.

## tmux passthrough - required for notifications sent from inside tmux

`sound-tts` wraps its escape sequence in a tmux DCS passthrough when going through tmux. Since tmux 3.3, forwarding that to the underlying terminal requires `allow-passthrough` to be on - it **defaults to off**. Add this to `~/.tmux.conf` (not part of this repo, it's your local tmux config):

```
set-option -g allow-passthrough on
```

Reload with `tmux source-file ~/.tmux.conf`, or restart tmux. Without it, notifications sent from inside a tmux pane never reach this listener (they work fine outside tmux regardless, as verified above).

**Status on this Mac: done.** Added to `~/.tmux.conf` and confirmed working end-to-end - a `sound-tts`-format sequence sent from inside a tmux pane is received, queued, and spoken.
