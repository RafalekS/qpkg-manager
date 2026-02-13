#!/bin/bash
# ============================================================================
# QPKG Builder - Interactive QPKG Package Creator for QNAP NAS
#
# Creates a ready-to-build QPKG project from any binary.
# Uses dialog for a TUI wizard. Bakes in QNAP-specific fixes:
#   - No su command (uses sudo -u)
#   - No nohup (uses bash &)
#   - No systemd (QPKG rcS.d handles boot)
#
# Runs on: QNAP NAS or Raspberry Pi (for offline prep)
# Requires: bash, dialog
# ============================================================================

set -e

SCRIPT_VERSION="1.0.0"
DIALOG=${DIALOG:-dialog}
TMPFILE=$(mktemp /tmp/qpkg-builder.XXXXXX)
trap "rm -f $TMPFILE" EXIT

# --- Defaults ----------------------------------------------------------------
DEF_AUTHOR="RLS SAP Security Ltd."
DEF_LICENSE="MIT"
DEF_QTS_MIN="5.0.0"
DEF_PORT="8080"
DEF_RC_NUM="150"
DEF_TIMEOUT="60"

# --- Helpers -----------------------------------------------------------------
die() { echo "ERROR: $1" >&2; exit 1; }

check_deps() {
    if ! command -v $DIALOG >/dev/null 2>&1; then
        echo "dialog not found. Install it first:"
        echo "  QNAP:  opkg install dialog"
        echo "  Debian: sudo apt install dialog"
        exit 1
    fi
}

# Run dialog and capture result to TMPFILE.
# NEVER call inside $(...) - dialog needs stdout for the terminal.
# After calling, read result with: result=$(cat "$TMPFILE")
ask() {
    $DIALOG "$@" 2>"$TMPFILE"
}

# Show error in dialog
show_error() {
    $DIALOG --title "Error" --msgbox "$1" 8 50
}

# --- Icon Generation ---------------------------------------------------------
generate_placeholder_icons() {
    local icon_dir="$1"
    local name="$2"

    if command -v python3 >/dev/null 2>&1; then
        python3 << PYEOF
import struct, zlib, os

def make_png(w, h, r, g, b, path):
    def chunk(t, d):
        c = t + d
        return struct.pack('>I', len(d)) + c + struct.pack('>I', zlib.crc32(c) & 0xffffffff)
    hdr = b'\x89PNG\r\n\x1a\n'
    ihdr = chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
    raw = b''
    for y in range(h):
        raw += b'\x00' + bytes([r, g, b]) * w
    idat = chunk(b'IDAT', zlib.compress(raw))
    iend = chunk(b'IEND', b'')
    with open(path, 'wb') as f:
        f.write(hdr + ihdr + idat + iend)

d = "${icon_dir}"
n = "${name}"
make_png(64, 64, 101, 155, 72, os.path.join(d, n + ".png"))
make_png(64, 64, 128, 128, 128, os.path.join(d, n + "_gray.png"))
make_png(80, 80, 101, 155, 72, os.path.join(d, n + "_80.png"))
PYEOF
        return 0
    else
        return 1
    fi
}

