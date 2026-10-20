#!/usr/bin/env bash
# Multica self-hosted upgrade script — run from WSL, upgrades remote Mac + local CLI/daemon
#
# Usage (from WSL):
#   bash .dev/launch/upgrade-multica-selfhost.sh
#
# The script copies itself to the remote Mac via SCP and runs the Docker
# upgrade over SSH. After the remote upgrade succeeds, it upgrades the
# local WSL multica CLI and restarts the daemon.
#
# Configure the target via environment variables (resolved in priority order:
# KOL_REMOTE_*, then legacy MULTICA_REMOTE_*, then the hardcoded default below).
# Edit the defaults in this file if the remote target changes (SEE-894 Plan 2:
# standalone, no longer sources a machine env / config loader):
#   KOL_REMOTE_HOST / MULTICA_REMOTE_HOST   (default: 192.168.1.210)
#   KOL_REMOTE_USER / MULTICA_REMOTE_USER   (default: jerry)
#   KOL_REMOTE_DIR  / MULTICA_REMOTE_DIR    (default: ~/Multica)
#
# Steps:
#   Remote (Mac):
#     1. Pull latest source (if inside git repo)
#     2. Pull latest Docker images (bypasses macOS keychain in SSH)
#     3. Restart services with compose override
#     4. Wait for backend API to respond
#     5. Restart frontend to flush stale DNS cache
#   Local (WSL):
#     6. Upgrade multica CLI to match remote server version
#     7. Restart local daemon

set -euo pipefail

# SEE-894 Plan 2: this script is standalone. It no longer sources a shared
# config loader; KOL_REMOTE_* / MULTICA_REMOTE_* env vars override the hardcoded
# defaults in the "Remote execution bootstrap" section below.

# SEE-1001: the local daemon is supervised by systemd (toolchain-start-all.
# service, Restart=always). Stopping/restarting it through `multica daemon
# stop|start` makes the daemon exit 0 — which systemd immediately undoes by
# restarting it, racing the binary replacement and breaking the upgrade. Route
# daemon stop/restart through systemctl so Restart= is suppressed during an
# intended stop. Fall back to the bare CLI on hosts where the unit is not
# installed (legacy bare-daemon setup).
TOOLCHAIN_SERVICE="toolchain-start-all.service"

_toolchain_service_installed() {
    systemctl list-unit-files --no-legend 2>/dev/null | grep -q "^${TOOLCHAIN_SERVICE}\b"
}

_kol_service_stop() {
    if _toolchain_service_installed && sudo systemctl stop "$TOOLCHAIN_SERVICE" 2>/dev/null; then
        return 0
    fi
    multica daemon stop 2>/dev/null || true
}

_kol_service_restart() {
    if _toolchain_service_installed && sudo systemctl restart "$TOOLCHAIN_SERVICE" 2>/dev/null; then
        return 0
    fi
    echo "[upgrade] ${TOOLCHAIN_SERVICE} not installed; falling back to bare 'multica daemon start'."
    multica daemon stop 2>/dev/null || true
    sleep 2
    multica daemon start 2>&1
}

# ---------------------------------------------------------------------------
# Local CLI + daemon upgrade (runs on WSL after remote succeeds)
# ---------------------------------------------------------------------------

