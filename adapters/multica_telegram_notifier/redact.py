"""Secret redaction for logs and error text (§SPEC-002).

The redactor is the last line of defense: the Telegram client already avoids
embedding the bot token in errors, and every log field passes through here so
a PAT or token that leaks into any string still cannot reach a log file.
"""

from typing import Any

# Secrets shorter than this would redact unrelated substrings (e.g. "abc"
# inside ordinary words) and mangle log text, so they are skipped by design.
MIN_REDACT_LEN = 8

PLACEHOLDER = "[REDACTED]"


class Redactor:
    def __init__(self, secrets):
        self._secrets = [s for s in secrets if isinstance(s, str) and len(s) >= MIN_REDACT_LEN]

    def redact(self, text: Any) -> Any:
        if not isinstance(text, str):
            return text
        for secret in self._secrets:
            text = text.replace(secret, PLACEHOLDER)
        return text

    def redact_value(self, value: Any) -> Any:
        if isinstance(value, str):
            return self.redact(value)
        if isinstance(value, dict):
            return {k: self.redact_value(v) for k, v in value.items()}
        if isinstance(value, (list, tuple)):
            return [self.redact_value(v) for v in value]
        return value