process_user_icon() {
    local src="$1"
    local icon_dir="$2"
    local name="$3"

    if [ ! -f "$src" ]; then
        return 1
    fi

    # Copy as main icon
    cp "$src" "${icon_dir}/${name}.png" 2>/dev/null || \
    cp "$src" "${icon_dir}/${name}.gif" 2>/dev/null

    # Try to generate gray + 80px versions via python3
    if command -v python3 >/dev/null 2>&1; then
        python3 << PYEOF
import os, struct, zlib

src = "${src}"
icon_dir = "${icon_dir}"
name = "${name}"

try:
    # Read the source file header to check if PNG
    with open(src, 'rb') as f:
        header = f.read(8)

    if header[:4] == b'\x89PNG':
        # It's a PNG - create simple gray and 80px placeholders
        # (full image processing would need PIL, so just make solid placeholders)
        def make_png(w, h, r, g, b, path):
            def chunk(t, d):
                c = t + d
                return struct.pack('>I', len(d)) + c + struct.pack('>I', zlib.crc32(c) & 0xffffffff)
            hdr = b'\x89PNG\r\n\x1a\n'
            ihdr = chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
            raw = b''
            for y in range(h):
                raw += b'\x00' + bytes([r, g, b]) * w
            idat = chunk(b'IDAT', zlib.compress(raw))
            iend = chunk(b'IEND', b'')
            with open(path, 'wb') as f:
                f.write(hdr + ihdr + idat + iend)

        make_png(64, 64, 128, 128, 128, os.path.join(icon_dir, name + "_gray.png"))
        make_png(80, 80, 101, 155, 72, os.path.join(icon_dir, name + "_80.png"))
    else:
        # Not PNG - just copy as gray too
        import shutil
        shutil.copy2(src, os.path.join(icon_dir, name + "_gray.gif"))
        shutil.copy2(src, os.path.join(icon_dir, name + "_80.gif"))
except Exception:
    pass
PYEOF
    else
        # No python3 - just copy the icon for all variants
        cp "$src" "${icon_dir}/${name}_gray.png" 2>/dev/null || true
        cp "$src" "${icon_dir}/${name}_80.png" 2>/dev/null || true
    fi
}

# --- Wizard Screens ----------------------------------------------------------

screen_welcome() {
    $DIALOG --title "QPKG Builder v${SCRIPT_VERSION}" \
        --msgbox "\
Welcome to the QPKG Package Builder!

This wizard will create a complete QPKG project
structure for your binary application.

Supports two modes:
 - Service: daemon with start/stop, port, boot
 - Standalone: CLI tool, just install the binary

QNAP quirks are handled automatically:
 - No su (uses sudo -u)
 - No nohup (uses bash &)
 - Proper privilege dropping

Press OK to begin." 21 54
}

screen_app_type() {
    ask --title "Application Type" \
        --menu "What kind of application is this?" 14 62 3 \
        "service"    "Background service/daemon (e.g. Gitea, Plex)" \
        "standalone" "CLI tool / standalone binary (e.g. ffmpeg, jq)"
    [ $? -ne 0 ] && return 1
    APP_TYPE=$(cat "$TMPFILE")
}

screen_package_info() {
    while true; do
        ask --title "Package Name" \
            --inputbox "Package name (no spaces, alphanumeric + dash/underscore):" 10 60 \
            "${PKG_NAME:-MyApp}"
        [ $? -ne 0 ] && return 1
        PKG_NAME=$(cat "$TMPFILE")

        if [ -z "$PKG_NAME" ]; then
            show_error "Package Name is required!"
            continue
        fi
        if echo "$PKG_NAME" | grep -q '[^a-zA-Z0-9_-]'; then
            show_error "Package Name must be alphanumeric (plus - and _). No spaces!"
            continue
        fi
        break
    done

    ask --title "Display Name" \
        --inputbox "Display name (shown in App Center):" 10 60 \
        "${PKG_DISPLAY:-$PKG_NAME}"
    [ $? -ne 0 ] && return 1
    PKG_DISPLAY=$(cat "$TMPFILE")
    [ -z "$PKG_DISPLAY" ] && PKG_DISPLAY="$PKG_NAME"

    ask --title "Version" \
        --inputbox "Version number:" 10 40 \
        "${PKG_VERSION:-1.0.0}"
    [ $? -ne 0 ] && return 1
    PKG_VERSION=$(cat "$TMPFILE")
    [ -z "$PKG_VERSION" ] && PKG_VERSION="1.0.0"

    ask --title "Summary" \
        --inputbox "Short description:" 10 60 \
        "${PKG_SUMMARY:-}"
    [ $? -ne 0 ] && return 1
    PKG_SUMMARY=$(cat "$TMPFILE")
}

