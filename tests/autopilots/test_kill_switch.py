"""Kill Switch 单源入口测试（SEE-1440 / ba5ed5893ad9）。"""

import kill_switch


def _clear_env(monkeypatch, tmp_path):
    monkeypatch.delenv("KILL_SWITCH", raising=False)
    monkeypatch.setenv("DEV_FORGE_PAUSED_FILE", str(tmp_path / "DISABLED"))
    return tmp_path / "DISABLED"


def test_nothing_active_by_default(monkeypatch, tmp_path):
    paused = _clear_env(monkeypatch, tmp_path)
    assert not paused.exists()
    assert kill_switch.kill_switch_reason() == ""
    assert kill_switch.kill_switch_default() == "false"


def test_env_track_activates(monkeypatch, tmp_path):
    _clear_env(monkeypatch, tmp_path)
    monkeypatch.setenv("KILL_SWITCH", "TRUE")
    assert kill_switch.kill_switch_reason() == "env:KILL_SWITCH"
    assert kill_switch.kill_switch_default() == "true"


def test_paused_file_track_activates(monkeypatch, tmp_path):
    paused = _clear_env(monkeypatch, tmp_path)
    paused.write_text("", encoding="utf-8")
    assert kill_switch.kill_switch_reason() == "paused:%s" % paused
    assert kill_switch.kill_switch_default() == "true"


def test_explicit_false_value_not_enabled(monkeypatch, tmp_path):
    paused = _clear_env(monkeypatch, tmp_path)
    paused.write_text("", encoding="utf-8")
    # 显式参数由 argparse 传入，覆盖默认值；判定函数只认 true 系字面量。
    assert kill_switch.is_enabled("false") is False
    assert kill_switch.is_enabled("true") is True
