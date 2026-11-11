"""Structured JSONL logging with mandatory secret redaction (§SPEC-002).

Every field value passes through the Redactor before serialization, so the
JSONL file (live-probe evidence) and stderr can never carry the PAT or the
bot token even if an upstream error string embeds them.
"""

import json
import os
import sys
from datetime import datetime, timezone

from multica_telegram_notifier.redact import Redactor


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class JsonLogger:
    def __init__(self, redactor: Redactor, stream=None, file_path=None):
        self.redactor = redactor
        self.stream = stream if stream is not None else sys.stderr
        self._file = None
        if file_path:
            parent = os.path.dirname(file_path)
            if parent:
                os.makedirs(parent, exist_ok=True)
            self._file = open(file_path, "a", encoding="utf-8")

    def log(self, level: str, event: str, **fields) -> None:
        record = {"ts": utc_now_iso(), "level": level, "event": event}
        for key, value in fields.items():
            record[key] = self.redactor.redact_value(value)
        line = json.dumps(record, ensure_ascii=False, default=str)
        # Sanitize once before any sink: lone surrogates (possible in
        # upstream "\udXXX" escapes) cannot be UTF-8 encoded and would crash
        # the JSONL file write even after a successful delivery.
        line = line.encode("utf-8", errors="ignore").decode("utf-8")
        self._write_line(line)

    def debug(self, event: str, **fields) -> None:
        self.log("debug", event, **fields)

    def info(self, event: str, **fields) -> None:
        self.log("info", event, **fields)

    def warning(self, event: str, **fields) -> None:
        self.log("warning", event, **fields)

    def error(self, event: str, **fields) -> None:
        self.log("error", event, **fields)

    def _write_line(self, line: str) -> None:
        try:
            print(line, file=self.stream, flush=True)
        except (OSError, ValueError):
            pass
        if self._file is not None:
            try:
                self._file.write(line + "\n")
                self._file.flush()
            except OSError:
                pass

    def close(self) -> None:
        if self._file is not None:
            try:
                self._file.close()
            except OSError:
                pass
            self._file = None