screen_author() {
    ask --title "Author" \
        --inputbox "Package author:" 10 60 \
        "${PKG_AUTHOR:-$DEF_AUTHOR}"
    [ $? -ne 0 ] && return 1
    PKG_AUTHOR=$(cat "$TMPFILE")
    [ -z "$PKG_AUTHOR" ] && PKG_AUTHOR="$DEF_AUTHOR"

    ask --title "License" \
        --menu "License:" 14 50 5 \
        "MIT"       "MIT License" \
        "Apache"    "Apache 2.0" \
        "GPLv2"     "GNU GPL v2" \
        "GPLv3"     "GNU GPL v3" \
        "Other"     "Other / Proprietary"
    [ $? -ne 0 ] && return 1
    PKG_LICENSE=$(cat "$TMPFILE")
}

screen_binary_source() {
    ask --title "Binary Source" \
        --menu "Where is the binary?" 12 55 3 \
        "local"    "Local file path" \
        "url"      "Download from URL" \
        "later"    "I will copy it manually later"
    [ $? -ne 0 ] && return 1
    BIN_SOURCE=$(cat "$TMPFILE")

    case "$BIN_SOURCE" in
        local)
            ask --title "Binary Path" \
                --inputbox "Full path to the binary file:" 10 60 \
                "${BIN_PATH:-}"
            [ $? -ne 0 ] && return 1
            BIN_PATH=$(cat "$TMPFILE")
            if [ ! -f "$BIN_PATH" ]; then
                show_error "File not found: $BIN_PATH"
                screen_binary_source
                return $?
            fi
            BIN_FILENAME=$(basename "$BIN_PATH")
            ;;
        url)
            ask --title "Binary URL" \
                --inputbox "Download URL for the binary:" 10 70 \
                "${BIN_URL:-}"
            [ $? -ne 0 ] && return 1
            BIN_URL=$(cat "$TMPFILE")

            ask --title "Binary Filename" \
                --inputbox "Save as filename (e.g. myapp):" 10 50 \
                "${BIN_FILENAME:-$(basename "$BIN_URL" | sed 's/?.*//')}"
            [ $? -ne 0 ] && return 1
            BIN_FILENAME=$(cat "$TMPFILE")
            ;;
        later)
            ask --title "Binary Filename" \
                --inputbox "What will the binary be called? (e.g. myapp):" 10 55 \
                "${BIN_FILENAME:-$PKG_NAME}"
            [ $? -ne 0 ] && return 1
            BIN_FILENAME=$(cat "$TMPFILE")
            ;;
    esac

    # Make sure filename is lowercase for consistency
    BIN_FILENAME=$(echo "$BIN_FILENAME" | tr '[:upper:]' '[:lower:]')
}

screen_service_config() {
    ask --title "Service Port" \
        --inputbox "Port number the service listens on:" 10 50 \
        "${SVC_PORT:-$DEF_PORT}"
    [ $? -ne 0 ] && return 1
    SVC_PORT=$(cat "$TMPFILE")
    [ -z "$SVC_PORT" ] && SVC_PORT="$DEF_PORT"

    ask --title "Start Arguments" \
        --inputbox "Start arguments (e.g. 'web --port 3004'), or leave empty:" 10 65 \
        "${SVC_ARGS:-}"
    [ $? -ne 0 ] && return 1
    SVC_ARGS=$(cat "$TMPFILE")
}

screen_run_as() {
    ask --title "Run As User" \
        --menu "Which user should the service run as?" 13 60 3 \
        "root"    "Run as root (simpler, some apps allow it)" \
        "user"    "Run as specific user (safer, required by some apps)" \
        "current" "Run as current user ($(id -un))"
    [ $? -ne 0 ] && return 1
    local choice
    choice=$(cat "$TMPFILE")

    case "$choice" in
        root)
            RUN_AS_USER="root"
            ;;
        user)
            ask --title "Username" \
                --inputbox "Which user?" 10 40 \
                "${RUN_AS_USER:-rls1203}"
            [ $? -ne 0 ] && return 1
            RUN_AS_USER=$(cat "$TMPFILE")
            ;;
        current)
            RUN_AS_USER=$(id -un)
            ;;
    esac
}

