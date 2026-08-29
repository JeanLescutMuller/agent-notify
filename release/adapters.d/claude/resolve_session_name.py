#!/usr/bin/env python3
"""Return a Claude Code session's most recent custom title.

The transcript is located by session UUID, then scanned backwards in fixed-size
chunks. This avoids repeatedly reading an entire long-running transcript while
still finding titles written near its beginning.

Usage:
    resolve_session_name.py <session-uuid>

Exit codes:
    0  Found a title and printed it.
    1  No transcript or custom title was found.
"""

import glob
import json
import os
import sys


CHUNK_SIZE = 65536


def find_transcript(session_uuid):
    pattern = os.path.join(
        os.path.expanduser("~"),
        ".claude",
        "projects",
        "*",
        f"{session_uuid}.jsonl",
    )
    l_matches = glob.glob(pattern)
    return l_matches[0] if l_matches else None


def find_last_custom_title(path, chunk_size=CHUNK_SIZE):
    with open(path, "rb") as transcript:
        transcript.seek(0, 2)
        position = transcript.tell()
        carry = b""

        while position > 0:
            read_size = min(chunk_size, position)
            position -= read_size
            transcript.seek(position)
            buffer = transcript.read(read_size) + carry
            l_lines = buffer.split(b"\n")

            # Before reaching byte zero, the first item may be only the tail of
            # a line. Carry it into the next chunk. At byte zero it is a real
            # first line and must be searched too.
            if position > 0:
                carry = l_lines[0]
                l_lines = l_lines[1:]

            for line in reversed(l_lines):
                line = line.strip()
                if not line or b'"type":"custom-title"' not in line:
                    continue
                try:
                    d_entry = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if d_entry.get("type") == "custom-title":
                    return d_entry.get("customTitle")

        return None


def main():
    if len(sys.argv) != 2 or not sys.argv[1]:
        print("Usage: resolve_session_name.py <session-uuid>", file=sys.stderr)
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
