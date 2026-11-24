"""§SPEC-002 (RCA-M03): 架构半周检拼装器的计数器落仓与期号探测。

工具链侧的同类行为由 test_build_review_prompt_see1408.py 覆盖；本文件守架构侧
独有的两点：默认计数器必须在仓内台账目录（不再读 ~/.multica/arch-patrol），
以及与工具链同构的「未合入 PR 取 max + fail-closed」期号规则。
"""
from __future__ import annotations

import argparse
import base64
import importlib.util
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
BUILDER_PATH = REPO_ROOT / "autopilots/review-prompts/architecture/build_review_prompt.py"
COUNTER_REL = "autopilots/review-prompts/architecture/ledger/review-state.json"

# 期号探测会调用真实 `gh`；单元测试把它换成本地 stub，避免联网与 CI 无 gh 的假红。
# stub 目录一律建在 pytest 管理的 tmp 下（自动回收），不在系统临时目录留垃圾。
GH_STUB = r"""#!/usr/bin/env bash
exec python3 - "$@" <<'PY'
import base64, json, os, sys
args = sys.argv[1:]
if args[:2] == ["pr", "list"]:
    if os.environ.get("GH_PR_LIST_EXIT"):
        sys.stderr.write("gh: stub API error\n")
        sys.exit(1)
    sys.stdout.write(os.environ.get("GH_PR_LIST", "[]"))
elif args[:1] == ["api"]:
    raw = os.environ.get("GH_API_RAW")
    if raw is not None:
        sys.stdout.write(raw)
    else:
        sha = args[1].rsplit("ref=", 1)[-1]
        nth = json.loads(os.environ.get("GH_CONTENTS", "{}"))[sha]
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


_DEFAULT_GH_DIR: Path | None = None


@pytest.fixture(scope="session", autouse=True)
def _default_gh_stub(tmp_path_factory):
    global _DEFAULT_GH_DIR
    d = tmp_path_factory.mktemp("see1634-gh-stub-arch")
    _DEFAULT_GH_DIR = _make_gh_stub(d)
    yield
    # 会话结束即回收：stub 目录连同 pytest 的 *current 指向链接一并清掉，
    # 不在系统临时目录留下未清理的东西。
    shutil.rmtree(d, ignore_errors=True)
    for p in d.parent.iterdir():
        if p.is_symlink() and os.path.realpath(p) == str(d):
            p.unlink()
    _DEFAULT_GH_DIR = None


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

    def test_two_pending_prs_take_max(self, tmp_path):
        gh = _make_gh_stub(tmp_path)
        state = tmp_path / "state.json"
        state.write_text(json.dumps({"nth": 25}), encoding="utf-8")
        out = tmp_path / "out.md"
        prs = json.dumps([
            {"number": 2, "headRefOid": "beef0001", "files": [{"path": COUNTER_REL}]},
            {"number": 1, "headRefOid": "cafe0001", "files": [{"path": COUNTER_REL}]},
        ])
        r = _run_builder(
            "--repo-root", str(REPO_ROOT), "--date", "2026-11-25",
            "--state-file", str(state), "--output", str(out),
            gh_dir=gh,
            env_extra={"GH_PR_LIST": prs,
                       "GH_CONTENTS": json.dumps({"beef0001": 26, "cafe0001": 25})},
        )
        assert r.returncode == 0, r.stderr
        assert "第 27 期" in out.read_text(encoding="utf-8")

    def test_counter_with_invalid_json_fails_closed(self, tmp_path):
        gh = _make_gh_stub(tmp_path)
        state = tmp_path / "state.json"
        seed = json.dumps({"nth": 25})
        state.write_text(seed, encoding="utf-8")
        out = tmp_path / "out.md"
        raw = json.dumps({"content": base64.b64encode(b"{'nth': 30}").decode()})
        r = _run_builder(
            "--repo-root", str(REPO_ROOT), "--date", "2026-11-25",
            "--state-file", str(state), "--output", str(out),
            gh_dir=gh,
            env_extra={"GH_PR_LIST": _pr_payload(), "GH_API_RAW": raw},
        )
        assert r.returncode == 4, r.stderr
        assert "Traceback" not in r.stderr
        assert state.read_text(encoding="utf-8") == seed
        assert not out.exists()

    def test_api_response_without_content_fails_closed(self, tmp_path):
        gh = _make_gh_stub(tmp_path)
        state = tmp_path / "state.json"
        seed = json.dumps({"nth": 25})
        state.write_text(seed, encoding="utf-8")
        out = tmp_path / "out.md"
        r = _run_builder(
            "--repo-root", str(REPO_ROOT), "--date", "2026-11-25",
            "--state-file", str(state), "--output", str(out),
            gh_dir=gh,
            env_extra={"GH_PR_LIST": _pr_payload(),
                       "GH_API_RAW": json.dumps({"sha": "x", "size": 0})},
        )
        assert r.returncode == 4, r.stderr
        assert "Traceback" not in r.stderr
        assert state.read_text(encoding="utf-8") == seed
        assert not out.exists()

    def test_counter_nth_not_an_integer_fails_closed(self, tmp_path):
        gh = _make_gh_stub(tmp_path)
        state = tmp_path / "state.json"
        seed = json.dumps({"nth": 25})
        state.write_text(seed, encoding="utf-8")
        out = tmp_path / "out.md"
        r = _run_builder(
            "--repo-root", str(REPO_ROOT), "--date", "2026-11-25",
            "--state-file", str(state), "--output", str(out),
            gh_dir=gh,
            env_extra={"GH_PR_LIST": _pr_payload(),
                       "GH_CONTENTS": json.dumps({"deadbeef": "30"})},
        )
        assert r.returncode == 4, r.stderr
        assert "Traceback" not in r.stderr
        assert state.read_text(encoding="utf-8") == seed
        assert not out.exists()

    def test_pr_list_not_json_fails_closed(self, tmp_path):
        gh = _make_gh_stub(tmp_path)
        state = tmp_path / "state.json"
        seed = json.dumps({"nth": 25})
        state.write_text(seed, encoding="utf-8")
        out = tmp_path / "out.md"
        r = _run_builder(
            "--repo-root", str(REPO_ROOT), "--date", "2026-11-25",
            "--state-file", str(state), "--output", str(out),
            gh_dir=gh, env_extra={"GH_PR_LIST": "not json at all"},
        )
        assert r.returncode == 4, r.stderr
        assert "Traceback" not in r.stderr
        assert state.read_text(encoding="utf-8") == seed
        assert not out.exists()

    def test_pr_list_error_fails_closed(self, tmp_path):
        gh = _make_gh_stub(tmp_path)
        state = tmp_path / "state.json"
        seed = json.dumps({"nth": 25})
        state.write_text(seed, encoding="utf-8")
        out = tmp_path / "out.md"
        r = _run_builder(
            "--repo-root", str(REPO_ROOT), "--date", "2026-11-25",
            "--state-file", str(state), "--output", str(out),
            gh_dir=gh, env_extra={"GH_PR_LIST_EXIT": "1"},
        )
        assert r.returncode == 4, r.stderr
        assert "Traceback" not in r.stderr
        assert state.read_text(encoding="utf-8") == seed
        assert not out.exists()


class TestProbeMalformedShapes:
    """Final Review 派单的异常输入族：返回形状不对/条目不完整/计数器读不懂
    一律 fail-closed（exit 4、计数器不变、无产物、无栈），以及 base64 折行
    与扫描上限边界的正反两向。"""

    SEED = json.dumps({"nth": 25})

    def _fail_closed(self, tmp_path, env_extra):
        gh = _make_gh_stub(tmp_path)
        state = tmp_path / "state.json"
        state.write_text(self.SEED, encoding="utf-8")
        out = tmp_path / "out.md"
        r = _run_builder(
            "--repo-root", str(REPO_ROOT), "--date", "2026-11-25",
            "--state-file", str(state), "--output", str(out),
            gh_dir=gh, env_extra=env_extra,
        )
        assert r.returncode == 4, r.stderr
        assert "Traceback" not in r.stderr
        assert state.read_text(encoding="utf-8") == self.SEED
        assert not out.exists()

    def test_pr_list_object_fails_closed(self, tmp_path):
        self._fail_closed(tmp_path, {"GH_PR_LIST": "{}",
                                     "GH_API_RAW": json.dumps({"content": base64.b64encode(b'{"nth": 30}').decode()})})

    def test_pr_list_null_fails_closed(self, tmp_path):
        self._fail_closed(tmp_path, {"GH_PR_LIST": "null",
                                     "GH_API_RAW": json.dumps({"content": base64.b64encode(b'{"nth": 30}').decode()})})

    def test_pr_list_null_entry_fails_closed(self, tmp_path):
        self._fail_closed(tmp_path, {"GH_PR_LIST": "[null]",
                                     "GH_API_RAW": json.dumps({"content": base64.b64encode(b'{"nth": 30}').decode()})})

    def test_pr_without_head_sha_fails_closed(self, tmp_path):
        self._fail_closed(tmp_path, {
            "GH_PR_LIST": json.dumps([{"number": 7, "files": [{"path": COUNTER_REL}]}]),
            "GH_API_RAW": json.dumps({"content": base64.b64encode(b'{"nth": 30}').decode()}),
        })

    def test_base64_garbage_suffix_fails_closed(self, tmp_path):
        good = base64.b64encode(b'{"nth": 30}').decode()
        self._fail_closed(tmp_path, {
            "GH_PR_LIST": _pr_payload(),
            "GH_API_RAW": json.dumps({"content": good + "!!!not-base64"}),
        })

    def test_base64_wrapped_newlines_still_works(self, tmp_path):
        """GitHub 真实形态：content 按 60 字符折行带换行，必须照常派生。"""
        gh = _make_gh_stub(tmp_path)
        state = tmp_path / "state.json"
        state.write_text(self.SEED, encoding="utf-8")
        out = tmp_path / "out.md"
        raw = base64.b64encode(b'{"nth": 30}').decode()
        wrapped = "\n".join(raw[i:i + 60] for i in range(0, len(raw), 60))
        r = _run_builder(
            "--repo-root", str(REPO_ROOT), "--date", "2026-11-25",
            "--state-file", str(state), "--output", str(out),
            gh_dir=gh,
            env_extra={"GH_PR_LIST": _pr_payload(), "GH_API_RAW": json.dumps({"content": wrapped})},
        )
        assert r.returncode == 0, r.stderr
        assert "第 31 期" in out.read_text(encoding="utf-8")
        assert json.loads(state.read_text(encoding="utf-8"))["nth"] == 31

    def _pr_list(self, n):
        prs = [{"number": i, "headRefOid": f"sha{i}", "files": [{"path": "README.md"}]}
               for i in range(n)]
        prs[0] = {"number": 1, "headRefOid": "deadbeef", "files": [{"path": COUNTER_REL}]}
        return json.dumps(prs)

    def test_pr_list_at_scan_limit_fails_closed(self, tmp_path):
        # 达到扫描上限即无法确认「没有漏探」，静默截断正是重号来源。
        self._fail_closed(tmp_path, {"GH_PR_LIST": self._pr_list(200),
                                     "GH_CONTENTS": json.dumps({"deadbeef": 30})})

    def test_pr_list_below_scan_limit_still_works(self, tmp_path):
        gh = _make_gh_stub(tmp_path)
        state = tmp_path / "state.json"
        state.write_text(self.SEED, encoding="utf-8")
        out = tmp_path / "out.md"
        r = _run_builder(
            "--repo-root", str(REPO_ROOT), "--date", "2026-11-25",
            "--state-file", str(state), "--output", str(out),
            gh_dir=gh,
            env_extra={"GH_PR_LIST": self._pr_list(199),
                       "GH_CONTENTS": json.dumps({"deadbeef": 30})},
        )
        assert r.returncode == 0, r.stderr
        assert "第 31 期" in out.read_text(encoding="utf-8")

    def test_repo_slug_error_hides_origin_url(self, tmp_path, monkeypatch):
        """origin 解析失败时错误信息不得回吐原始 URL（可能带 userinfo）。"""
        d = tmp_path / "gitbin"
        d.mkdir()
        (d / "git").write_text(
            '#!/usr/bin/env bash\necho "https://user:fake-secret@git.example.com/foo/bar.git"\n',
            encoding="utf-8")
        (d / "git").chmod(0o755)
        monkeypatch.setenv("PATH", f"{d}:{os.environ['PATH']}")
        with pytest.raises(builder.PendingProbeError) as ei:
            builder.repo_slug(REPO_ROOT)
        msg = str(ei.value)
        assert "fake-secret" not in msg
        assert "git.example.com" not in msg
        assert "foo/bar" not in msg