screen_webui() {
    $DIALOG --title "Web UI" \
        --yesno "Does this application have a web interface?" 8 50
    if [ $? -eq 0 ]; then
        HAS_WEBUI="yes"
        ask --title "Web UI Path" \
            --inputbox "URL path (e.g. / or /app/):" 10 50 \
            "${WEBUI_PATH:-/}"
        [ $? -ne 0 ] && return 1
        WEBUI_PATH=$(cat "$TMPFILE")
    else
        HAS_WEBUI="no"
        WEBUI_PATH=""
    fi
}

screen_icon() {
    $DIALOG --title "Custom Icon" \
        --yesno "Do you have a custom icon file? (64x64 PNG or GIF)\n\nIf no, placeholder icons will be generated." 10 55
    if [ $? -eq 0 ]; then
        ask --title "Icon Path" \
            --inputbox "Full path to icon file:" 10 60 \
            "${ICON_PATH:-}"
        [ $? -ne 0 ] && return 1
        ICON_PATH=$(cat "$TMPFILE")
        if [ ! -f "$ICON_PATH" ]; then
            show_error "File not found: $ICON_PATH\nPlaceholder icons will be used."
            ICON_PATH=""
        fi
    else
        ICON_PATH=""
    fi
}

screen_output_dir() {
    local default_dir
    if [ -d "/share/homes" ]; then
        default_dir="/share/homes/$(id -un)"
    else
        default_dir="$(pwd)"
    fi

    ask --title "Output Directory" \
        --inputbox "Where to create the QPKG project folder?\n(A '${PKG_NAME}' subfolder will be created)" 12 60 \
        "${OUTPUT_DIR:-$default_dir}"
    [ $? -ne 0 ] && return 1
    OUTPUT_DIR=$(cat "$TMPFILE")
}

screen_summary() {
    local bin_info
    case "$BIN_SOURCE" in
        local) bin_info="$BIN_PATH" ;;
        url)   bin_info="Download: $BIN_URL" ;;
        later) bin_info="(manual copy later)" ;;
    esac

    local summary_text="\
Package:    ${PKG_NAME} v${PKG_VERSION}
Display:    ${PKG_DISPLAY}
Summary:    ${PKG_SUMMARY}
Author:     ${PKG_AUTHOR}
License:    ${PKG_LICENSE}
Type:       ${APP_TYPE}

Binary:     ${bin_info}
Filename:   ${BIN_FILENAME}"

    if [ "$APP_TYPE" = "service" ]; then
        local webui_info="No"
        [ "$HAS_WEBUI" = "yes" ] && webui_info="Yes (port ${SVC_PORT}, path ${WEBUI_PATH})"
        summary_text="${summary_text}
Port:       ${SVC_PORT}
Start args: ${SVC_ARGS:-none}
Run as:     ${RUN_AS_USER}
Web UI:     ${webui_info}"
    fi

    summary_text="${summary_text}
Icon:       ${ICON_PATH:-placeholder}

Output:     ${OUTPUT_DIR}/${PKG_NAME}/

Proceed with generation?"

    $DIALOG --title "Summary - Confirm" \
        --yesno "$summary_text" 24 62
}

# --- File Generation ---------------------------------------------------------

generate_qpkg_cfg() {
    local out="$1/qpkg.cfg"
    cat > "$out" << EOF
# QPKG configuration - generated by qpkg-builder v${SCRIPT_VERSION}

QPKG_NAME="${PKG_NAME}"
QPKG_DISPLAY_NAME="${PKG_DISPLAY}"
QPKG_SUMMARY="${PKG_SUMMARY}"
QPKG_VER="${PKG_VERSION}"
QPKG_AUTHOR="${PKG_AUTHOR}"
QPKG_LICENSE="${PKG_LICENSE}"

# Service management
QPKG_SERVICE_PROGRAM="${PKG_NAME}.sh"
EOF

    if [ "$APP_TYPE" = "service" ]; then
        cat >> "$out" << EOF
QPKG_SERVICE_PORT="${SVC_PORT}"
QPKG_RC_NUM="${DEF_RC_NUM}"
QPKG_TIMEOUT="${DEF_TIMEOUT}"
EOF
    fi

    if [ "$HAS_WEBUI" = "yes" ]; then
        cat >> "$out" << EOF

# Web UI - clickable link in App Center
QPKG_WEBUI="${WEBUI_PATH}"
QPKG_WEB_PORT="${SVC_PORT}"
QPKG_USE_PROXY="0"
QPKG_DESKTOP_APP="1"
EOF
    fi

    cat >> "$out" << EOF

# QTS requirements
QTS_MINI_VERSION="${DEF_QTS_MIN}"
QPKG_VOLUME_SELECT="1"
EOF
}

