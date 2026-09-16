# Test map

End-to-end scenarios in `tests/`, not a unit-test decomposition of every branch. Each item below
is one test *scenario* — a realistic sequence of calls against `release/notify` (or `install.sh`)
that bundles several related assertions along the way, the same shape `test_framework.sh`'s
original `test_lifecycle`/`test_popup_targeting`/`test_refresh_all_isolation`/`test_renderers`
already used. All 16 scenarios below are implemented; this file stays as the map explaining what
each one covers and why, for whoever touches these tests next.

## Why scenarios, not unit tests

Nearly everything in this project is a shell script whose real risk is at the *boundaries*
(adapter → framework, framework → renderer, hook → state file, install → runtime) — see
`TESTING.md`'s own boundary table. Branch-by-branch unit tests of e.g. every `jq` fallback inside
`resolve_renderer_settings` would multiply into hundreds of near-duplicate tests without proving
the boundaries actually work together. A handful of realistic scenarios, each exercising a full
path end to end, catches the same regressions with far less code to maintain — and matches how
`TESTING.md`'s live checks (T1–T5) are already framed: as scenarios, not as branch coverage.

Shared helpers live in `tests/lib/test_helpers.sh` (`PROJECT_DIR`/`NOTIFY`, `pass`/`fail`, and the
`assert_*`/`count_log_occurrences` grep wrappers) and are sourced by every `tests/test_*.sh` file
except `test_resolve_session_name.py`. Fake `tmux`/`claude`/`codex` binaries are written inline
per test file rather than through a shared generator, since each one's canned responses are
scenario-specific enough that a shared abstraction wasn't worth it.

Tags: **[done]** implemented and passing. **[fixture]** scripted against a hand-built `.jsonl`
transcript standing in for a real Claude session — this is what makes T1–T3/T5 automatable at all.
**[stub]** needs a fake `tmux`/`claude`/`codex` binary on `PATH`. **[opt-in]** documents a
currently-accepted bug or risk from `TODO.md`; kept out of the default pass/fail suite since it's
inherently racy or intentionally-not-fixed, gated behind `RUN_KNOWN_ISSUES=1`.

---

## Core framework scenarios (`tests/test_framework.sh`)

### 1. [done] Full adapter lifecycle + renderer dispatch — `test_lifecycle`

