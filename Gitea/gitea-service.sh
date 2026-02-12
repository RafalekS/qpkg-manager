#!/bin/bash
# ============================================================================
# Gitea Service Manager for QNAP TS-464 (Linux AMD64)
# Based on: https://docs.gitea.com/installation/install-from-binary
#
# System: QNAP TS-464, QTS, Intel N5095, 16GB RAM
# Init:   BusyBox init (no systemd). /etc/ is in RAM, wiped on reboot.
# Data:   /share/CACHEDEV1_DATA (ext4, 18.8T) - persistent across reboots
# Homes:  /share/homes -> /share/CACHEDEV1_DATA/homes (persistent)
# Shell:  bash 3.2.57, nohup NOT available, screen available
# Boot:   autorun.sh on /dev/mmcblk0p6 via hal_app
# ============================================================================

# --- Configuration -----------------------------------------------------------
GITEA_VERSION="1.25.4"
GITEA_PORT="3004"
GITEA_USER="rls1203"
GITEA_HOME="/share/homes/${GITEA_USER}"
GITEA_BASE="${GITEA_HOME}/gitea-server"
GITEA_BINARY="${GITEA_BASE}/gitea"
GITEA_WORK_DIR="${GITEA_BASE}"
GITEA_CUSTOM="${GITEA_BASE}/custom"
GITEA_CONFIG="${GITEA_CUSTOM}/conf/app.ini"
GITEA_DATA="${GITEA_BASE}/data"
GITEA_LOG="${GITEA_BASE}/log"
GITEA_REPOS="${GITEA_BASE}/repositories"
GITEA_PID_FILE="${GITEA_BASE}/gitea.pid"
GITEA_SCREEN="gitea"
GITEA_DOWNLOAD_URL="https://dl.gitea.com/gitea/${GITEA_VERSION}/gitea-${GITEA_VERSION}-linux-amd64"

# --- Colours -----------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- Helper Functions --------------------------------------------------------
msg()  { echo -e "${CYAN}[gitea]${NC} $1"; }
ok()   { echo -e "${GREEN}[  OK ]${NC} $1"; }
warn() { echo -e "${YELLOW}[ WARN]${NC} $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1"; }

