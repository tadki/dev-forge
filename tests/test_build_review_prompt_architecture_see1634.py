"""§SPEC-002 (RCA-M03): 架构半周检拼装器的计数器落仓与期号探测。

工具链侧的同类行为由 test_build_review_prompt_see1408.py 覆盖；本文件守架构侧
独有的两点：默认计数器必须在仓内台账目录（不再读 ~/.multica/arch-patrol），
以及与工具链同构的「未合入 PR 取 max + fail-closed」期号规则。
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
BUILDER_PATH = REPO_ROOT / "autopilots/review-prompts/architecture/build_review_prompt.py"
COUNTER_REL = "autopilots/review-prompts/architecture/ledger/review-state.json"

# 期号探测会调用真实 `gh`；单元测试把它换成本地 stub，避免联网与 CI 无 gh 的假红。
GH_STUB = r"""#!/usr/bin/env bash
exec python3 - "$@" <<'PY'
import base64, json, os, sys
args = sys.argv[1:]
if args[:2] == ["pr", "list"]:
    sys.stdout.write(os.environ.get("GH_PR_LIST", "[]"))
elif args[:1] == ["api"]:
    sha = args[1].rsplit("ref=", 1)[-1]
    nth = json.loads(os.environ["GH_CONTENTS"])[sha]
    payload = {"content": base64.b64encode(json.dumps({"nth": nth}).encode()).decode()}
    sys.stdout.write(json.dumps(payload))
else:
    sys.stderr.write("stub gh: unsupported args %r\n" % (args,))
    sys.exit(2)
PY
"""


def _make_gh_stub(parent: Path) -> Path:
    d = parent / "ghbin"
    d.mkdir(exist_ok=True)
    p = d / "gh"
    p.write_text(GH_STUB, encoding="utf-8")
    p.chmod(0o755)
    return d


_DEFAULT_GH_DIR = _make_gh_stub(Path(tempfile.mkdtemp(prefix="see1634-gh-stub-arch-")))


def _load_builder():
    spec = importlib.util.spec_from_file_location("build_review_prompt_arch", BUILDER_PATH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


builder = _load_builder()


def _run_builder(
    *cli_args: str,
    gh_dir: Path | None = None,
    env_extra: dict | None = None,
) -> subprocess.CompletedProcess[str]:
    env = dict(os.environ)
    env["PATH"] = f"{gh_dir or _DEFAULT_GH_DIR}:{env['PATH']}"
    env.setdefault("GH_PR_LIST", "[]")
    env.setdefault("GH_CONTENTS", "{}")
    env.update(env_extra or {})
    return subprocess.run(
        [sys.executable, str(BUILDER_PATH), *cli_args],
        cwd=str(REPO_ROOT),
        capture_output=True,
        text=True,
        timeout=30,
        env=env,
    )


def _pr_payload(*, sha: str = "deadbeef", path: str = COUNTER_REL, number: int = 7) -> str:
    return json.dumps([{"number": number, "headRefOid": sha, "files": [{"path": path}]}])


def _python_only_bin(tmp_path: Path) -> Path:
    """PATH that carries python3 but neither gh nor git → probe must fail closed."""
    d = tmp_path / "python-only-bin"
    d.mkdir()
    (d / "python3").symlink_to(sys.executable)
    return d


class TestDefaultStateFile:
    def test_default_counter_lives_in_repo_ledger(self, tmp_path):
        args = argparse.Namespace(
            repo_root=str(tmp_path),
            state_file=None,
            ledger_path=str(tmp_path / "ledger.md"),
            daily_report_dir=str(tmp_path / "reports"),
        )
        _repo, _tpl, _daily, _ledger, state = builder.resolve_paths(args, "2026-11-25")
        assert state == tmp_path / COUNTER_REL
        assert ".multica" not in str(state)


class TestPendingNthProbe:
    def test_unmerged_pr_nth_raises_period(self, tmp_path):
        gh = _make_gh_stub(tmp_path)
        state = tmp_path / "state.json"
        state.write_text(json.dumps({"nth": 25}), encoding="utf-8")
        out = tmp_path / "out.md"
        r = _run_builder(
            "--repo-root", str(REPO_ROOT), "--date", "2026-11-25",
            "--state-file", str(state), "--output", str(out),
            gh_dir=gh,
            env_extra={"GH_PR_LIST": _pr_payload(),
                       "GH_CONTENTS": json.dumps({"deadbeef": 30})},
        )
        assert r.returncode == 0, r.stderr
        assert "第 31 期" in out.read_text(encoding="utf-8")
        assert json.loads(state.read_text(encoding="utf-8"))["nth"] == 31

    def test_probe_failure_exits_4_keeps_state_and_writes_nothing(self, tmp_path):
        bin_only = _python_only_bin(tmp_path)
        state = tmp_path / "state.json"
        seed = json.dumps({"nth": 25})
        state.write_text(seed, encoding="utf-8")
        out = tmp_path / "out.md"
        r = _run_builder(
            "--repo-root", str(REPO_ROOT), "--date", "2026-11-25",
            "--state-file", str(state), "--output", str(out),
            gh_dir=bin_only, env_extra={"PATH": str(bin_only)},
        )
        assert r.returncode == 4, r.stderr
        assert state.read_text(encoding="utf-8") == seed
        assert not out.exists()

    def test_forced_nth_skips_probe(self, tmp_path):
        bin_only = _python_only_bin(tmp_path)
        out = tmp_path / "out.md"
        r = _run_builder(
            "--repo-root", str(REPO_ROOT), "--nth", "7", "--date", "2026-11-25",
            "--output", str(out),
            gh_dir=bin_only, env_extra={"PATH": str(bin_only)},
        )
        assert r.returncode == 0, r.stderr
        assert "第 7 期" in out.read_text(encoding="utf-8")