Per adapter (generic/codex/claude): session-start → Working → WaitingForUser (with an OnHold
detour + idempotent re-selection) → Finished → Idle → session-end, asserting state file contents
and that all four renderers get dispatched on each agent-state change. Extended with two more
steps in the same walk: an automatic-style `USER_STATE=Seen` request while disk state is
`Acknowledged` does not downgrade it even via a deliberate `update` call (the "never downgrade
acknowledged to seen" guard has no `force` exception, unlike the `OnHold` guard right below it in
`update_state_and_render` — locked down as current behavior, not a claim it's the intended design);
and `notify update CLAUDE_STATE ...` (v4 compat alias) behaves identically to `AGENT_STATE`.

### 2. [done] tmux popup targeting + idempotency — `test_popup_targeting`

Direct pane-PID targeting, no state created for a plain shell pane, idempotent re-selection.
Extended to assert every `run-shell "..."`/`run-shell '...'` invocation in `tmux-hooks.conf` (not
just the 3 popup-menu state actions) uses the absolute `$HOME/.local/bin/notify` path — compares
the count of `run-shell [quote]` lines against the count that also contain the absolute path,
so it doesn't hardcode how many such lines the file has.

### 3. [done] `refresh --all` session isolation — `test_refresh_all_isolation`

Two sessions refreshed together must not leak adapter/transcript metadata into each other.
Extended to also assert `AGENT_PID` and `SESSION_NAME` stay isolated, not just
`AGENT_TYPE`/`TRANSCRIPT_PATH`.

### 4. [done] All-renderer output — `test_renderers` + `test_renderer_disabled_is_skipped`

Direct renderer invocation with a hand-built `RENDERER_SETTINGS` — BEL byte, iTerm2 TTS sequence,
aggregated title, both tmux pane-style options. Extended with the "default" reset behavior
(`tmux-pane-bg` unsetting styles via `set-option -u` rather than setting a literal `bg=default`)
in the same function, plus a new `test_renderer_disabled_is_skipped` scenario proving a
session-disabled renderer is skipped by the core dispatcher (`call_all_renderers`) — exercised
through `notify event`, not by calling the renderer's own `main` directly, since the skip decision
belongs to the core, not the renderer.

---

## New scenarios

### 5. [fixture, done] Subagent completion (T1 shape) — `tests/test_subagent_tracking.sh`

One fixture transcript with a dispatched `agentId` and no completion entry yet → `Finished` is
suppressed, `pending_finish` marker created. Append a completion entry to the same fixture and
fire the next hook event (a plain `event Idle`) → marker resolves reactively, `Finished` renders
first, then the new `Idle` request still applies — locking down the currently-undecided ordering
from `TODO.md`'s "Decide how new activity supersedes a pending finish" as today's actual behavior,
not a claim it's correct. Automates `TESTING.md`'s T1 without a live Claude session.

### 6. [fixture, done] Parallel subagents (T2 shape)

Three dispatched `agentId`s in one fixture, completion entries added one at a time across three
successive `refresh` calls → assert no `Finished` fires until the *last* one clears (checked via
`assert_log_not_contains "pending_finish resolved"` after each partial completion), and exactly
one resolution happens overall. Automates T2.

### 7. [fixture, done] Silent background completion (T3 shape)

Dispatched work with the parent's `Stop` firing before any completion entry, then completion
appears with **no further hook event** for that session — only a `refresh` call (standing in for
the debounced background refresh). Asserts `Finished` still resolves purely from that proactive
path (`cmd_refresh`'s own `try_resolve_pending_finish` call). Automates T3's "parent goes idle"
resolution path.

### 8. [fixture, done] Orphaned subagent (T5 shape)

A fixture that never gains a completion entry. Runs several `refresh`es and asserts
`pending_finish` is still present and no `Finished` ever fires — this is *documented, accepted*
behavior (an orphan is supposed to stay pending forever, per `TODO.md`), not a bug to assert away.
Deterministic (nothing about it is racy), so it runs in the default suite rather than the opt-in
`test_known_issues.sh` file — a good tripwire if pending-finish ever grows a timeout later.

### 9. [stub, done] tmux focus switching — `tests/test_tmux_focus.sh`

Four panes in one stub tmux session: `user-focus` fired for a switch to pane `%1` gives it
`Acknowledged`, an already-`Acknowledged` pane `%2` and an `OnHold` pane `%3` both stay put despite
the automatic (non-`force`) path touching them, and a plain shell pane `%4` with no session dir is
never given one. A second scenario in the same file confirms an empty `$TMUX_PANE` is a pure no-op
(byte-identical state files before/after).

### 10. [done] Renderer settings precedence — `tests/test_renderer_settings.sh`

Real three-file merge (default `settings.json` → global override under `$NOTIFY_CONFIG_DIR` →
session override), verified through `notify <renderer> key=value [--global]` and `notify
status`/`notify event` rather than a hand-built `RENDERER_SETTINGS` var — the one gap scenario 4
leaves, since that one bypasses `resolve_renderer_settings` entirely. A second scenario in the same
file: session-scoped `enabled=false` overriding a default-enabled renderer, confirmed both in
`notify status`'s label and in actual dispatch (the concrete case behind CLAUDE.md's `has()` vs
`//` warning, since the shipped default `settings.json` has no `enabled` key at all).

### 11. [done] `notify init` managed tmux block lifecycle — `tests/test_notify_init.sh`

One sequential scenario against a scratch copy of `release/` (so the real `tmux-hooks.conf` is
never edited) and a throwaway `$HOME`: `CLAUDE-NOTIFY` → `AGENT-NOTIFY` label migration with no
rewrite → fresh deploy onto a file with unrelated existing content (which *does* back that content
up, since the backup is keyed on "does the target file exist," not "does it already have a block"
— a real subtlety this scenario caught) → idempotent redeploy (byte-identical, no new backup) → a
real content change producing exactly one new backup (backup filenames are only
second-granularity, so the test sleeps 1s first to avoid a same-second filename collision with the
prior backup) → a hand-edited block being refused with a diff on stderr, left completely untouched.

### 12. [done] Install + migration — `tests/test_install.sh`

Automates the "complete migration test" `TESTING.md` used to flag as missing, as two scenarios:
`test_install_idempotency` (fresh install → symlink + executable `app/notify`, `template/`
staying non-executable → a hand-edited global settings file and a stray leftover app-file both
survive/get-cleaned-up correctly across a second install) and `test_install_migration` (an old
plugin-shaped settings file that differs from the shipped default is migrated into
`config/renderers.d/` and logged; one identical to the default is not migrated; a second install
never re-migrates or clobbers an already-present config file even if the old source changes).
Along the way this uncovered a real bug: `install.sh`'s `cleanup` EXIT trap returned non-zero on
the normal success path (`stage_dir=""` makes `[ -n "$stage_dir" ]` false, and bash's EXIT trap
status becomes the script's own exit code), so `install.sh` always exited 1 even on success —
fixed with an explicit `return 0` at the end of `cleanup()`.

### 13. [stub, done] Claude/Codex plugin registration — `test_plugin_registration`

Fake `claude`/`codex` binaries (in the same file) record every invocation and track minimal state
(has the marketplace been added? has the plugin been installed?) so repeated `list` calls behave
like the real CLIs would. Two installs assert: the marketplace manifest ends up with exactly one
`notify` entry both times (no duplication); Claude's own registration is idempotent (`plugin
marketplace add`/`plugin install` each called exactly once across both installs, since it checks
`list` first); and — a real asymmetry this scenario caught — Codex's `plugin add` has no such
guard in `install.sh` and is invoked again on *every* install, locked down as current behavior
rather than "fixed" silently by the test.

### 14. [done] Plugin manifest shape — `tests/test_manifests.sh`

Pure `jq`/grep assertions, no runtime: every Claude hook command starts with
`${CLAUDE_PLUGIN_ROOT}/notify`, every timeout stays within 1–3s, and the `AskUserQuestion`-specific
`PreToolUse` matcher plus the catch-all matcher-less one are both still present — the known
T4/TODO overlap, asserted as a tripwire for either direction of drift, not a claim it's correct.
Plus: the Codex plugin manifest is valid with the `+codex.<timestamp>` version suffix, and every
Codex hook command carries `NOTIFY_AGENT_TYPE=codex`, stays within 1–3s, and has hook-event coverage
matching `TESTING.md`'s mapping table exactly — including that `PostToolUse` specifically maps to
`event Working`, per `TODO.md`'s resolved "Distinguish auto-approved Codex permission requests from
real waits": that's what clears a `WaitingForUser` the instant an auto-approved tool actually
finishes, instead of leaving it rendered until some later unrelated `PreToolUse` (observed lingering
for minutes in production on 2026-08-31/09-01). This manifest assertion is the only thing that would
catch someone silently rewiring or dropping that hook — no runtime scenario exercises `hooks.json`
itself, only the `notify event` calls it fires (already covered generically by scenario 1's
Working→WaitingForUser→Finished walk).

### 15. [opt-in, done] Concurrent state-update race — `tests/test_known_issues.sh`

25 bursts of 12 truly concurrent `notify update AGENT_STATE Working|Finished` calls against the
same render PID, checking `state.env` for structural corruption (wrong line count, duplicate
`AGENT_STATE=`/`USER_STATE=` keys) after each burst — the actual observable symptom of two
processes' separate `>`/`>>` write sequences interleaving, per `TODO.md`'s "Serialize overlapping
state updates". Reproducing a real race black-box (without instrumenting the script to force an
exact interleaving) is inherently probabilistic, so this scenario never fails the suite by itself —
it prints whether it reproduced the race this run and always passes structurally. Skipped by
default; run explicitly with `RUN_KNOWN_ISSUES=1`.

### 16. [opt-in, done] Trust-boundary tripwire

A working-directory value containing a literal `$(touch marker)` payload, passed through
`NOTIFY_AGENT_WD`, written verbatim into `static.env`, and only executed once something re-sources
that file (`notify status`) — proving the accepted risk in CLAUDE.md/TODO.md ("Runtime `.env`
files are sourced as shell") is still exactly as documented. Deterministic, not flaky; grouped into
the opt-in file alongside scenario 15 because both document accepted risk rather than assert
correctness, not because this one is racy.

---

## File layout

- `tests/lib/test_helpers.sh` — shared `pass`/`fail`/`assert_*`/`count_log_occurrences` helpers,
  sourced by every file below.
- `tests/test_framework.sh` — scenarios 1–4.
- `tests/test_subagent_tracking.sh` — scenarios 5–8, fixture transcripts built inline per test
  (not pre-committed files — each scenario needs a different dispatch/completion sequence).
- `tests/test_tmux_focus.sh` — scenario 9.
- `tests/test_renderer_settings.sh` — scenario 10.
- `tests/test_notify_init.sh` — scenario 11.
- `tests/test_install.sh` — scenarios 12–13.
- `tests/test_manifests.sh` — scenario 14 (pure static checks, fastest file in the suite, no
  temp-dir setup at all).
- `tests/test_known_issues.sh` (`RUN_KNOWN_ISSUES=1`) — scenarios 15–16.

That's 9 files (8 scenario files + the shared helper), 16 scenarios — up from the original 1 file
/ 4 scenarios, still small enough to read end to end in one sitting. Run the whole suite with
`for t in tests/test_*.sh; do "$t"; done` (see `TESTING.md`); `tests/test_resolve_session_name.py`
runs separately via `python3 -m unittest discover -s tests`.
