#!/bin/bash
# Gitea QPKG Service Script
# Called by QTS with: start | stop | restart

CONF="/etc/config/qpkg.conf"
QPKG_NAME="Gitea"
QPKG_ROOT=$(/sbin/getcfg $QPKG_NAME Install_Path -f ${CONF})
GITEA_BINARY="${QPKG_ROOT}/gitea"
GITEA_PID="${QPKG_ROOT}/gitea.pid"
GITEA_LOG="${QPKG_ROOT}/log"
GITEA_PORT="3004"
GITEA_USER="rls1203"

run_as_user() {
    # Run a command as GITEA_USER
    # Gitea refuses to run as root, so we must drop privileges
    local cmd="$1"

    if [ "$(id -un)" = "$GITEA_USER" ]; then
        # Already the right user
        bash -c "$cmd"
    elif [ "$(id -u)" -eq 0 ]; then
        # Running as root - drop to GITEA_USER via sudo -u
        sudo -u ${GITEA_USER} bash -c "$cmd"
    else
        # Some other user - just try directly
        bash -c "$cmd"
    fi
}

start_gitea() {
    if [ -f "$GITEA_PID" ]; then
        local pid
        pid=$(cat "$GITEA_PID" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            echo "Gitea already running (PID: ${pid})"
            return 0
        fi
        rm -f "$GITEA_PID"
    fi

    echo "Starting Gitea on port ${GITEA_PORT}..."

    run_as_user "
        export GITEA_WORK_DIR='${QPKG_ROOT}'
        export GITEA_CUSTOM='${QPKG_ROOT}/custom'
        '${GITEA_BINARY}' web --port ${GITEA_PORT} >> '${GITEA_LOG}/gitea.log' 2>&1 &
        echo \$! > '${GITEA_PID}'
    "

    sleep 3
    if [ -f "$GITEA_PID" ]; then
        local new_pid
        new_pid=$(cat "$GITEA_PID" 2>/dev/null)
        if [ -n "$new_pid" ] && kill -0 "$new_pid" 2>/dev/null; then
            echo "Gitea started (PID: ${new_pid})"
            return 0
        fi
    fi

    # Fallback: check if process started anyway
    local found
    found=$(pgrep -f "${GITEA_BINARY}.*web" 2>/dev/null | head -1)
    if [ -n "$found" ]; then
        echo "$found" > "$GITEA_PID"
        echo "Gitea started (PID: ${found})"
        return 0
    fi

    echo "Gitea failed to start. Check ${GITEA_LOG}/gitea.log"
    return 1
}

stop_gitea() {
    if [ ! -f "$GITEA_PID" ]; then
        # Try pgrep as fallback
        local found
        found=$(pgrep -f "${GITEA_BINARY}.*web" 2>/dev/null | head -1)
        if [ -z "$found" ]; then
            echo "Gitea is not running"
            return 0
        fi
        echo "$found" > "$GITEA_PID"
    fi

    local pid
    pid=$(cat "$GITEA_PID" 2>/dev/null)
    echo "Stopping Gitea (PID: ${pid})..."
    kill "$pid" 2>/dev/null

    # Wait for graceful shutdown
    local count=0
    while kill -0 "$pid" 2>/dev/null && [ $count -lt 10 ]; do
        sleep 1
        count=$((count + 1))
    done

    if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null
        sleep 1
    fi

    rm -f "$GITEA_PID"
    echo "Gitea stopped"
}

case "$1" in
    start)
        start_gitea
        ;;
    stop)
        stop_gitea
        ;;
    restart)
        stop_gitea
        sleep 2
        start_gitea
        ;;
    *)
        echo "Usage: $0 {start|stop|restart}"
        exit 1
        ;;
esac

exit 0
