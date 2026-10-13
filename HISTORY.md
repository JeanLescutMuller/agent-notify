# agent-notify: resolved issues

What was fixed, why, and how it is tested; cited by code comments and tests. Open work moved to Todoist on 2026-10-14 (tasks with `Repo: agent-notify`, skill `task-management`).

## Resolved history

- **Cross-session identity corruption during refresh (2026-10-08):** v5.9 captures the
  invoking adapter/session/PID/directory once, before loading saved sessions. Previously,
  a current session visited later in `refresh --all` adopted the preceding session's
  identity, sometimes wiping its own state. Detached periodic sweeps now retain the
  original invocation in a subshell instead of re-importing another session's exported
  metadata. Regression tests cover an invoker later in the sweep and a periodic sweep
  after `status --all`. The separate Codex daemon-to-terminal routing issue above remains open.
- **Codex session title missing from TTS (2026-10-08):** v5.8 resolves the last matching
  `thread_name` from Codex's local session index and caches it per session. Status and changed
  agent states detect index changes, so late titles/renames reach TTS without restarting.
  `SESSION_NAME` is shell-escaped on persistence, preserving spaces and literal shell syntax.
  Explicit TTS settings still win; missing data keeps the existing fallback order.

- **Remaining Codex `Hook failed` after the debounce fix (2026-10-06):** v5.4 detached the known
  debounce/refresh subprocesses, but a newly started Codex session still showed `Hook failed`.
  The integration still had three structural problems: its wrapper ignored Codex's documented
  stdin JSON context, every renderer failure/output was allowed to reach the hook runner, and full
  synchronous renderer passes had only a 2s outer budget (live `Finished` passes visibly crossed
  a timestamp boundary). v5.5 makes this advisory integration fail-open: the wrapper translates
  `session_id`/`cwd`/`transcript_path`, captures all output, traces non-zero exits, always returns
  success with no hook output, and uses an internal watchdog that ends before each outer deadline.
  The already-reviewed outer hook definitions remain byte-for-byte stable so Codex's persisted
  trust stays valid; calls stay synchronous and ordered unless the runtime is genuinely stuck.
  The installer also preserves replaced Codex cache roots as links to the live wrapper because
  active sessions freeze `PLUGIN_ROOT` and otherwise call a path removed by `codex plugin add`.
  Regression: `tests/test_codex_hook_wrapper.sh` covers context translation, output suppression,
  non-zero failure, diagnostics, and a hung runtime.
- **Codex `Hook failed` from the WaitingForUser debounce (2026-10-06):** Codex showed `Hook
  failed` in a normal session. Codex waits for EOF on a hook's stdout/stderr, not only for exit;
  the 2026-09-16 debounce subshells (and the periodic `refresh --all &`) inherited those pipes, so
  every Codex `PermissionRequest` hook stayed open for the full 8s debounce, blew its 2s deadline,
  and was killed together with the pending alert. `notify.log` for that session: 15/15 debounced
  bell/TTS alerts never fired nor logged a cancellation, while Claude sessions (which don't wait on
  the pipes) fired 9/9. Fix: all three background jobs run with `</dev/null >/dev/null 2>&1`.
  Regression: `tests/test_waiting_debounce.sh` scenario 4 pipes both streams into `cat` and fails
  if the hook holds them for 3s+ (it held them 4s, the full debounce, before the fix).
- **sound-bell/sound-tts alert on a WaitingForUser that auto-clears (2026-09-16):** The
  2026-09-03 `PostToolUse` fix below stops `WaitingForUser` from *lingering*, but it still
  applies and renders instantly - so every Codex `PermissionRequest`, auto-approved or not,
  rang the bell and spoke a TTS name. Live example: session `statusline-codex-patch` (render pid
  45462, `~/.codex/config.toml` `trust_level = "trusted"`) rang/spoke on four separate
  auto-approved requests inside four minutes. Mined `notify.log`'s prior ~3 days for the actual
  gap between `WaitingForUser` and the next differing state, split heuristically by agent
  (Codex: n=9, one session, min 6s/median 15s/p75 48s/max 510s; Claude: n=15, mixed sessions, 4 of
  15 also resolved within 1s, median 61s, long tail to 8285s) - confirms TODO.md's own
  "no payload-based signal exists" conclusion: duration alone can't cleanly separate a fast
  auto-approval from a genuine wait, and even Claude has some near-instant flicker. Fix, scoped to
  the two SOUND renderers only (not the core, not terminal-title/tmux-pane-bg, which must keep
  reflecting `WaitingForUser` immediately): `sound-bell`/`sound-tts` each hold a
  `WaitingForUser` render in a backgrounded, disowned subshell for a new `waiting_debounce_secs`
  setting (default 8s - clears the fastest/most common blips in both distributions above without
  meaningfully delaying a real alert), re-reading `state.env` straight off disk right before
  actually ringing/speaking; if anything else superseded it, they silently skip. `state.env`
  itself, and every other renderer, are unaffected - written and rendered exactly as before.
  Regression coverage: `tests/test_waiting_debounce.sh` (fast-clear never rings/speaks, a
  sustained wait still does, `waiting_debounce_secs=0` stays fully synchronous);
  `tests/test_renderer_settings.sh` sets `waiting_debounce_secs=0` explicitly so its own
  settings-merge assertions stay synchronous. Known residual gap: this is still a bounded time
  window, not a real signal - a slow-but-auto-approved Codex command past ~8s (up to the observed
  510s) still alerts.
- **Codex `WaitingForUser` lingering after an auto-approved permission request (2026-09-03):**
  Observed live on 2026-08-31/09-01 in session `01a05946-5ca0-7ba0-a8de-d845b9cba0cd` (render pid
  90597): `WaitingForUser` sat rendered for anywhere from seconds to minutes (worst case ~24 min)
  after `~/.codex/config.toml`'s `approvals_reviewer = "auto_review"` silently auto-resolved a
  `PermissionRequest`, because the only thing that ever cleared it was the *next*, unrelated
  `PreToolUse`. Not a same-tick flicker as first assumed from `notify.log`'s 1-second timestamp
  resolution — measured gaps in a captured hook-payload log showed real multi-minute lingers.
  Investigated by temporarily instrumenting `release/codex/notify` (2026-08-31) to log every hook's
  argv/env/stdin JSON; the captured `PermissionRequest` payloads (`hook_event_name`, `model`,
  `permission_mode` — always `"default"`, `tool_name`, `tool_input`) carry no decision/reviewer
  field, and the Codex transcript's `CommandExecution` entries don't either, so no payload-based
  signal exists. The actual fix: Codex's own hook schema (found via `strings` on the installed
  `codex` binary) defines a `PostToolUse` event ("After a tool executes") that `hooks.json` never
  wired up. Mapping `PostToolUse` → `event Working` in `release/codex/hooks/hooks.json` clears the
  state the instant the tool actually finishes, whether approval took 10ms or 5 minutes — no payload
  inspection or timing heuristic needed. Debug instrumentation removed; regression coverage is now a
  static assertion in `tests/test_manifests.sh` that `PostToolUse` maps to `event Working` (the
  opt-in runtime reproduction in `tests/test_known_issues.sh` was deleted as redundant with it, since
  the bug was never in `notify`'s state transitions themselves, only in `hooks.json`'s coverage).
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
