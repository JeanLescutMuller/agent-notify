# sound-tts: iTerm2 listener setup

The renderer sends `Custom=id=tts:<payload>` control sequences to the attached terminal. On macOS,
the iTerm2 AutoLaunch listener receives them and serializes calls to the built-in `say` command.
This renderer is independent of the agent integration that produced the state change.

## Automated deployment

Run the project installer:

```bash
./install.sh
```

On macOS it copies `notify_tts_async_say.py` to:

```text
~/Library/Application Support/iTerm2/Scripts/AutoLaunch/notify_tts_async_say.py
```

On other operating systems this renderer installer exits without creating macOS paths.

## One-time iTerm2 setup

1. iTerm2 → Settings → General → Magic → enable **Python API**.
2. iTerm2 → Scripts → AutoLaunch → select `notify_tts_async_say.py` to start it without restarting
   iTerm2.
3. Accept iTerm2's bundled Python runtime download if prompted.

The listener log is:

```text
~/Library/Application Support/iTerm2/Scripts/AutoLaunch/notify_tts_async_say.log
```

It should contain `listener-start` followed by `listener-ready`.

## Verify outside tmux

Run in a plain iTerm2 tab:

```bash
printf '\033]1337;Custom=id=tts:%s\a' "[[volm 0.7]] notify direct test"
```

The phrase should be spoken and the listener log should show `received`, `queued`, `speak-start`,
and `speak-end`.

## tmux passthrough

The renderer wraps the control sequence for tmux. tmux 3.3 and later require:

```tmux
set-option -g allow-passthrough on
```

Reload after changing the setting:

```bash
tmux source-file ~/.tmux.conf
```

Without passthrough, the listener works in plain iTerm2 sessions but does not receive sequences from
inside tmux.

## Reload after edits

Re-run `./install.sh`, then select the listener again from iTerm2's Scripts menu. A full iTerm2
restart is not required.
