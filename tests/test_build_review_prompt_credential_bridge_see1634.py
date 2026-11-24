"""§SPEC-030 (SEE-1634): 两个拼装器的 gh 凭据桥接行为。

运行时把 PAT 暴露为 GITHUB_PERSONAL_ACCESS_TOKEN，而 gh 只认 GH_TOKEN/GITHUB_TOKEN。
拼装器在探测未合入 PR 期号时调用 gh，必须把 PAT 桥接成 gh 能识别的令牌。四条语义：

1. GH_TOKEN、GITHUB_TOKEN 都没设且有 PAT 时，桥接为 GH_TOKEN；
2. 已有 GH_TOKEN 时不覆盖；
3. 已有 GITHUB_TOKEN 而没 GH_TOKEN 时不桥接（gh 已能读到 GITHUB_TOKEN）；
4. 没有 PAT 时不凭空造出令牌。

本文件对工具链与架构两个拼装器逐一覆盖上述四条，并用桩 gh 端到端证明桥接后的令牌
确实进入了 gh 子进程的环境（而非只是算出来丢弃）。全程只用假令牌。
"""
from __future__ import annotations

import importlib.util
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

FAKE_PAT = "fake-pat-see1634-do-not-use"
FAKE_GH_TOKEN = "fake-ghtoken-see1634"
FAKE_GITHUB_TOKEN = "fake-githubtoken-see1634"

