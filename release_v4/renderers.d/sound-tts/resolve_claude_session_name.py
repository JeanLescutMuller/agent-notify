#!/usr/bin/env python3
"""resolve_claude_session_name.py - Fetch a Claude Code session's custom title.

Looks up the session's JSONL transcript by UUID alone (glob across every
~/.claude/projects/*/ dir - the UUID alone is unique, so there's no need to
reconstruct Claude Code's own cwd-to-project-key slugification), then returns
its most recent "custom-title" entry, if any. A custom title is a JSON line
Claude Code appends to the transcript: {"type":"custom-title","customTitle":
"...","sessionId":"...","source":"..."}.

Usage:
    resolve_claude_session_name.py <session-uuid>

Exit codes:
    0  Found a title (printed to stdout)
    1  No matching transcript, or no custom title in it (no stdout)

--- Problem ---

This runs once per CLAUDE_STATE_UPDATE (i.e. on every state change of a
possibly-long-running session), so it needs to be fast even when the
transcript is huge (a real transcript observed during development: 7MB /
~2900 lines; nothing stops one from growing to hundreds of MB over a long
session) AND even when the custom-title entry isn't near the end of the
file (a title is typically set once, early, then the session keeps going -
so by the time we look it up there can be many MB of unrelated conversation
after it). A naive top-to-bottom scan pays for the whole file on every
single lookup regardless of where the match is.

--- Solutions considered, and why this one won ---

Benchmarked against a synthetic 200MB JSONL (matching Claude Code's real,
compact - no spaces after ':'/',' - line format) with the custom-title line
placed in two positions: at EOF (best case) and ~96MB before EOF, i.e. ~96MB
of unrelated lines written after the title was set (realistic case).

    approach                                    | at EOF | 96MB deep
    ---------------------------------------------|--------|----------
    grep '"type":"custom-title"' file | tail -1  | 1.55s  | 1.52s
    tail -c 65536 (fixed-size, single shot)      | 0.02s  | MISS (wrong answer)
    tail -c $chunk, doubling until match (bash)  | 0.02s  | 7.8s
    backward chunked scan (this file, Python)    | 0.02s  | 0.16s
    naive top-to-bottom scan (Python)            | 0.65s  | 0.65s

- grep full-file / naive Python full scan: correct, but always pays for the
  entire file - the thing we're trying to avoid.
- fixed 64KB tail: fastest when it hits, but silently returns nothing if the
  title is further back than 64KB - not safe as a general solution, only
  works if you already know the title is always near the end (it isn't).
- growing-tail bash (tail -c $chunk, doubling the window and retrying):
  looked reasonable on paper, but was the worst performer in the realistic
  case - every retry re-reads the ENTIRE current window from EOF via a new
  `tail -c` process, so by the time the window has grown past ~96MB it has
  re-read overlapping data (in the same, growing chunk) something like a
  dozen times over, each retry spawning a new tail+grep pipeline.
- backward chunked scan (what this file does): reads fixed 64KB chunks
  walking from EOF towards the start, each chunk read exactly once, no
  overlap, stops the moment a match is found. Bash can't do this cleanly
  (no simple non-overlapping backward read primitive without `dd`
  block-arithmetic gymnastics), which is why this one piece is Python
  rather than folded into sound-tts/main directly - this project already
  ships one other Python component (notify_tts_async_say.py), so this isn't
  a new pattern.
"""
import sys
import os
import glob
import json

CHUNK_SIZE = 65536


def find_transcript(session_uuid):
    home = os.path.expanduser("~")
    matches = glob.glob(os.path.join(home, ".claude", "projects", "*", f"{session_uuid}.jsonl"))
    return matches[0] if matches else None


def find_last_custom_title(path, chunk_size=CHUNK_SIZE):
    with open(path, "rb") as f:
        f.seek(0, 2)
        pos = f.tell()
        carry = b""
        while pos > 0:
            read_size = min(chunk_size, pos)
            pos -= read_size
            f.seek(pos)
            buf = f.read(read_size) + carry
            lines = buf.split(b"\n")
            carry = lines[0]  # possibly-incomplete line, prepend to next chunk
            for line in reversed(lines[1:]):
                line = line.strip()
                if not line or b'"type":"custom-title"' not in line:
                    continue
                try:
                    entry = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if entry.get("type") == "custom-title":
                    return entry.get("customTitle")
        return None


def main():
    if len(sys.argv) != 2 or not sys.argv[1]:
        print("Usage: resolve_claude_session_name.py <session-uuid>", file=sys.stderr)
        sys.exit(1)

    transcript = find_transcript(sys.argv[1])
    if not transcript:
        sys.exit(1)

    title = find_last_custom_title(transcript)
    if not title:
        sys.exit(1)

    print(title)


if __name__ == "__main__":
    main()
