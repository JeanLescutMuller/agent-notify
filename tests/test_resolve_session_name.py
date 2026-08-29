#!/usr/bin/env python3

import importlib.util
import json
import pathlib
import tempfile
import unittest


PROJECT_ROOT = pathlib.Path(__file__).resolve().parents[1]
MODULE_PATH = PROJECT_ROOT / "release/adapters.d/claude/resolve_session_name.py"
SPEC = importlib.util.spec_from_file_location("resolve_session_name", MODULE_PATH)
RESOLVER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RESOLVER)


class FindLastCustomTitleTest(unittest.TestCase):
    def write_transcript(self, l_entries):
        transcript = tempfile.NamedTemporaryFile(mode="w", delete=False)
        self.addCleanup(pathlib.Path(transcript.name).unlink, missing_ok=True)
        with transcript:
            for d_entry in l_entries:
                transcript.write(json.dumps(d_entry, separators=(",", ":")) + "\n")
        return transcript.name

    def test_finds_title_on_first_line(self):
        path = self.write_transcript(
            [
                {"type": "custom-title", "customTitle": "First title"},
                {"type": "user", "message": "later"},
            ]
        )
        self.assertEqual(RESOLVER.find_last_custom_title(path), "First title")

    def test_returns_most_recent_title_across_small_chunks(self):
        path = self.write_transcript(
            [
                {"type": "custom-title", "customTitle": "Old title"},
                {"type": "user", "message": "x" * 100},
                {"type": "custom-title", "customTitle": "New title"},
                {"type": "user", "message": "y" * 100},
            ]
        )
        self.assertEqual(
            RESOLVER.find_last_custom_title(path, chunk_size=32),
            "New title",
        )

    def test_returns_none_without_title(self):
        path = self.write_transcript([{"type": "user", "message": "hello"}])
        self.assertIsNone(RESOLVER.find_last_custom_title(path))


if __name__ == "__main__":
    unittest.main()
