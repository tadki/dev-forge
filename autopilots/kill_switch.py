"""Kill Switch 单源入口（SEE-1440 / fingerprint ba5ed5893ad9）。

历史双轨：评审拼装器看 DISABLED 文件，autopilots 只看 KILL_SWITCH 环境变量。
统一后语义：
  - paused 文件（机器级，规范入口，与 toolchain_review_prompt §0 同址）命中即停用；
  - KILL_SWITCH 环境变量保留为会话级临时覆盖；
  - 显式 --kill-switch 参数仍优先于本模块产出的默认值。
"""

from __future__ import annotations

import os
from pathlib import Path

CANONICAL_PAUSED_FILE = "~/.multica/toolchain-reports/DISABLED"
_TRUTHY = {"1", "true", "yes", "on"}


def paused_file() -> Path:
    """规范 paused 文件路径（可用 DEV_FORGE_PAUSED_FILE 覆盖，供测试/迁移期使用）。"""
    return Path(os.environ.get("DEV_FORGE_PAUSED_FILE", CANONICAL_PAUSED_FILE)).expanduser()


def kill_switch_reason() -> str:
    """命中时返回原因（env:/paused:），未命中返回空串。"""
    if os.environ.get("KILL_SWITCH", "").strip().lower() in _TRUTHY:
        return "env:KILL_SWITCH"
    path = paused_file()
    if path.exists():
        return "paused:%s" % path
    return ""


def kill_switch_default() -> str:
    """argparse 默认值：paused 文件或 env 任一命中即 true。"""
    return "true" if kill_switch_reason() else "false"


def is_enabled(value: str) -> bool:
    return str(value).strip().lower() in _TRUTHY