generate_service_script() {
    local out="$1/shared/${PKG_NAME}.sh"

    if [ "$APP_TYPE" = "standalone" ]; then
        generate_standalone_script "$out"
    else
        generate_daemon_script "$out"
    fi
    chmod +x "$out"
}

generate_standalone_script() {
    local out="$1"
    cat > "$out" << SVCEOF
#!/bin/bash
# Stub service script for ${PKG_NAME} QPKG (standalone tool)
# QTS calls this with: start | stop | restart
# This is a standalone binary - no daemon to manage.

CONF="/etc/config/qpkg.conf"
QPKG_NAME="${PKG_NAME}"
QPKG_ROOT=\$(/sbin/getcfg \$QPKG_NAME Install_Path -f \${CONF})

case "\$1" in
    start)
        echo "\${QPKG_NAME} is a standalone tool, not a service."
        echo "Binary location: \${QPKG_ROOT}/${BIN_FILENAME}"
        ;;
    stop)
        echo "\${QPKG_NAME} is a standalone tool, nothing to stop."
        ;;
    restart)
        echo "\${QPKG_NAME} is a standalone tool, nothing to restart."
        ;;
    *)
        echo "Usage: \$0 {start|stop|restart}"
        echo "\${QPKG_NAME} is a standalone tool. Run directly:"
        echo "  \${QPKG_ROOT}/${BIN_FILENAME}"
        ;;
esac
exit 0
SVCEOF
}

