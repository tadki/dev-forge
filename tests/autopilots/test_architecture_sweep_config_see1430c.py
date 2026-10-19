"""SEE-1430c O1: architecture_sweep --config wiring.

The red-line constants (`max_file_lines`, forbidden identifiers) come from a
patrol-target config (default: configs/kol.json). A missing/unreadable config
must leave the built-in defaults untouched — behaviour-compatible with the
pre-O1 hardcoded implementation.
"""

import json
import os
import sys

import pytest

sys.path.insert(
    0, os.path.join(os.path.dirname(__file__), "..", "..", "autopilots")
)

import architecture_sweep as sweep


BUILTIN_MAX_FILE_LINES = 800
BUILTIN_FIELDS = ["player_level", "gold", "total_likes", "total_clicks"]


@pytest.fixture(autouse=True)
def _restore_module_constants():
    """Each test may mutate module globals — restore afterwards."""
    saved_limit = sweep.MAX_FILE_LINES
    saved_fields = list(sweep.GAMESTATE_MIRROR_FIELDS)
    yield
    sweep.MAX_FILE_LINES = saved_limit
    sweep.GAMESTATE_MIRROR_FIELDS = saved_fields


def test_default_config_file_is_shipped():
    """The default config path points at the shipped kol.json."""
    assert os.path.isfile(sweep.DEFAULT_CONFIG_PATH)


def test_default_config_values_match_builtin_defaults():
    """configs/kol.json mirrors the built-in values (no behaviour change)."""
    sweep.apply_config(sweep.DEFAULT_CONFIG_PATH)
    assert sweep.MAX_FILE_LINES == BUILTIN_MAX_FILE_LINES
    assert sweep.GAMESTATE_MIRROR_FIELDS == BUILTIN_FIELDS


def test_config_overrides_are_applied(tmp_path):
    cfg = tmp_path / "target.json"
    cfg.write_text(
        json.dumps(
            {"max_file_lines": 1200, "forbidden_identifiers": ["alpha", "beta"]}
        )
    )
    sweep.apply_config(str(cfg))
    assert sweep.MAX_FILE_LINES == 1200
    assert sweep.GAMESTATE_MIRROR_FIELDS == ["alpha", "beta"]


def test_missing_config_falls_back_to_builtin(tmp_path):
    sweep.apply_config(str(tmp_path / "does-not-exist.json"))
    assert sweep.MAX_FILE_LINES == BUILTIN_MAX_FILE_LINES
    assert sweep.GAMESTATE_MIRROR_FIELDS == BUILTIN_FIELDS


def test_corrupt_config_falls_back_to_builtin(tmp_path):
    cfg = tmp_path / "broken.json"
    cfg.write_text("{not json!!")
    sweep.apply_config(str(cfg))
    assert sweep.MAX_FILE_LINES == BUILTIN_MAX_FILE_LINES
    assert sweep.GAMESTATE_MIRROR_FIELDS == BUILTIN_FIELDS


def test_invalid_value_types_are_ignored(tmp_path):
    cfg = tmp_path / "bad-types.json"
    cfg.write_text(
        json.dumps({"max_file_lines": "lots", "forbidden_identifiers": [1, 2]})
    )
    sweep.apply_config(str(cfg))
    assert sweep.MAX_FILE_LINES == BUILTIN_MAX_FILE_LINES
    assert sweep.GAMESTATE_MIRROR_FIELDS == BUILTIN_FIELDS


def test_cli_exposes_config_flag():
    """parse_args accepts --config (default = shipped kol.json)."""
    argv = sys.argv
    try:
        sys.argv = ["architecture_sweep.py"]
        args = sweep.parse_args()
        assert args.config == sweep.DEFAULT_CONFIG_PATH
        sys.argv = ["architecture_sweep.py", "--config", "/x/y.json"]
        assert sweep.parse_args().config == "/x/y.json"
    finally:
        sys.argv = argv