_upgrade_local_cli() {
    local current latest download_url tmp_dir
    current=$(multica version 2>/dev/null | grep -oP '^multica \K[0-9.]+' || true)
    if [[ -z "$current" ]]; then
        echo "[upgrade] multica CLI not found, skipping local upgrade."
        return 0
    fi

    latest=$(curl -sI "https://github.com/multica-ai/multica/releases/latest" 2>/dev/null \
        | grep -i "location:" | grep -oP 'tag/\K[^/\r]+' | tr -d '\r\n' || true)
    if [[ -z "$latest" ]]; then
        echo "[upgrade] Could not check latest multica version. Skipping local CLI upgrade."
        return 0
    fi

    if [[ "v$current" == "$latest" ]]; then
        echo "[upgrade] Local multica CLI is already up to date ($current)."
        return 0
    fi

    echo "[upgrade] Upgrading local multica CLI: $current → ${latest#v}"

    # Stop daemon first so binary can be replaced
    if multica daemon status 2>/dev/null | grep -q "running"; then
        echo "[upgrade] Stopping local daemon to replace binary..."
        _kol_service_stop
        sleep 2
    fi

    download_url="https://github.com/multica-ai/multica/releases/download/${latest}/multica-cli-${latest#v}-linux-amd64.tar.gz"
    tmp_dir=$(mktemp -d)
    curl -sL "$download_url" -o "$tmp_dir/multica-cli.tar.gz" || {
        echo "[upgrade] WARN: Failed to download $download_url"
        rm -rf "$tmp_dir"
        return 0
    }
    tar xzf "$tmp_dir/multica-cli.tar.gz" -C "$tmp_dir" || {
        echo "[upgrade] WARN: Failed to extract tar.gz"
        rm -rf "$tmp_dir"
        return 0
    }
    sudo cp "$tmp_dir/multica" /usr/local/bin/multica && sudo chmod +x /usr/local/bin/multica
    rm -rf "$tmp_dir"
    echo "[upgrade] multica CLI upgraded to $(multica version | head -1)"
}

_upgrade_local_daemon() {
    local status
    status=$(multica daemon status 2>&1 || true)
    if echo "$status" | grep -q "running"; then
        echo "[upgrade] Restarting local daemon via ${TOOLCHAIN_SERVICE}..."
        _kol_service_restart
    else
        echo "[upgrade] Starting local daemon via ${TOOLCHAIN_SERVICE}..."
        _kol_service_restart
    fi
    sleep 3
    status=$(multica daemon status 2>&1 || true)
    if echo "$status" | grep -q "running"; then
        echo "[upgrade] Local daemon restarted successfully."
    else
        echo "[upgrade] WARN: Local daemon status after restart: $status"
    fi
}

# ---------------------------------------------------------------------------
# Remote execution bootstrap
# ---------------------------------------------------------------------------
# Priority: KOL_* (machine env) > legacy MULTICA_REMOTE_* > hardcoded default.
REMOTE_HOST="${KOL_REMOTE_HOST:-${MULTICA_REMOTE_HOST:-192.168.1.210}}"
REMOTE_USER="${KOL_REMOTE_USER:-${MULTICA_REMOTE_USER:-jerry}}"
REMOTE_DIR="${KOL_REMOTE_DIR:-${MULTICA_REMOTE_DIR:-~/Multica}}"

# If not already running on the remote Mac, SCP self over and re-execute.
if [[ -z "${_MULTICA_UPGRADE_EXEC:-}" ]]; then
    REMOTE_SCRIPT="/tmp/upgrade-multica-selfhost.sh"
    echo "[upgrade] Deploying script to $REMOTE_USER@$REMOTE_HOST..."
    scp -q "${BASH_SOURCE[0]}" "$REMOTE_USER@$REMOTE_HOST:$REMOTE_SCRIPT"
    echo "[upgrade] Running upgrade on $REMOTE_USER@$REMOTE_HOST..."
    REMOTE_EXIT=0
    ssh "$REMOTE_USER@$REMOTE_HOST" "_MULTICA_UPGRADE_EXEC=1 bash $REMOTE_SCRIPT $REMOTE_DIR" || REMOTE_EXIT=$?

    if [[ "$REMOTE_EXIT" -eq 0 ]]; then
        echo "[upgrade] Remote upgrade succeeded. Upgrading local CLI/daemon..."
        _upgrade_local_cli
        _upgrade_local_daemon
    else
        echo "[upgrade] Remote upgrade failed (exit $REMOTE_EXIT). Skipping local CLI/daemon upgrade."
    fi
    exit "$REMOTE_EXIT"
fi

# ---------------------------------------------------------------------------
# Remote execution (macOS Docker Desktop via SSH)
# ---------------------------------------------------------------------------

COMPOSE_DIR="${1:-.}"
COMPOSE_FILE="docker-compose.selfhost.yml"
OVERRIDE_FILE="docker-compose.override.yml"
BACKEND_SVC="backend"
FRONTEND_SVC="frontend"
HEALTH_TIMEOUT=120
HEALTH_INTERVAL=3
API_PORT=""