generate_daemon_script() {
    local out="$1"
    local needs_user_switch="false"
    [ "$RUN_AS_USER" != "root" ] && needs_user_switch="true"

    cat > "$out" << 'SVCEOF'
#!/bin/bash
# Service script for __PKG_NAME__ QPKG
# Called by QTS with: start | stop | restart

CONF="/etc/config/qpkg.conf"
QPKG_NAME="__PKG_NAME__"
QPKG_ROOT=$(/sbin/getcfg $QPKG_NAME Install_Path -f ${CONF})
SVC_BINARY="${QPKG_ROOT}/__BIN_FILENAME__"
SVC_PID="${QPKG_ROOT}/__BIN_FILENAME__.pid"
SVC_LOG="${QPKG_ROOT}/log"
SVC_PORT="__SVC_PORT__"
SVC_ARGS="__SVC_ARGS__"
RUN_USER="__RUN_AS_USER__"
SVCEOF

    if [ "$needs_user_switch" = "true" ]; then
        cat >> "$out" << 'SVCEOF'

run_cmd() {
    local cmd="$1"
    if [ "$(id -un)" = "$RUN_USER" ]; then
        bash -c "$cmd"
    elif [ "$(id -u)" -eq 0 ]; then
        sudo -u ${RUN_USER} bash -c "$cmd"
    else
        bash -c "$cmd"
    fi
}
SVCEOF
    fi

    cat >> "$out" << 'SVCEOF'

start_service() {
    if [ -f "$SVC_PID" ]; then
        local pid
        pid=$(cat "$SVC_PID" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            echo "${QPKG_NAME} already running (PID: ${pid})"
            return 0
        fi
        rm -f "$SVC_PID"
    fi

    echo "Starting ${QPKG_NAME} on port ${SVC_PORT}..."
    mkdir -p "${SVC_LOG}"

SVCEOF

    if [ "$needs_user_switch" = "true" ]; then
        cat >> "$out" << 'SVCEOF'
    run_cmd "'${SVC_BINARY}' ${SVC_ARGS} >> '${SVC_LOG}/${QPKG_NAME}.log' 2>&1 & echo \$! > '${SVC_PID}'"
SVCEOF
    else
        cat >> "$out" << 'SVCEOF'
    ${SVC_BINARY} ${SVC_ARGS} >> "${SVC_LOG}/${QPKG_NAME}.log" 2>&1 &
    echo $! > "${SVC_PID}"
SVCEOF
    fi

    cat >> "$out" << 'SVCEOF'

    sleep 3
    if [ -f "$SVC_PID" ]; then
        local new_pid
        new_pid=$(cat "$SVC_PID" 2>/dev/null)
        if [ -n "$new_pid" ] && kill -0 "$new_pid" 2>/dev/null; then
            echo "${QPKG_NAME} started (PID: ${new_pid})"
            return 0
        fi
    fi

    # Fallback: pgrep
    local found
    found=$(pgrep -f "${SVC_BINARY}" 2>/dev/null | head -1)
    if [ -n "$found" ]; then
        echo "$found" > "$SVC_PID"
        echo "${QPKG_NAME} started (PID: ${found})"
        return 0
    fi

    echo "${QPKG_NAME} failed to start. Check ${SVC_LOG}/${QPKG_NAME}.log"
    return 1
}

stop_service() {
    if [ ! -f "$SVC_PID" ]; then
        local found
        found=$(pgrep -f "${SVC_BINARY}" 2>/dev/null | head -1)
        if [ -z "$found" ]; then
            echo "${QPKG_NAME} is not running"
            return 0
        fi
        echo "$found" > "$SVC_PID"
    fi

    local pid
    pid=$(cat "$SVC_PID" 2>/dev/null)
    echo "Stopping ${QPKG_NAME} (PID: ${pid})..."
    kill "$pid" 2>/dev/null

    local count=0
    while kill -0 "$pid" 2>/dev/null && [ $count -lt 10 ]; do
        sleep 1
        count=$((count + 1))
    done

    if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null
        sleep 1
    fi

    rm -f "$SVC_PID"
    echo "${QPKG_NAME} stopped"
}

case "$1" in
    start)   start_service ;;
    stop)    stop_service ;;
    restart) stop_service; sleep 2; start_service ;;
    *)       echo "Usage: $0 {start|stop|restart}"; exit 1 ;;
esac
exit 0
SVCEOF

    # Replace placeholders
    sed -i "s|__PKG_NAME__|${PKG_NAME}|g" "$out"
    sed -i "s|__BIN_FILENAME__|${BIN_FILENAME}|g" "$out"
    sed -i "s|__SVC_PORT__|${SVC_PORT}|g" "$out"
    sed -i "s|__SVC_ARGS__|${SVC_ARGS}|g" "$out"
    sed -i "s|__RUN_AS_USER__|${RUN_AS_USER}|g" "$out"
}

