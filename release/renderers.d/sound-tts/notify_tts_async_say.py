#!/usr/bin/env python3
"""iTerm2 AutoLaunch script.

Listens for `Custom=id=tts:<payload>` control sequences (sent by notify's
renderers.d/sound-tts, unmodified) across every session in this
iTerm2 instance, and speaks each payload via macOS `say`, one at a time, in
FIFO arrival order. Not-yet-spoken duplicates for the same payload are
collapsed so a burst of repeats doesn't say the same thing twice.

Payload format: "[[volm <0-1>]] <name>", e.g. "[[volm 0.7]] Notify Dev".
`[[volm ...]]` is Apple's own embedded speech-synthesis command syntax
(https://developer.apple.com/documentation/AppKit/nsspeechsynthesizer) -
`say` interprets it natively, so the payload is passed straight through
with no volume-handling logic needed here.

The voice is chosen deterministically from a hash of the name, so the same
session always sounds the same across every announcement. The name is
reduced to a stable key first: the "[[volm ...]]" tag is stripped, "_" is
replaced with " ", the result is lowercased, non-alphanumeric characters
are dropped, and only the first word is kept - so "[[volm 0.5]] Notify!
DEV" and "[[volm 1.0]] Notify tests" both key on "notify" and get the same
voice. Uses hashlib rather than Python's builtin hash() - the latter is
randomized per-process (hash randomization), which would pick a different
voice for the same name every time this listener restarts.

Deploy: copy to
  ~/Library/Application Support/iTerm2/Scripts/AutoLaunch/notify_tts_async_say.py
Requires iTerm2 Preferences > General > Magic > Enable Python API.

Test the 'say' pipeline alone, without iTerm2 running this as AutoLaunch:
  python3 notify_tts_async_say.py --test "[[volm 0.7]] hello from the backlog"
"""

import asyncio
import datetime
import hashlib
import os
import re
import sys

try:
    import iterm2
except ImportError:
    iterm2 = None

IDENTITY = "tts"
PAYLOAD_REGEX = r"^(.*)$"
SAY_CMD = "say"
LOG_DIR = os.path.expanduser("~/Library/Application Support/iTerm2/Scripts/AutoLaunch")
LOG_FILE = os.path.join(LOG_DIR, "notify_tts_async_say.log")

VOICES = ["Samantha", "Daniel", "Karen", "Moira", "Rishi", "Tessa"]
VOLM_TAG_RE = re.compile(r"^\[\[volm[^\]]*\]\]\s*")
NON_KEY_CHARS_RE = re.compile(r"[^a-z0-9 ]")


def log(event, **fields):
    os.makedirs(LOG_DIR, exist_ok=True)
    ts = datetime.datetime.now().strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3]
    extra = " ".join(f"{k}={v!r}" for k, v in fields.items())
    with open(LOG_FILE, "a") as f:
        f.write(f"{ts} [{event}] {extra}\n")


def voice_key(payload):
    """Reduce a raw payload to the stable string the voice is hashed from."""
    text = VOLM_TAG_RE.sub("", payload).strip()
    text = text.replace("_", " ").lower()
    text = NON_KEY_CHARS_RE.sub("", text)
    words = text.split()
    return words[0] if words else ""


def voice_for(payload):
    key = voice_key(payload)
    digest = hashlib.sha256(key.encode("utf-8")).hexdigest()
    return VOICES[int(digest, 16) % len(VOICES)]


class Backlog:
    """FIFO queue of payloads to speak. A payload already queued (not yet
    popped for speaking) is not queued again - the newer event replaces it."""

    def __init__(self):
        self._order = asyncio.Queue()
        self._pending = set()

    async def put(self, payload):
        if payload in self._pending:
            log("collapsed", payload=payload)
            return
        self._pending.add(payload)
        await self._order.put(payload)
        log("queued", payload=payload, depth=self._order.qsize())

    async def get(self):
        payload = await self._order.get()
        self._pending.discard(payload)
        return payload


async def run_say(payload):
    voice = voice_for(payload)
    proc = await asyncio.create_subprocess_exec(SAY_CMD, "-v", voice, payload)
    await proc.wait()
    return proc.returncode, voice


async def speaker_loop(backlog):
    while True:
        payload = await backlog.get()
        log("speak-start", payload=payload)
        try:
            rc, voice = await run_say(payload)
            if rc == 0:
                log("speak-end", payload=payload, voice=voice)
            else:
                log("error", payload=payload, reason=f"say exited {rc}")
        except Exception as exc:
            log("error", payload=payload, reason=str(exc))


async def main(connection):
    log("listener-start")
    backlog = Backlog()
    asyncio.ensure_future(speaker_loop(backlog))

    async with iterm2.CustomControlSequenceMonitor(
        connection, IDENTITY, PAYLOAD_REGEX
    ) as mon:
        log("listener-ready")
        while True:
            match = await mon.async_get()
            payload = match.group(1)
            log("received", payload=payload)
            await backlog.put(payload)


async def test_say(payload):
    log("speak-start", payload=payload, source="--test")
    rc, voice = await run_say(payload)
    if rc == 0:
        log("speak-end", payload=payload, voice=voice, source="--test")
    else:
        log("error", payload=payload, source="--test", reason=f"say exited {rc}")


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--test":
        test_payload = sys.argv[2] if len(sys.argv) > 2 else "notify tts async say test"
        asyncio.run(test_say(test_payload))
    elif iterm2 is None:
        sys.exit(
            "iterm2 package not found. Run this with iTerm2's bundled python3 "
            "(see the AutoLaunch deployment note at the top of this file), "
            "or use --test to check the 'say' pipeline without it."
        )
    else:
        iterm2.run_forever(main)
