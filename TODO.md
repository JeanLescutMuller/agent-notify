# Claude Notify - TODO

## False "Finished" notifications during subagent dispatch

**Problem:** When Claude dispatches subagents (Agent tool), the main agent's turn ends and Claude Code fires the `Stop` hook. We transition to Finished, triggering TTS and bell. But 1 to 12 seconds later, a subagent returns, Claude resumes, and we go back to Working. This cycle repeats for each returning subagent, producing multiple false "Finished" notifications per turn.

Observed in session 44112769: 6 agents dispatched at 01:57:53, followed by 7 false Finished notifications over 8 minutes before the actual final Finished at 02:06:51.

**Root cause:** Claude Code's `Stop` hook means "the main agent stopped generating text", not "all work is complete." The hook payload has no field indicating pending subagents.

**Investigation findings:**
- Stop hook payload: no `pending_agents` or similar field
- Subagent directory (`<transcript>/subagents/`) exists with `.meta.json` per agent, but no completion status
- Subagent hooks fire with `/subagents/` in transcript_path (currently filtered out)
- Transcript JSONL contains Agent tool_use and tool_result entries that could be counted (dispatched vs. returned)
- Process tree shows child `claude` processes during subagent execution

**Proposed solutions (ranked by cleanliness):**

1. **Transcript parsing on Stop** - Count Agent tool_use IDs vs. tool_result IDs in the JSONL transcript. If dispatched > returned, subagents are pending, skip Finished transition. Deterministic and correct, but expensive to parse on every Stop and complex in bash.

2. **Grace period (Cooling state)** - On Stop, transition to "Cooling" instead of Finished. Visual renderers show green (user sees something finished). Sound renderers skip. A background `sleep 5` process checks: if still Cooling, promote to Finished and fire sounds. If activity resumed, do nothing. Practical, catches 90%+ of false positives (most subagent returns happen in 1 to 6 seconds). Tradeoff: 5 second delay on legitimate notifications.

3. **Subagent file age heuristic** - On Stop, check if any `subagents/*.jsonl` was modified within the last N seconds. If yes, subagents are likely still active. Simple but depends on file timestamps and a chosen threshold.

4. **Process tree check** - Count `claude` child processes under CLAUDE_PID on Stop. If > 1, subagents may be running. Unreliable (hard to distinguish subagents from MCP servers).

**Decision:** TBD. Waiting for Claude Code to potentially expose a `pending_tools` or `running_agents` field in the hook payload, which would make this trivial.

## notify_tts_async_say: nonce-based dedup (deferred, low priority)

**Idea:** Protect `notify_tts_async_say` against processing the same "say" event twice (e.g. if iTerm2/tmux ever redelivers a control sequence) by embedding a unique nonce in each event's payload and tracking recently-seen nonces on the listener side.

**Why deferred:** Requires changing the wire payload format emitted by `renderers.d/sound-tts/main`. Low priority - in practice, no duplicate speak events have ever been observed, so this is a theoretical protection, not an observed bug.

**How to apply:** Add a nonce field to the payload in `renderers.d/sound-tts/main`, and implement a bounded recent-nonce set in `notify_tts_async_say` to skip already-seen events.
 # Write unit test file
