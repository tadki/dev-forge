"""§SPEC-030 (SEE-1634): 两个拼装器期号探测（fail-closed）的边界行为钉。

期号探测是本批新增逻辑的核心：从 open PR 头读计数器、取 max、任何读不出/读不懂
都必须 fail-closed（exit 4，计数器不动，不出产物）。既有的功能测试覆盖了「未合入
PR 抬期号」「取 max」「gh 缺失」等主路径；本文件补几条容易在实现走样时静默放过的
边界：

- 计数器里的 nth 是布尔（Python 里 bool 是 int 子类）→ 必须拒绝；
- gh 非零退出即便 stdout 是合法 JSON → 必须拒绝（不能「忽略返回码照常解析」）；
- gh api 返回的载荷不是对象（如数组）→ 必须 fail-closed；
- PR 的 files 里混入 null 条目 → 安全忽略（不当成计数器改动，也不崩）；
- origin 不是 github / git 读取失败 → repo_slug 探测失败。

两个拼装器逻辑同构，逐一覆盖。全程只用桩工具，不碰网络与真实 gh。
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

# 可配置桩 gh：pr list 与 api 的 stdout 与退出码都由环境变量注入。
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
    return request.param, _load(BUILDERS[request.param], f"brp_edges_{request.param}")


def _make_bin(tmp_path: Path, name: str, script: str) -> Path:
    d = tmp_path / f"bin-{name}"
    d.mkdir(exist_ok=True)
    p = d / name
    p.write_text(script, encoding="utf-8")
    p.chmod(0o755)
    return d


def _run(builder_path: Path, mod, tmp_path: Path, env_extra: dict) -> subprocess.CompletedProcess:
    bin_dir = tmp_path / "ghbin"
    if not bin_dir.exists():
        bin_dir = _make_bin(tmp_path, "gh", GH_STUB)
    state = tmp_path / "state.json"
    if not state.exists():
        state.write_text(json.dumps({"nth": 24}), encoding="utf-8")
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


def _counter_payload(nth_value) -> str:
    return json.dumps({"content": base64.b64encode(json.dumps({"nth": nth_value}).encode()).decode()})


def _pr_touching(counter_rel: str) -> str:
    return json.dumps([{"number": 7, "headRefOid": "sha7", "files": [{"path": counter_rel}]}])


class TestProbeFailClosedEdges:
    def test_boolean_nth_counter_fails_closed(self, builder, tmp_path):
        _key, mod = builder
        r = _run(BUILDERS[_key], mod, tmp_path, {
            "E_PR_LIST": _pr_touching(mod.COUNTER_REL),
            "E_API_RAW": _counter_payload(True),
        })
        assert r.returncode == 4, r.stderr
        assert "Traceback" not in r.stderr

    def test_nonzero_prlist_rc_with_valid_json_fails_closed(self, builder, tmp_path):
        _key, mod = builder
        r = _run(BUILDERS[_key], mod, tmp_path, {
            "E_PR_LIST": _pr_touching(mod.COUNTER_REL),
            "E_PR_LIST_RC": "1",
            "E_API_RAW": _counter_payload(30),
        })
        assert r.returncode == 4, r.stderr
        assert "Traceback" not in r.stderr

    def test_api_payload_not_object_fails_closed(self, builder, tmp_path):
        _key, mod = builder
        r = _run(BUILDERS[_key], mod, tmp_path, {
            "E_PR_LIST": _pr_touching(mod.COUNTER_REL),
            "E_API_RAW": "[]",
        })
        assert r.returncode == 4, r.stderr
        assert "Traceback" not in r.stderr

    def test_api_nonzero_rc_fails_closed(self, builder, tmp_path):
        _key, mod = builder
        r = _run(BUILDERS[_key], mod, tmp_path, {
            "E_PR_LIST": _pr_touching(mod.COUNTER_REL),
            "E_API_RAW": _counter_payload(30),
            "E_API_RC": "1",
        })
        assert r.returncode == 4, r.stderr
        assert "Traceback" not in r.stderr

    def test_null_files_entry_is_ignored(self, builder, tmp_path):
        _key, mod = builder
        prs = json.dumps([{"number": 7, "headRefOid": "sha7",
                           "files": [None, {"path": "README.md"}]}])
        r = _run(BUILDERS[_key], mod, tmp_path, {"E_PR_LIST": prs})
        assert r.returncode == 0, r.stderr
        assert "第 25 期" in (tmp_path / "out.md").read_text(encoding="utf-8")


class TestRepoSlug:
    GIT_OK_HTTPS = r"""#!/usr/bin/env bash
echo "https://github.com/tadki/dev-forge.git"
"""
    GIT_OK_SSH = r"""#!/usr/bin/env bash
echo "git@github.com:tadki/dev-forge.git"
"""
    GIT_NON_GITHUB = r"""#!/usr/bin/env bash
echo "git@gitlab.com:foo/bar.git"
"""
    GIT_FAIL = r"""#!/usr/bin/env bash
echo "fatal: no remote" >&2
exit 1
"""

    @pytest.mark.parametrize("script", [GIT_OK_HTTPS, GIT_OK_SSH])
    def test_repo_slug_parses_github_remote(self, builder, tmp_path, monkeypatch, script):
        _key, mod = builder
        d = _make_bin(tmp_path, "git", script)
        monkeypatch.setenv("PATH", f"{d}:{os.environ['PATH']}")
        assert mod.repo_slug(tmp_path) == "tadki/dev-forge"

    def test_repo_slug_non_github_origin_raises(self, builder, tmp_path, monkeypatch):
        _key, mod = builder
        d = _make_bin(tmp_path, "git", self.GIT_NON_GITHUB)
        monkeypatch.setenv("PATH", f"{d}:{os.environ['PATH']}")
        with pytest.raises(mod.PendingProbeError):
            mod.repo_slug(tmp_path)

    def test_repo_slug_git_failure_raises(self, builder, tmp_path, monkeypatch):
        _key, mod = builder
        d = _make_bin(tmp_path, "git", self.GIT_FAIL)
        monkeypatch.setenv("PATH", f"{d}:{os.environ['PATH']}")
        with pytest.raises(mod.PendingProbeError):
            mod.repo_slug(tmp_path)