# macOS Docker Desktop path (not in SSH PATH by default). Canonical location;
# override via KOL_MAC_DOCKER_PATH if Docker lives elsewhere on the host.
MAC_DOCKER_PATH="${KOL_MAC_DOCKER_PATH:-/Applications/Docker.app/Contents/Resources/bin}"
export PATH="$MAC_DOCKER_PATH:/usr/local/bin:$PATH"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_log() {
    echo "[upgrade] $*"
}

_err() {
    echo "[upgrade] ERROR: $*" >&2
}

_warn() {
    echo "[upgrade] WARN: $*"
}

_require_cmd() {
    if ! command -v "$1" &>/dev/null; then
        _err "'$1' not found in PATH"
        exit 1
    fi
}

_cd_compose_dir() {
    if [[ "$COMPOSE_DIR" != "." ]]; then
        cd "$COMPOSE_DIR"
    fi
}

# Extract the host-mapped API port from docker compose output or .env
_detect_api_port() {
    local port
    port=$(docker compose -f "$COMPOSE_FILE" ps --format json "$BACKEND_SVC" 2>/dev/null \
        | jq -r '.Publishers[]? | select(.TargetPort == 8080) | .PublishedPort' 2>/dev/null || true)
    if [[ -n "$port" && "$port" != "null" ]]; then
        echo "$port"
        return 0
    fi
    # Fallback: parse .env for BACKEND_PORT or PORT
    if [[ -f .env ]]; then
        port=$(grep -oP '^PORT\s*=\s*\K[0-9]+' .env 2>/dev/null || true)
        [[ -n "$port" ]] && { echo "$port"; return 0; }
        port=$(grep -oP '^BACKEND_PORT\s*=\s*\K[0-9]+' .env 2>/dev/null || true)
        [[ -n "$port" ]] && { echo "$port"; return 0; }
    fi
    echo "8080"
}

_wait_backend_ready() {
    local deadline=$((SECONDS + HEALTH_TIMEOUT))
    API_PORT=$(_detect_api_port)
    _log "Backend API port detected: $API_PORT"
    _log "Waiting for backend to respond (timeout: ${HEALTH_TIMEOUT}s)..."

    while [[ $SECONDS -lt $deadline ]]; do
        local state
        state=$(docker compose -f "$COMPOSE_FILE" ps --format json "$BACKEND_SVC" 2>/dev/null \
            | jq -r '.State // "unknown"' 2>/dev/null || true)

        if [[ "$state" == "exited" || "$state" == "dead" ]]; then
            _err "Backend container exited unexpectedly."
            return 1
        fi

        if [[ "$state" == "running" ]]; then
            local http_code
            http_code=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${API_PORT}/api/config" 2>/dev/null || true)
            if [[ "$http_code" == "200" ]]; then
                _log "Backend is responding (HTTP 200)."
                return 0
            fi
        fi

        sleep "$HEALTH_INTERVAL"
    done

    _err "Backend health check timed out after ${HEALTH_TIMEOUT}s."
    return 1
}

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------

_require_cmd git
_require_cmd docker
_require_cmd curl
_require_cmd jq

_cd_compose_dir

if [[ ! -f "$COMPOSE_FILE" ]]; then
    _err "Compose file not found: $(pwd)/$COMPOSE_FILE"
    exit 1
fi

_log "Working directory: $(pwd)"

# ---------------------------------------------------------------------------
# 1. Pull latest source (skip if not in a git repo)
# ---------------------------------------------------------------------------