generate_package_routines() {
    local out="$1/package_routines"

    cat > "$out" << EOF
#!/bin/bash
# Package routines for ${PKG_NAME} QPKG

pkg_pre_install() {
    return 0
}

pkg_install() {
    return 0
}

pkg_post_install() {
    local QPKG_ROOT
    QPKG_ROOT=\$(/sbin/getcfg ${PKG_NAME} Install_Path -f /etc/config/qpkg.conf)

    # Make binary executable
    chmod +x "\${QPKG_ROOT}/${BIN_FILENAME}"

    # Make service script executable
    chmod +x "\${QPKG_ROOT}/${PKG_NAME}.sh"

EOF

    if [ "$APP_TYPE" = "service" ]; then
        cat >> "$out" << EOF
    # Create data directories
    mkdir -p "\${QPKG_ROOT}/data"
    mkdir -p "\${QPKG_ROOT}/log"

EOF
        if [ "$RUN_AS_USER" != "root" ]; then
            cat >> "$out" << EOF
    # Set ownership for non-root user
    chown -R ${RUN_AS_USER}:everyone "\${QPKG_ROOT}/data"
    chown -R ${RUN_AS_USER}:everyone "\${QPKG_ROOT}/log"

EOF
        fi
    fi

    cat >> "$out" << EOF
    return 0
}

pkg_pre_remove() {
EOF

    if [ "$APP_TYPE" = "service" ]; then
        cat >> "$out" << EOF
    local QPKG_ROOT
    QPKG_ROOT=\$(/sbin/getcfg ${PKG_NAME} Install_Path -f /etc/config/qpkg.conf)
    if [ -f "\${QPKG_ROOT}/${BIN_FILENAME}.pid" ]; then
        local pid
        pid=\$(cat "\${QPKG_ROOT}/${BIN_FILENAME}.pid" 2>/dev/null)
        [ -n "\$pid" ] && kill "\$pid" 2>/dev/null
        sleep 2
    fi
EOF
    fi

    cat >> "$out" << EOF
    return 0
}

pkg_main_remove() {
    return 0
}

pkg_post_remove() {
    return 0
}
EOF
    chmod +x "$out"
}