# 桩 gh：只处理 `pr list`（回空表，让探测成功）；把子进程实际看到的
# GH_TOKEN / GITHUB_TOKEN 写进 SEE1634_TOKEN_SINK，用于端到端证明桥接生效。
GH_STUB = r"""#!/usr/bin/env bash
exec python3 - "$@" <<'PY'
import os, sys
args = sys.argv[1:]
sink = os.environ.get("SEE1634_TOKEN_SINK")
if sink:
    with open(sink, "w", encoding="utf-8") as fh:
        fh.write("GH_TOKEN=%s\n" % os.environ.get("GH_TOKEN", "<UNSET>"))
        fh.write("GITHUB_TOKEN=%s\n" % os.environ.get("GITHUB_TOKEN", "<UNSET>"))
if args[:2] == ["pr", "list"]:
    sys.stdout.write("[]")
else:
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
    return request.param, _load(BUILDERS[request.param], f"brp_creds_{request.param}")


def _clear_tokens(monkeypatch):
    for var in TOKEN_VARS:
        monkeypatch.delenv(var, raising=False)


def _run_builder_with_tokens(tmp_path: Path, builder_path: Path, token_env: dict) -> tuple:
    """用受控令牌环境跑一次拼装器（不强制期号，令其真实走 gh 探测）。

    Returns (CompletedProcess, sink_text_or_None).
    """
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    gh = bin_dir / "gh"
    gh.write_text(GH_STUB, encoding="utf-8")
    gh.chmod(0o755)
    sink = tmp_path / "token-sink.txt"

    env = dict(os.environ)
    for var in TOKEN_VARS:
        env.pop(var, None)
    env["PATH"] = f"{bin_dir}:{env['PATH']}"
    env["SEE1634_TOKEN_SINK"] = str(sink)
    env.update(token_env)

    args = [
        "--repo-root", str(REPO_ROOT),
        "--date", "2026-11-25",
        "--state-file", str(tmp_path / "state.json"),
        "--daily-report-dir", str(tmp_path / "reports"),
        "--ledger-path", str(tmp_path / "ledger" / "2026-11.md"),
    ]
    r = subprocess.run(
        [sys.executable, str(builder_path), *args],
        cwd=str(REPO_ROOT), capture_output=True, text=True, timeout=60, env=env,
    )
    text = sink.read_text(encoding="utf-8") if sink.exists() else None
    return r, text


class TestGhEnvBridgeSemantics:
    """四条语义，直接对 _gh_env() 的映射结果断言（两个拼装器各跑一遍）。"""

    def test_pat_bridged_to_gh_token_when_both_unset(self, builder, monkeypatch):
        _key, mod = builder
        _clear_tokens(monkeypatch)
        monkeypatch.setenv("GITHUB_PERSONAL_ACCESS_TOKEN", FAKE_PAT)
        assert mod._gh_env()["GH_TOKEN"] == FAKE_PAT

    def test_existing_gh_token_not_overwritten(self, builder, monkeypatch):
        _key, mod = builder
        _clear_tokens(monkeypatch)
        monkeypatch.setenv("GITHUB_PERSONAL_ACCESS_TOKEN", FAKE_PAT)
        monkeypatch.setenv("GH_TOKEN", FAKE_GH_TOKEN)
        assert mod._gh_env()["GH_TOKEN"] == FAKE_GH_TOKEN

    def test_existing_github_token_without_gh_token_blocks_bridge(self, builder, monkeypatch):
        _key, mod = builder
        _clear_tokens(monkeypatch)
        monkeypatch.setenv("GITHUB_PERSONAL_ACCESS_TOKEN", FAKE_PAT)
        monkeypatch.setenv("GITHUB_TOKEN", FAKE_GITHUB_TOKEN)
        env = mod._gh_env()
        assert "GH_TOKEN" not in env
        assert env["GITHUB_TOKEN"] == FAKE_GITHUB_TOKEN

    def test_no_pat_does_not_fabricate_token(self, builder, monkeypatch):
        _key, mod = builder
        _clear_tokens(monkeypatch)
        assert "GH_TOKEN" not in mod._gh_env()

    def test_both_tokens_set_neither_overwritten(self, builder, monkeypatch):
        _key, mod = builder
        _clear_tokens(monkeypatch)
        monkeypatch.setenv("GITHUB_PERSONAL_ACCESS_TOKEN", FAKE_PAT)
        monkeypatch.setenv("GH_TOKEN", FAKE_GH_TOKEN)
        monkeypatch.setenv("GITHUB_TOKEN", FAKE_GITHUB_TOKEN)
        env = mod._gh_env()
        assert env["GH_TOKEN"] == FAKE_GH_TOKEN
        assert env["GITHUB_TOKEN"] == FAKE_GITHUB_TOKEN


class TestBridgeReachesGhSubprocess:
    """端到端：桩 gh 记录子进程看到的令牌，证明桥接真正生效（不是算完丢弃）。"""

    @pytest.mark.parametrize("key", sorted(BUILDERS))
    def test_pat_bridged_into_gh_env(self, key, tmp_path):
        r, sink = _run_builder_with_tokens(
            tmp_path, BUILDERS[key], {"GITHUB_PERSONAL_ACCESS_TOKEN": FAKE_PAT})
        assert r.returncode == 0, r.stderr
        assert sink is not None
        assert f"GH_TOKEN={FAKE_PAT}" in sink

    @pytest.mark.parametrize("key", sorted(BUILDERS))
    def test_existing_gh_token_reaches_gh_unbridged(self, key, tmp_path):
        r, sink = _run_builder_with_tokens(
            tmp_path, BUILDERS[key],
            {"GITHUB_PERSONAL_ACCESS_TOKEN": FAKE_PAT, "GH_TOKEN": FAKE_GH_TOKEN})
        assert r.returncode == 0, r.stderr
        assert sink is not None
        assert f"GH_TOKEN={FAKE_GH_TOKEN}" in sink

    @pytest.mark.parametrize("key", sorted(BUILDERS))
    def test_github_token_only_not_bridged(self, key, tmp_path):
        r, sink = _run_builder_with_tokens(
            tmp_path, BUILDERS[key],
            {"GITHUB_PERSONAL_ACCESS_TOKEN": FAKE_PAT, "GITHUB_TOKEN": FAKE_GITHUB_TOKEN})
        assert r.returncode == 0, r.stderr
        assert sink is not None
        assert "GH_TOKEN=<UNSET>" in sink
        assert f"GITHUB_TOKEN={FAKE_GITHUB_TOKEN}" in sink

    @pytest.mark.parametrize("key", sorted(BUILDERS))
    def test_no_pat_nothing_bridged(self, key, tmp_path):
        r, sink = _run_builder_with_tokens(tmp_path, BUILDERS[key], {})
        assert r.returncode == 0, r.stderr
        assert sink is not None
        assert "GH_TOKEN=<UNSET>" in sink
