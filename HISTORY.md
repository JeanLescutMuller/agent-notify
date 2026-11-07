# agent-notify: resolved issues

What was fixed, why, and how it is tested; cited by code comments and tests. Open work moved to Todoist on 2026-10-14 (tasks with `Repo: agent-notify`, skill `task-management`).

## Resolved history

- **Copies of facts others already give (v5.15, 2026-11-07, agent-tracker v1):** `static.env` held 11 fields per shell; 8 were copies of what tmux, the hook's own input or agent-tracker's `last_seen.json` give when they are read, and one copy (`SESSION_TMUX_SESSION`) had already gone stale after a `tmux rename-session` (2026-08-18). v5.15 keeps `AGENT_TYPE`, `AGENT_SESSION_ID` and `SESSION_NAME` and derives the rest in `derive_session_context` (one `tmux list-panes -a` per render; one `jq` on `last_seen.json` only when agent-tracker wrote one). agent-notify does not depend on agent-tracker: tmux by shell PID gives the pane, so colors are set without it. Field table: INTEGRATIONS.md, "Session fields: stored or derived". Tested by `tests/test_derived_context.sh` and `test_refresh_all_isolation`.

- **`notify.log` never trimmed (v5.13-v5.14, 2026-11-03):** the shared log grew to 86 MB / 1.2 M
  lines in 18 days (first line 2026-10-16, ~5 MB/day). `trim_log` runs at the start of the
  detached debounced refresh (at most every 300 s while agents run, never on a hook's critical
  path; no separate job): over `NOTIFY_LOG_MAX_BYTES` (default 100 MB, the user's choice) it
  renames the log to `notify.log.1`, replacing the previous one. v5.13 instead copied the newest
  half, which took 2.4 s on a 106 MB file; the user asked for the leanest step and did not mind
  ±100 MB, so v5.14 renames (no copy; disk stays under ~200 MB). The check under the cap is one
  `stat` (~13 ms, measured). Tested by `tests/test_log_cap.sh`, including the real default on a
  106 MB file.

- **Subagent completion tracking (v5.12, 2026-11-03):** Claude's `Stop` fires when the parent's
  turn ends, even while subagents it dispatched still run (the Agent tool now runs in the
  background by default). v5.0-v5.11 detected that by scanning the parent transcript's tail for
  `agentId:` lines without a matching `enqueue … <task-id>` entry, kept a `pending_finish` marker,
  and shortened the background refresh to 15 s to resolve it. A probe on Claude Code 2.1.317
  (45 hook calls, 4 runs) showed every hook gets stdin JSON and `Stop` carries `background_tasks`
  (`id`, `type` subagent|shell, `status`); when a subagent ends, Claude always wakes the parent
  (UserPromptSubmit, then a second Stop with the list emptied). v5.12 defers Finished while a
  `subagent` entry is `running` and stores nothing; the marker, the transcript scan, the
  transcript-path lookup and the 15 s refresh are gone. Background shells (`type: shell`, e.g. a
  dev server) never defer. This also closed two open questions: a stale Finished rendered before
  new activity (no marker any more) and orphaned subagents keeping a marker forever (a hung one
  now stays Working until Claude's `idle_prompt` sets Idle). Not measured: whether a killed or
  failed subagent wakes the parent (if not, `idle_prompt` still moves the pane to Idle). Claude Code passes hook stdin on a Unix socket, not a pipe: a first draft that
  read only pipes passed every fixture test yet missed the live T3 payload; the adapter now reads
  any non-terminal stdin, and a socket test guards it. Tested by `tests/test_subagent_tracking.sh`
  (17 scenarios) and live T1-T3 on 2.1.317 (2026-11-03, haiku, ~$0.05): T3 logged `Finished
  deferred`, then one Finished from the wake-up turn; T1/T2 one Finished each.

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