generate_build_script() {
    local out="$1/build-qpkg.sh"

    cat > "$out" << 'BLDEOF'
#!/bin/bash
# Build QPKG package - run on QNAP NAS with QDK installed
set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'
ok()  { echo -e "${GREEN}[  OK ]${NC} $1"; }
err() { echo -e "${RED}[ERROR]${NC} $1"; }
msg() { echo -e "${YELLOW}[BUILD]${NC} $1"; }

# Find qbuild
QBUILD=$(which qbuild 2>/dev/null)
if [ -z "$QBUILD" ]; then
    for path in /share/CACHEDEV1_DATA/.qpkg/QDK/bin/qbuild /opt/QDK/bin/qbuild; do
        [ -x "$path" ] && QBUILD="$path" && break
    done
fi
if [ -z "$QBUILD" ] || [ ! -x "$QBUILD" ]; then
    err "qbuild not found. Install QDK from App Center."
    exit 1
fi
ok "Found qbuild: ${QBUILD}"

cd "$(dirname "$0")"

# Check binary
if [ ! -f "x86_64/__BIN_FILENAME__" ]; then
    err "Binary not found: x86_64/__BIN_FILENAME__"
    err "Copy it there before building."
    exit 1
fi

chmod +x "x86_64/__BIN_FILENAME__"
chmod +x "shared/__PKG_NAME__.sh"
chmod +x "package_routines"

msg "Building QPKG..."
echo ""
$QBUILD
echo ""

if [ -d "build" ] && ls build/*.qpkg >/dev/null 2>&1; then
    ok "Build complete!"
    ls -lh build/*.qpkg
    echo ""
    msg "Install via:"
    echo "  App Center > Install Manually > select .qpkg file"
    echo "  or: sh build/__PKG_NAME___*.qpkg"
else
    err "Build failed - check output above"
    exit 1
fi
BLDEOF

    sed -i "s|__BIN_FILENAME__|${BIN_FILENAME}|g" "$out"
    sed -i "s|__PKG_NAME__|${PKG_NAME}|g" "$out"
    chmod +x "$out"
}

save_config() {
    local out="$1/qpkg-builder.conf"
    cat > "$out" << EOF
# QPKG Builder saved config - can be loaded to regenerate
APP_TYPE="${APP_TYPE}"
PKG_NAME="${PKG_NAME}"
PKG_DISPLAY="${PKG_DISPLAY}"
PKG_VERSION="${PKG_VERSION}"
PKG_SUMMARY="${PKG_SUMMARY}"
PKG_AUTHOR="${PKG_AUTHOR}"
PKG_LICENSE="${PKG_LICENSE}"
BIN_SOURCE="${BIN_SOURCE}"
BIN_PATH="${BIN_PATH}"
BIN_URL="${BIN_URL}"
BIN_FILENAME="${BIN_FILENAME}"
SVC_PORT="${SVC_PORT}"
SVC_ARGS="${SVC_ARGS}"
RUN_AS_USER="${RUN_AS_USER}"
HAS_WEBUI="${HAS_WEBUI}"
WEBUI_PATH="${WEBUI_PATH}"
ICON_PATH="${ICON_PATH}"
OUTPUT_DIR="${OUTPUT_DIR}"
EOF
}

# --- Main Generation ---------------------------------------------------------

do_generate() {
    local project_dir="${OUTPUT_DIR}/${PKG_NAME}"

    # Create directory structure
    mkdir -p "${project_dir}/shared"
    mkdir -p "${project_dir}/x86_64"
    mkdir -p "${project_dir}/icons"

    # Generate all files
    generate_qpkg_cfg "$project_dir"
    generate_service_script "$project_dir"
    generate_package_routines "$project_dir"
    generate_build_script "$project_dir"
    save_config "$project_dir"

    # Handle binary
    case "$BIN_SOURCE" in
        local)
            cp "$BIN_PATH" "${project_dir}/x86_64/${BIN_FILENAME}"
            chmod +x "${project_dir}/x86_64/${BIN_FILENAME}"
            ;;
        url)
            if command -v wget >/dev/null 2>&1; then
                wget -O "${project_dir}/x86_64/${BIN_FILENAME}" "$BIN_URL" || true
                chmod +x "${project_dir}/x86_64/${BIN_FILENAME}" 2>/dev/null
            else
                echo "wget not available - download manually to:"
                echo "  ${project_dir}/x86_64/${BIN_FILENAME}"
            fi
            ;;
        later)
            echo "# Place your binary here" > "${project_dir}/x86_64/README"
            ;;
    esac

    # Handle icons
    if [ -n "$ICON_PATH" ] && [ -f "$ICON_PATH" ]; then
        process_user_icon "$ICON_PATH" "${project_dir}/icons" "$PKG_NAME"
    else
        if ! generate_placeholder_icons "${project_dir}/icons" "$PKG_NAME"; then
            echo "Warning: Could not generate icons (python3 not found)"
        fi
    fi

    # Show result
    local script_type="Service script"
    [ "$APP_TYPE" = "standalone" ] && script_type="Stub script (no-op)"

    $DIALOG --title "Done!" --msgbox "\
QPKG project created at:
${project_dir}/

Contents:
  qpkg.cfg              Package config
  package_routines       Install/remove hooks
  shared/${PKG_NAME}.sh  ${script_type}
  x86_64/${BIN_FILENAME} Binary
  icons/                 Package icons
  build-qpkg.sh          Build helper
  qpkg-builder.conf      Saved config

To build on QNAP:
  cd ${project_dir}
  sudo bash build-qpkg.sh

To install:
  App Center > Install Manually" 22 60
}

# --- Main Flow ---------------------------------------------------------------

main() {
    check_deps

    # Check for saved config to reload
    if [ -n "$1" ] && [ -f "$1" ]; then
        source "$1"
        $DIALOG --title "Config Loaded" \
            --yesno "Loaded config from: $1\n\nPackage: ${PKG_NAME} v${PKG_VERSION}\n\nRe-generate with these settings?" 12 50
        if [ $? -eq 0 ]; then
            do_generate
            return 0
        fi
    fi

    # Run wizard
    screen_welcome || exit 0
    screen_package_info || exit 0
    screen_author || exit 0
    screen_app_type || exit 0
    screen_binary_source || exit 0
    if [ "$APP_TYPE" = "service" ]; then
        screen_service_config || exit 0
        screen_run_as || exit 0
        screen_webui || exit 0
    else
        # Defaults for standalone - no service
        SVC_PORT=""
        SVC_ARGS=""
        RUN_AS_USER="root"
        HAS_WEBUI="no"
        WEBUI_PATH=""
    fi
    screen_icon || exit 0
    screen_output_dir || exit 0
    screen_summary || exit 0

    # Generate
    do_generate
}

main "$@"