if [[ -d .git ]]; then
    # ---------------------------------------------------------------------------
    # 0. Pre-flight worktree recovery
    # ---------------------------------------------------------------------------
    # A previous failed run can leave merge state / unmerged paths / a stale
    # index lock. Self-heal once before touching the index so we never get
    # stuck in the same dirty state twice.

    # 1) Stale index.lock
    if [[ -f .git/index.lock ]]; then
        if ! pgrep -x git >/dev/null 2>&1; then
            _warn "Stale .git/index.lock found — removing."
            rm -f .git/index.lock
        else
            _err "A git process is running and holds .git/index.lock. Wait for it to finish and re-run."
            exit 1
        fi
    fi

    # 2) Detect and recover merge / unmerged state
    if git ls-files --unmerged 2>/dev/null | grep -q . || [[ -f .git/MERGE_HEAD ]]; then
        _warn "Worktree is in an inconsistent state from a previous run — recovering."

        recovered=false

        if [[ -f .git/MERGE_HEAD ]]; then
            if git merge --abort 2>/dev/null; then
                recovered=true
                _log "Merge state aborted."
            fi
        fi

        if [[ "$recovered" != true ]] && git ls-files --unmerged 2>/dev/null | grep -q .; then
            if git reset --merge HEAD 2>/dev/null; then
                recovered=true
                _log "Unmerged paths reset to HEAD."
            fi
        fi

        if [[ "$recovered" != true ]]; then
            _warn "Targeted recovery failed — falling back to hard reset to origin/main."
            git fetch origin main || { _err "Failed to fetch origin/main for recovery."; exit 1; }
            git reset --hard origin/main || { _err "Failed to hard reset to origin/main."; exit 1; }
        fi

        # 3) Post-recovery validation
        if git ls-files --unmerged 2>/dev/null | grep -q . || [[ -f .git/MERGE_HEAD ]]; then
            _err "Worktree still inconsistent after recovery. Inspect $(pwd) manually."
            exit 1
        fi

        _log "Worktree recovered successfully."
    fi

    _log "Pulling latest source..."

    # Stash any local changes to avoid pull conflicts
    had_changes=false
    if ! git diff --quiet HEAD 2>/dev/null || ! git diff --cached --quiet HEAD 2>/dev/null; then
        _log "Local changes detected — stashing before pull..."
        git stash push -m "upgrade-multica-auto-stash-$(date +%s)" || true
        had_changes=true
    fi

    if ! git pull origin main; then
        _err "git pull failed. Please resolve conflicts manually and re-run."
        exit 1
    fi

    # Attempt to restore stashed changes
    if [[ "$had_changes" == true ]]; then
        _log "Restoring stashed changes..."
        if ! git stash pop; then
            _err "Stashed changes conflict with the updated compose file."
            _err "The stash entry is preserved. Resolve the conflict manually and re-run this script:"
            _err "  git status"
            _err "  git stash list"
            _err "  git stash pop   # or git stash apply, then resolve and git add"
            exit 1
        fi
    fi

    _log "Source updated."
else
    _log "Not a git repo — skipping source pull."
fi
echo ""

# ---------------------------------------------------------------------------
# 2. Pull latest Docker images
# ---------------------------------------------------------------------------

_log "Pulling latest Docker images..."

# macOS Docker Desktop uses a credential store (e.g. desktop/osxkeychain).
# In non-interactive SSH sessions the keychain is locked and `docker pull`
# fails with "keychain cannot be accessed...".
#
# Workaround: install a dummy credential helper that returns empty creds,
# create a temp Docker config pointing to it, and pull each image with
# `docker --config <dir> pull <image>`.  `docker compose up -d` will then
# use the already-pulled local images.

_PULL_IMAGES=()
_COMPOSE_FILES=(-f "$COMPOSE_FILE")
[[ -f "$OVERRIDE_FILE" ]] && _COMPOSE_FILES+=(-f "$OVERRIDE_FILE")

while IFS= read -r line; do
    _PULL_IMAGES+=("$line")
done < <(docker compose "${_COMPOSE_FILES[@]}" config 2>/dev/null \
    | grep 'image:' | sed 's/.*image: *//' | sort -u)

_PULL_DIR=""
if [[ -n "${SSH_CONNECTION:-}" ]]; then
    _log "SSH session detected — bypassing Docker credential store..."
    _PULL_DIR=$(mktemp -d)
    # Dummy credential helper that always returns empty credentials
    mkdir -p "$_PULL_DIR/bin"
    cat > "$_PULL_DIR/bin/docker-credential-none" << 'HELPER'
