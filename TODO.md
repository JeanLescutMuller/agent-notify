# agent-notify TODO

## Correctness

### Serialize overlapping state updates

`update_state_and_render` performs an unlocked read/modify/write/render sequence. Concurrent hook
commands can therefore read the same old state, overwrite each other's `state.env`, reuse the same
`*.tmp` path, and interleave renderer calls. This was observed during the rapid T9 test in
`TESTING.md`.

The Claude plugin currently makes this race especially easy to hit for `AskUserQuestion`: both the
specific `WaitingForUser` `PreToolUse` hook and the matcher-less `Working` hook match that tool, and
Claude runs matching hooks concurrently.

Possible fix:

- Route each native hook event through one adapter dispatcher so it emits only one normalized
  state transition.
- Protect the full per-session state transition and renderer pass with a portable lock. macOS does
  not ship `flock`, so a carefully cleaned-up `mkdir` lock is the likely common implementation.
- Replace fixed `file.tmp` names with unique, same-directory temporary files and atomic renames.

### Re-evaluate Claude's documented hook lifecycle

The current Claude adapter reflects behavior verified during the August 2026 subagent
investigation: hook stdin appeared empty, subagent completion did not trigger a usable parent hook,
and completion was only reliably visible through the parent transcript's queue-operation entries.
That is why `adapter_has_pending_work` scans a bounded transcript tail and the core maintains a
`pending_finish` marker.

Current [Claude Code hook documentation](https://code.claude.com/docs/en/hooks) describes common
JSON hook input on stdin (`session_id`, `cwd`, `transcript_path`) and native
`SubagentStart`/`SubagentStop` events carrying `agent_id`.
Validate those events against the actually deployed Claude CLI. If reliable, replace the
undocumented environment lookup, transcript parsing, and 15-second pending-finish polling with
adapter-owned lifecycle markers.

### Decide how new activity supersedes a pending finish

If a suppressed `Finished` becomes resolvable immediately before a new `Working` event,
`try_resolve_pending_finish` currently renders the old `Finished` first and then applies `Working`.
Decide whether the completion notification is still desired or whether new activity should simply
cancel the stale marker.

## Accepted personal-project risk

### Runtime `.env` files are sourced as shell

`static.env` and `state.env` are written as unquoted shell assignments and later sourced. Values
containing spaces can fail to load, and shell syntax in adapter metadata, session titles, working
directories, tmux names, or manually supplied state values can execute code when the file is read.

This should use JSON or safely escaped assignments before the project accepts untrusted adapters
or is installed for other users. It is intentionally not being fixed while this remains a trusted,
single-user personal project.

## Claude-specific external issue

### A subagent's backgrounded tool call can orphan the task

In the old T10 scenario, a forked Claude subagent running a long background Bash command stopped
updating its transcript and never produced a final completion notification. This appears to be
Claude Code behavior rather than a notify state bug, but an orphan also means the transcript-based
pending-work detector remains pending forever.

## Renderer enhancements

### Add status-aware TTS announcements

Include the state in spoken text, for example “Backend needs you” versus “Backend is done.”

### Speak directly on macOS when possible

When notify itself runs locally on macOS and `say` is available, compare direct speech with the
current iTerm2 control-sequence relay. Keep the relay for remote sessions.

### Add nonce-based TTS deduplication

Include a bounded event nonce in the sender/listener protocol if duplicate delivery is ever
observed. Current listener-side queue deduplication has been sufficient in practice.

### Add per-session voice/rate controls

The listener already selects a deterministic voice from the session name. Consider exposing the
voice pool and rate in persistent renderer settings.

## Resolved history

- **Project renamed to agent-notify (2026-08-29):** GitHub repo, `~/dev`, `~/opt`, and marketplace
  symlinks now use `agent-notify`. The CLI command, plugin names, and env var prefix stay `notify`
  for brevity.
- **False Finished during dispatched subagents (2026-08-27):** Claude's `Stop` means the parent
  stopped generating, not necessarily that dispatched work completed. The Claude adapter now
  detects dispatched-but-not-completed agent IDs in the parent transcript, suppresses the early
  transition, and resolves one pending finish when the work clears. See `TESTING.md` for the live
  regression scenarios and the limitations above.
- **Global settings lost on reinstall (2026-08-27):** mutable overrides now live under
  `~/opt/notify/config`, separate from the replaceable `~/opt/notify/app` deployment.
