"""SEE-1583 §SPEC-007 — dev-forge CI 消费面 gqt v0.3.0 守护（Harti hardener）。

判据面：`.github/workflows/*.yml` 不得出现旧一级调用形态（literal
`gqt <old>` / `$GQT <old>` / `python3 -m godot_qa_toolkit.cli <old>` /
多空白分隔 / 旧名大小写变体）；gqt 安装 pin 必须且只能是
`godot-qa-toolkit.git@v0.3.0`。

allowlist（不在扫描范围，非 active 消费面）：autopilots/review-prompts/
下的 dated 审计台账（2026-10.md / 2026-11.md 的旧 pin 与旧命令史述），
以及 push-guard「GQT canonical 检出」拓扑语义表述（scripts/ 与
test_push_guard_gqt_host_see1406.py）——均非 CLI 调用，零触碰。
"""

from __future__ import annotations

import re
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]

_OLD_NAMES = ("accept", "canonical", "canonical-diagnose", "attr-update",
              "recipe", "registry", "arch", "complexity", "coverage",
              "parity", "risk")
_PREFIXES = (r"\bgqt\s+",
             r"\$[Gg][Qq][Tt]\s+",
             r"\bpython3?\s+-m\s+godot_qa_toolkit\.cli\s+")
_NAME_RE = "(?i:" + "|".join(_OLD_NAMES) + ")"
OLD_INVOCATION = re.compile(
    "|".join(p + _NAME_RE + r"([^-a-z0-9]|$)" for p in _PREFIXES))
PIN_RE = re.compile(r'godot-qa-toolkit\.git@([^\s"\')]+)')
PIN_EXPECTED = "v0.3.0"


def _workflow_texts() -> list[tuple[Path, str]]:
    return [(p, p.read_text(encoding="utf-8"))
            for p in sorted(REPO.glob(".github/workflows/*.yml"))
            if p.is_file()]


def test_no_old_invocation_forms_in_workflows():
    bad = []
    for path, text in _workflow_texts():
        for lineno, line in enumerate(text.splitlines(), 1):
            if OLD_INVOCATION.search(line):
                bad.append(f"{path.relative_to(REPO)}:{lineno}: "
                           f"{line.strip()[:100]}")
    assert not bad, ("old gqt top-level invocation in CI workflows:\n"
                     + "\n".join(bad[:20]))


def test_install_pin_is_v030_only():
    hits: list[tuple[str, str]] = []
    pinned_v030 = False
    for path, text in _workflow_texts():
        for match in PIN_RE.finditer(text):
            ref = match.group(1)
            hits.append((str(path.relative_to(REPO)), ref))
            if ref == PIN_EXPECTED:
                pinned_v030 = True
    assert hits, "no godot-qa-toolkit install pin found (pin discipline)"
    wrong = [f"{p}: @{ref}" for p, ref in hits if ref != PIN_EXPECTED]
    assert not wrong, f"stale gqt install pin(s): {wrong}"
    assert pinned_v030, f"expected a @{PIN_EXPECTED} pin in the CI face"