#!/bin/sh
case "$1" in
    get) echo '{"ServerURL":"","Username":"","Secret":""}' ;;
    store|erase|list) echo '{}' ;;
esac
HELPER
    chmod +x "$_PULL_DIR/bin/docker-credential-none"
    # Docker config using the dummy helper
    mkdir -p "$_PULL_DIR/docker-config"
    echo '{"auths":{},"credsStore":"none"}' > "$_PULL_DIR/docker-config/config.json"
fi

for _img in ${_PULL_IMAGES[@]+"${_PULL_IMAGES[@]}"}; do
    _log "Pulling $_img ..."
    if [[ -n "$_PULL_DIR" ]]; then
        PATH="$_PULL_DIR/bin:$PATH" docker --config "$_PULL_DIR/docker-config" pull "$_img" || {
            _err "Failed to pull $_img"
            rm -rf "$_PULL_DIR"
            exit 1
        }
    else
        docker pull "$_img" || {
            _err "Failed to pull $_img"
            exit 1
        }
    fi
done

[[ -n "$_PULL_DIR" ]] && rm -rf "$_PULL_DIR"
unset _PULL_IMAGES _PULL_DIR _COMPOSE_FILES _img
_log "Images updated."
echo ""

# ---------------------------------------------------------------------------
# 3. Restart services
# ---------------------------------------------------------------------------

_log "Restarting services..."

if [[ -f "$OVERRIDE_FILE" ]]; then
    _log "Using override file: $OVERRIDE_FILE"
    docker compose -f "$COMPOSE_FILE" -f "$OVERRIDE_FILE" up -d
else
    docker compose -f "$COMPOSE_FILE" up -d
fi

_log "Services restarted."
echo ""

# ---------------------------------------------------------------------------
# 4. Wait for backend ready
# ---------------------------------------------------------------------------

if ! _wait_backend_ready; then
    _err "Backend failed to become ready. Aborting."
    docker compose -f "$COMPOSE_FILE" logs --tail 100 "$BACKEND_SVC"
    exit 1
fi

# Give backend a moment to fully initialise DNS registration
sleep 2
echo ""

# ---------------------------------------------------------------------------
# 5. Restart frontend to flush stale DNS cache
# ---------------------------------------------------------------------------
#
# Symptom: frontend starts before backend is ready, Node.js caches the
# failed DNS lookup (ENOTFOUND), and all /api/* proxy requests fail.
# Fix: restart frontend after backend is confirmed healthy so Node.js
# re-resolves the backend hostname.
# ---------------------------------------------------------------------------

_log "Restarting frontend to flush DNS cache..."
docker compose -f "$COMPOSE_FILE" restart "$FRONTEND_SVC"

# Verify frontend is running
sleep 2
frontend_state=$(docker compose -f "$COMPOSE_FILE" ps --format json "$FRONTEND_SVC" 2>/dev/null \
    | jq -r '.State // "unknown"' 2>/dev/null || true)

if [[ "$frontend_state" == "running" ]]; then
    _log "Frontend restarted and running."
else
    _warn "Frontend state is '$frontend_state' — please check manually."
fi

# Quick smoke test
API_PORT=$(_detect_api_port)
FRONTEND_PORT=$(docker compose -f "$COMPOSE_FILE" ps --format json "$FRONTEND_SVC" 2>/dev/null \
    | jq -r '.Publishers[]? | select(.TargetPort == 3000) | .PublishedPort' 2>/dev/null || true)
if [[ -n "$FRONTEND_PORT" && "$FRONTEND_PORT" != "null" ]]; then
    smoke=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${FRONTEND_PORT}/api/config" 2>/dev/null || true)
    if [[ "$smoke" == "200" ]]; then
        _log "Smoke test passed — frontend proxy OK."
    else
        _warn "Smoke test returned HTTP $smoke — proxy may need more time."
    fi
fi

echo ""
echo "========================================="
echo " Upgrade complete."
echo "========================================="
_log "Verify: docker compose -f $COMPOSE_FILE ps"