get_pid() {
    # Check PID file first
    if [ -f "$GITEA_PID_FILE" ]; then
        local pid
        pid=$(cat "$GITEA_PID_FILE" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            echo "$pid"
            return 0
        fi
        rm -f "$GITEA_PID_FILE"
    fi
    # Fallback: find gitea process by name
    local found
    found=$(pgrep -f "${GITEA_BINARY}.*web" 2>/dev/null | head -1)
    if [ -n "$found" ]; then
        echo "$found"
        echo "$found" > "$GITEA_PID_FILE"
        return 0
    fi
    return 1
}

# --- Commands ----------------------------------------------------------------

do_setup() {
    msg "Setting up Gitea in ${GITEA_BASE}/ ..."

    # Create directory structure
    mkdir -p "${GITEA_CUSTOM}/conf"
    mkdir -p "${GITEA_DATA}"
    mkdir -p "${GITEA_LOG}"
    mkdir -p "${GITEA_REPOS}"

    # Handle binary: move from home dir if it exists there, or download
    if [ ! -f "$GITEA_BINARY" ]; then
        if [ -f "${GITEA_HOME}/gitea" ]; then
            msg "Moving existing binary from ${GITEA_HOME}/gitea ..."
            mv "${GITEA_HOME}/gitea" "$GITEA_BINARY"
            ok "Binary moved to ${GITEA_BINARY}"
        else
            msg "Downloading Gitea v${GITEA_VERSION}..."
            wget -O "$GITEA_BINARY" "$GITEA_DOWNLOAD_URL"
            if [ $? -ne 0 ]; then
                err "Download failed!"
                return 1
            fi
            ok "Binary downloaded"
        fi
        chmod +x "$GITEA_BINARY"
    else
        ok "Binary already at ${GITEA_BINARY}"
    fi

    # Handle config: migrate from old location or create new
    if [ ! -f "$GITEA_CONFIG" ]; then
        if [ -f "${GITEA_HOME}/custom/conf/app.ini" ]; then
            msg "Found existing config at ${GITEA_HOME}/custom/conf/app.ini"
            msg "Creating fresh config (old one was from test run)"
        fi
        msg "Creating ${GITEA_CONFIG} ..."
        cat > "$GITEA_CONFIG" << EOCONF
; Gitea Configuration for QNAP TS-464
; Docs: https://docs.gitea.com/administration/config-cheat-sheet

[server]
HTTP_PORT        = ${GITEA_PORT}
ROOT_URL         = http://192.168.0.166:${GITEA_PORT}/
APP_DATA_PATH    = ${GITEA_DATA}
LFS_START_SERVER = true

[database]
DB_TYPE  = sqlite3
PATH     = ${GITEA_DATA}/gitea.db

[repository]
ROOT = ${GITEA_REPOS}

[log]
ROOT_PATH = ${GITEA_LOG}
MODE      = file
LEVEL     = info

[security]
INSTALL_LOCK = false
EOCONF
        ok "Configuration created"
    else
        ok "Configuration already exists"
    fi

    # Clean up old test artifacts from home dir
    if [ -d "${GITEA_HOME}/custom/conf" ] && [ "${GITEA_HOME}/custom" != "${GITEA_CUSTOM}" ]; then
        warn "Old test config exists at ${GITEA_HOME}/custom/"
        warn "You can remove it after verifying the new setup works:"
        echo "  rm -rf ${GITEA_HOME}/custom"
    fi

    echo ""
    ok "Setup complete!"
    echo ""
    echo "  ${GITEA_BASE}/"
    echo "  ├── gitea              (binary)"
    echo "  ├── gitea.pid          (created on start)"
    echo "  ├── custom/conf/"
    echo "  │   └── app.ini        (configuration)"
    echo "  ├── data/              (database, attachments, LFS)"
    echo "  ├── log/               (log files)"
    echo "  └── repositories/      (git repos)"
    echo ""
    msg "Next steps:"
    echo "  1. $0 start"
    echo "  2. Open http://192.168.0.166:${GITEA_PORT}/"
    echo "  3. Complete web installer"
    echo "  4. sudo $0 autostart   (boot persistence)"
}

do_start() {
    local pid
    if pid=$(get_pid); then
        warn "Gitea is already running (PID: ${pid})"
        return 1
    fi

    if [ ! -f "$GITEA_BINARY" ]; then
        err "Binary not found. Run '$0 setup' first."
        return 1
    fi

    if [ ! -f "$GITEA_CONFIG" ]; then
        err "Config not found. Run '$0 setup' first."
        return 1
    fi

    msg "Starting Gitea on port ${GITEA_PORT}..."

    # Use screen (nohup is not available on this QNAP)
    GITEA_WORK_DIR="${GITEA_WORK_DIR}" \
    GITEA_CUSTOM="${GITEA_CUSTOM}" \
    /usr/sbin/screen -dmS "${GITEA_SCREEN}" \
        bash -c "\"${GITEA_BINARY}\" web --port ${GITEA_PORT} >> \"${GITEA_LOG}/gitea-stdout.log\" 2>&1"

    # Wait for process to appear
    sleep 3
    local new_pid
    new_pid=$(pgrep -f "${GITEA_BINARY}.*web" 2>/dev/null | head -1)

    if [ -n "$new_pid" ] && kill -0 "$new_pid" 2>/dev/null; then
        echo "$new_pid" > "$GITEA_PID_FILE"
        ok "Gitea started (PID: ${new_pid})"
        ok "URL: http://192.168.0.166:${GITEA_PORT}/"
        msg "Attach to console: screen -r ${GITEA_SCREEN}"
    else
        err "Gitea failed to start. Check:"
        echo "  ${GITEA_LOG}/gitea-stdout.log"
        return 1
    fi
}

do_stop() {
    local pid
    if ! pid=$(get_pid); then
        warn "Gitea is not running"
        return 1
    fi

    msg "Stopping Gitea (PID: ${pid})..."
    kill "$pid" 2>/dev/null

    # Wait for graceful shutdown (up to 10 seconds)
    local count=0
    while kill -0 "$pid" 2>/dev/null && [ $count -lt 10 ]; do
        sleep 1
        count=$((count + 1))
    done

    if kill -0 "$pid" 2>/dev/null; then
        warn "Graceful stop timed out, force killing..."
        kill -9 "$pid" 2>/dev/null
        sleep 1
    fi

    # Kill screen session if still around
    /usr/sbin/screen -ls 2>/dev/null | grep -q "${GITEA_SCREEN}" && \
        /usr/sbin/screen -S "${GITEA_SCREEN}" -X quit 2>/dev/null

    rm -f "$GITEA_PID_FILE"
    ok "Gitea stopped"
}

do_restart() {
    do_stop 2>/dev/null
    sleep 2
    do_start
}

do_status() {
    local pid
    if pid=$(get_pid); then
        ok "Gitea is running (PID: ${pid})"
        echo "  URL:     http://192.168.0.166:${GITEA_PORT}/"
        echo "  Config:  ${GITEA_CONFIG}"
        echo "  Data:    ${GITEA_DATA}/"
        echo "  Logs:    ${GITEA_LOG}/"
        echo "  Repos:   ${GITEA_REPOS}/"
        echo "  Screen:  screen -r ${GITEA_SCREEN}"
        local version
        version=$("$GITEA_BINARY" --version 2>/dev/null)
        [ -n "$version" ] && echo "  Version: ${version}"
    else
        warn "Gitea is not running"
    fi

    # Show screen sessions
    echo ""
    msg "Screen sessions:"
    /usr/sbin/screen -ls 2>/dev/null | grep "${GITEA_SCREEN}" || echo "  (none)"
}

do_logs() {
    local lines="${1:-50}"
    local log_file="${GITEA_LOG}/gitea-stdout.log"
    if [ -f "$log_file" ]; then
        tail -n "$lines" "$log_file"
    else
        warn "No log file at ${log_file}"
    fi
}

do_update() {
    local new_version="${1:-$GITEA_VERSION}"
    local download_url="https://dl.gitea.com/gitea/${new_version}/gitea-${new_version}-linux-amd64"
    local backup="${GITEA_BINARY}.backup"

    msg "Updating Gitea to v${new_version}..."

    # Stop if running
    local was_running=false
    if get_pid > /dev/null; then
        was_running=true
        do_stop
    fi

    # Backup current binary
    if [ -f "$GITEA_BINARY" ]; then
        cp "$GITEA_BINARY" "$backup"
        ok "Backed up to ${backup}"
    fi

    # Download new version
    msg "Downloading v${new_version}..."
    wget -O "$GITEA_BINARY" "$download_url"
    if [ $? -ne 0 ]; then
        err "Download failed!"
        if [ -f "$backup" ]; then
            mv "$backup" "$GITEA_BINARY"
            warn "Restored backup"
        fi
        return 1
    fi
    chmod +x "$GITEA_BINARY"
    ok "Downloaded v${new_version}"

    if [ "$was_running" = true ]; then
        do_start
    else
        ok "Update complete. Run '$0 start' to start."
    fi
}

do_autostart() {
    local script_path
    script_path="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
    local marker="# gitea-autostart"
    # Run gitea as rls1203 with a small delay to let network come up
    local start_cmd="(sleep 30 && su - ${GITEA_USER} -c '${script_path} start') &"

    if [ "$(id -u)" -ne 0 ]; then
        err "Autostart requires root. Run:"
        echo "  sudo $0 autostart"
        return 1
    fi

    msg "Setting up QNAP autorun.sh ..."

    # Mount config partition (TS-464 = HAL-based Intel, boot on mmcblk0p6)
    local boot_dev
    boot_dev=$(/sbin/hal_app --get_boot_pd port_id=0)6
    mount -t ext2 "$boot_dev" /tmp/config 2>/dev/null

    if [ ! -d /tmp/config ] || ! mountpoint -q /tmp/config 2>/dev/null; then
        # Fallback: try direct device from recon
        mount -t ext2 /dev/mmcblk0p6 /tmp/config 2>/dev/null
    fi

    if ! ls /tmp/config/ >/dev/null 2>&1; then
        err "Cannot access config partition"
        return 1
    fi

    # Create or update autorun.sh
    if [ -f /tmp/config/autorun.sh ] && grep -qF "$marker" /tmp/config/autorun.sh; then
        warn "Gitea autostart already configured"
        grep -A1 "$marker" /tmp/config/autorun.sh
    else
        echo "" >> /tmp/config/autorun.sh
        echo "${marker}" >> /tmp/config/autorun.sh
        echo "${start_cmd}" >> /tmp/config/autorun.sh
        chmod +x /tmp/config/autorun.sh
        ok "Added to /tmp/config/autorun.sh:"
        echo "  ${start_cmd}"
    fi

    umount /tmp/config 2>/dev/null

    echo ""
    warn "IMPORTANT - Enable autorun in QTS web UI:"
    echo "  Control Panel > Hardware > General"
    echo "  Tick: 'Run user defined startup processes (autorun.sh)'"
    echo ""
    warn "NOTE: QNAP Malware Remover (installed on this NAS) can sometimes"
    warn "delete autorun.sh. If Gitea stops auto-starting after a scan,"
    warn "re-run: sudo $0 autostart"
    echo ""
    ok "Autostart configured"
}

do_remove_autostart() {
    local marker="# gitea-autostart"

    if [ "$(id -u)" -ne 0 ]; then
        err "Requires root. Run: sudo $0 remove-autostart"
        return 1
    fi

    msg "Removing Gitea from QNAP autorun.sh ..."

    local boot_dev
    boot_dev=$(/sbin/hal_app --get_boot_pd port_id=0)6
    mount -t ext2 "$boot_dev" /tmp/config 2>/dev/null

    if [ -f /tmp/config/autorun.sh ]; then
        # Remove marker line and the command line after it
        sed -i "/${marker}/{N;d;}" /tmp/config/autorun.sh
        # Remove any trailing blank lines we left
        sed -i -e :a -e '/^\n*$/{$d;N;ba' -e '}' /tmp/config/autorun.sh
        ok "Removed from autorun.sh"
    else
        warn "No autorun.sh found"
    fi

    umount /tmp/config 2>/dev/null
}

# --- Usage -------------------------------------------------------------------
usage() {
    echo ""
    echo "Gitea Service Manager for QNAP TS-464"
    echo ""
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  setup              Create dirs, download binary, create config"
    echo "  start              Start Gitea (uses screen, port ${GITEA_PORT})"
    echo "  stop               Stop Gitea gracefully"
    echo "  restart            Stop then start"
    echo "  status             Show running state and paths"
    echo "  logs [N]           Show last N log lines (default: 50)"
    echo "  update [VERSION]   Update binary (default: v${GITEA_VERSION})"
    echo "  autostart          Add to QNAP autorun.sh (requires root)"
    echo "  remove-autostart   Remove from autorun.sh (requires root)"
    echo ""
    echo "Examples:"
    echo "  $0 setup && $0 start"
    echo "  sudo $0 autostart"
    echo "  $0 update 1.25.5"
    echo "  screen -r ${GITEA_SCREEN}        # attach to console"
    echo ""
}

# --- Main --------------------------------------------------------------------
case "${1}" in
    setup)            do_setup ;;
    start)            do_start ;;
    stop)             do_stop ;;
    restart)          do_restart ;;
    status)           do_status ;;
    logs)             do_logs "${2}" ;;
    update)           do_update "${2}" ;;
    autostart)        do_autostart ;;
    remove-autostart) do_remove_autostart ;;
    *)                usage ;;
esac
