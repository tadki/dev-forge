#!/bin/bash
# Version-agnostic launcher for the Hindsight stdio MCP server.
# Used by Multica agents (via --mcp-config) so each agent can run its own
# single-bank stdio MCP process against the remote Hindsight REST API.
#
# Multica injects HINDSIGHT_BANK_ID per agent via custom_env; this wrapper just
# finds the latest plugin version and execs the MCP server, which derives the
# bank from the environment at startup.

set -euo pipefail

HOME_DIR="${HOME}"
PLUGIN_CACHE="${HOME_DIR}/.claude/plugins/cache/hindsight/hindsight-memory"
PLUGIN_DATA="${HOME_DIR}/.claude/plugins/data/hindsight-memory-hindsight"

if [ ! -d "${PLUGIN_CACHE}" ]; then
    echo "[hindsight-mcp] Plugin cache directory not found: ${PLUGIN_CACHE}" >&2
    exit 1
fi

# Pick the most recently modified version directory under the cache.
LATEST_DIR="$(ls -dt "${PLUGIN_CACHE}"/*/ 2>/dev/null | head -n 1 || true)"
if [ -z "${LATEST_DIR}" ]; then
    echo "[hindsight-mcp] No hindsight plugin version found under ${PLUGIN_CACHE}" >&2
    exit 1
fi

MCP_SERVER="${LATEST_DIR}scripts/mcp_server.py"
if [ ! -f "${MCP_SERVER}" ]; then
    echo "[hindsight-mcp] MCP server script missing: ${MCP_SERVER}" >&2
    exit 1
fi

VENV_PYTHON="${PLUGIN_DATA}/venv/bin/python"
if [ ! -x "${VENV_PYTHON}" ]; then
    echo "[hindsight-mcp] Venv python not found or not executable: ${VENV_PYTHON}" >&2
    exit 1
fi

exec "${VENV_PYTHON}" "${MCP_SERVER}"
