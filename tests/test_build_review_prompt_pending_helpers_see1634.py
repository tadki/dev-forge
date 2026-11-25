"""§SPEC-030 (SEE-1634 续轮): 探测 helper（_pending_counter_nth 等）修复点的行为钉。

Final Review 窄修复把期号探测拆成 _validated_pr_list / _pr_touches_counter /
_pending_counter_nth。Leader 抽查发现两处仓内测试缺口，本文件补上，并连带补两个
同族边界（自查发现）：

1. headRefOid 是非字符串真值（如整数 42）→ 必须 fail-closed。
   （既有用例只测「缺 headRefOid」= None；None 对「漏掉 isinstance 检查」的
   走样实现同样为假，区分不了。）
2. headRefOid 是空字符串 → 必须 fail-closed（不能拿空 ref 去 api 撞运气）。
3. base64 真实折行正例：载荷必须长到按 60 字符折行真的产生换行
   （既有正例只有 16 字符，折不进任何换行，「先去空白再严格解码」实际没测到）。
4. base64 中混入非字母表字符（截断/污染）→ 严格解码必须报错 fail-closed。

两个拼装器逻辑同构，逐一覆盖。全程只用桩 gh 与假数据。
"""
from __future__ import annotations

import base64
import importlib.util
import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]

BUILDERS = {
    "toolchain": REPO_ROOT / "autopilots/review-prompts/toolchain/build_review_prompt.py",
    "architecture": REPO_ROOT / "autopilots/review-prompts/architecture/build_review_prompt.py",
}

TOKEN_VARS = ("GITHUB_PERSONAL_ACCESS_TOKEN", "GH_TOKEN", "GITHUB_TOKEN")

SEED = json.dumps({"nth": 24})

# 可配置桩 gh：pr list 与 api 的 stdout 由环境变量注入（与 probe_edges 同款）。
GH_STUB = r"""#!/usr/bin/env bash
exec python3 - "$@" <<'PY'
import os, sys
args = sys.argv[1:]
if args[:2] == ["pr", "list"]:
    sys.stdout.write(os.environ.get("E_PR_LIST", "[]"))
    sys.exit(int(os.environ.get("E_PR_LIST_RC", "0")))
if args[:1] == ["api"]:
    sys.stdout.write(os.environ.get("E_API_RAW", "{}"))
    sys.exit(int(os.environ.get("E_API_RC", "0")))
sys.stderr.write("stub gh: unexpected args %r\n" % (args,))
sys.exit(2)
PY
"""


def _load(path: Path, name: str):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


@pytest.fixture(params=sorted(BUILDERS))
def builder(request):
    return request.param, _load(BUILDERS[request.param], f"brp_helpers_{request.param}")


def _run(builder_path: Path, tmp_path: Path, env_extra: dict) -> subprocess.CompletedProcess:
    bin_dir = tmp_path / "ghbin"
    if not bin_dir.exists():
        bin_dir.mkdir()
        gh = bin_dir / "gh"
        gh.write_text(GH_STUB, encoding="utf-8")
        gh.chmod(0o755)
    state = tmp_path / "state.json"
    if not state.exists():
        state.write_text(SEED, encoding="utf-8")
    out = tmp_path / "out.md"
    env = dict(os.environ)
    for var in TOKEN_VARS:
        env.pop(var, None)
    env["PATH"] = f"{bin_dir}:{env['PATH']}"
    env.setdefault("E_PR_LIST", "[]")
    env.setdefault("E_API_RAW", "{}")
    env.update(env_extra)
    return subprocess.run(
        [
            sys.executable, str(builder_path),
            "--repo-root", str(REPO_ROOT),
            "--date", "2026-11-25",
            "--state-file", str(state),
            "--output", str(out),
            "--daily-report-dir", str(tmp_path / "reports"),
            "--ledger-path", str(tmp_path / "ledger" / "2026-11.md"),
        ],
        cwd=str(REPO_ROOT), capture_output=True, text=True, timeout=60, env=env,
    )


def _counter_content(raw_b64: str) -> str:
    return json.dumps({"content": raw_b64})


def _b64_of(payload_bytes: bytes) -> str:
    return base64.b64encode(payload_bytes).decode()


def _pr_touching(counter_rel: str, **overrides) -> str:
    pr = {"number": 7, "headRefOid": "sha7", "files": [{"path": counter_rel}]}
    pr.update(overrides)
    return json.dumps([pr])


def _assert_fail_closed(builder_key, r, tmp_path):
    assert r.returncode == 4, r.stderr
    assert "Traceback" not in r.stderr
    state = tmp_path / "state.json"
    assert state.read_text(encoding="utf-8") == SEED
    assert not (tmp_path / "out.md").exists()


class TestHeadRefOidShape:
    def test_sha_non_string_truthy_fails_closed(self, builder, tmp_path):
        """headRefOid=42（非字符串真值）→ 不能当合法 sha 拿去调 api。"""
        _key, mod = builder
        r = _run(BUILDERS[_key], tmp_path, {
            "E_PR_LIST": _pr_touching(mod.COUNTER_REL, headRefOid=42),
            "E_API_RAW": _counter_content(_b64_of(b'{"nth": 30}')),
        })
        _assert_fail_closed(_key, r, tmp_path)

    def test_sha_empty_string_fails_closed(self, builder, tmp_path):
        """headRefOid="" → 空 ref 不得发 api；即便桩回有效载荷也必须 exit 4。"""
        _key, mod = builder
        r = _run(BUILDERS[_key], tmp_path, {
            "E_PR_LIST": _pr_touching(mod.COUNTER_REL, headRefOid=""),
            "E_API_RAW": _counter_content(_b64_of(b'{"nth": 30}')),
        })
        _assert_fail_closed(_key, r, tmp_path)


class TestStrictBase64Decode:
    def test_base64_folded_at_60_chars_still_derives(self, builder, tmp_path):
        """GitHub 真实折行形态：载荷足够长，60 字符折行真的产生换行，
        先去空白再解码后必须照常派生（不得因折行而 fail-closed）。"""
        _key, mod = builder
        payload = json.dumps({"nth": 30, "pad": "0123456789" * 5})
        assert len(payload) > 45, "载荷必须长到折行真的插入换行"
        raw = _b64_of(payload.encode())
        assert len(raw) > 60, "base64 必须超过 60 字符才会被折行"
        wrapped = "\n".join(raw[i:i + 60] for i in range(0, len(raw), 60))
        assert "\n" in wrapped
        r = _run(BUILDERS[_key], tmp_path, {
            "E_PR_LIST": _pr_touching(mod.COUNTER_REL, headRefOid="deadbeef"),
            "E_API_RAW": _counter_content(wrapped),
        })
        assert r.returncode == 0, r.stderr
        state = tmp_path / "state.json"
        assert json.loads(state.read_text(encoding="utf-8"))["nth"] == 31
        assert "第 31 期" in (tmp_path / "out.md").read_text(encoding="utf-8")

    def test_base64_interior_non_alphabet_char_fails_closed(self, builder, tmp_path):
        """content 中段混入非字母表字符（截断/污染）→ 严格解码必须报错。"""
        _key, mod = builder
        good = _b64_of(b'{"nth": 30}')
        assert len(good) >= 8
        poisoned = good[:8] + "!" + good[8:]
        r = _run(BUILDERS[_key], tmp_path, {
            "E_PR_LIST": _pr_touching(mod.COUNTER_REL, headRefOid="deadbeef"),
            "E_API_RAW": _counter_content(poisoned),
        })
        _assert_fail_closed(_key, r, tmp_path)
