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

SCRIPT_VERSION="1.1.0"
DIALOG=${DIALOG:-dialog}
TMPFILE=$(mktemp /tmp/qpkg-builder.XXXXXX)
DEB_TMPDIR=""
trap 'rm -f "$TMPFILE"; [ -n "$DEB_TMPDIR" ] && rm -rf "$DEB_TMPDIR"' EXIT

# --- Defaults ----------------------------------------------------------------
DEF_AUTHOR="Anon"
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

# --- Deb Extraction ----------------------------------------------------------

# Extract a .deb file into a temp directory.
# Sets DEB_TMPDIR to the extraction path.
# Creates: DEB_TMPDIR/data/ (filesystem) and DEB_TMPDIR/control/ (metadata)
extract_deb() {
    local deb_path="$1"
    DEB_TMPDIR=$(mktemp -d /tmp/qpkg-deb.XXXXXX)

    mkdir -p "$DEB_TMPDIR/data" "$DEB_TMPDIR/control"

    if command -v dpkg-deb >/dev/null 2>&1; then
        dpkg-deb -x "$deb_path" "$DEB_TMPDIR/data" 2>/dev/null || return 1
        dpkg-deb -e "$deb_path" "$DEB_TMPDIR/control" 2>/dev/null || return 1
    elif command -v ar >/dev/null 2>&1; then
        local saved_dir
        saved_dir=$(pwd)
        cd "$DEB_TMPDIR"
        ar x "$deb_path" 2>/dev/null || { cd "$saved_dir"; return 1; }
        # data.tar.* could be .gz, .xz, .zst
        local data_tar
        data_tar=$(ls data.tar.* 2>/dev/null | head -1)
        if [ -n "$data_tar" ]; then
            tar xf "$data_tar" -C data 2>/dev/null || { cd "$saved_dir"; return 1; }
        fi
        local ctrl_tar
        ctrl_tar=$(ls control.tar.* 2>/dev/null | head -1)
        if [ -n "$ctrl_tar" ]; then
            tar xf "$ctrl_tar" -C control 2>/dev/null || { cd "$saved_dir"; return 1; }
        fi
        cd "$saved_dir"
    else
        return 1
    fi
    return 0
}

# Parse the control file from a .deb extraction
# Sets: DEB_PKG_NAME, DEB_VERSION, DEB_SUMMARY, DEB_MAINTAINER, DEB_ARCH
parse_deb_control() {
    local ctrl="$DEB_TMPDIR/control/control"
    [ ! -f "$ctrl" ] && return 1

    DEB_PKG_NAME=$(sed -n 's/^Package: *//p' "$ctrl" | head -1)
    DEB_VERSION=$(sed -n 's/^Version: *//p' "$ctrl" | head -1)
    DEB_SUMMARY=$(sed -n 's/^Description: *//p' "$ctrl" | head -1)
    DEB_MAINTAINER=$(sed -n 's/^Maintainer: *//p' "$ctrl" | head -1)
    DEB_ARCH=$(sed -n 's/^Architecture: *//p' "$ctrl" | head -1)
    return 0
}

# Find executables in extracted .deb data.
# Prints paths relative to DEB_TMPDIR/data, one per line.
find_deb_executables() {
    local data_dir="$DEB_TMPDIR/data"
    # Find all regular files with execute permission bit set (using -perm,
    # not -executable, because -executable checks if current user can run
    # it which fails for cross-arch binaries e.g. arm64 host, amd64 binary)
    local all_exe
    all_exe=$(find "$data_dir" -type f -perm /111 2>/dev/null)

    if [ -z "$all_exe" ]; then
        return
    fi

    # Filter out common non-binary files (shared libs, man pages, etc.)
    # Keep: anything in bin/sbin/opt dirs, or ELF files, or scripts
    local filtered=""
    local IFS_SAVE="$IFS"
    IFS=$'\n'
    for f in $all_exe; do
        local rel
        rel=$(echo "$f" | sed "s|^${data_dir}/||")
        case "$rel" in
            # Skip shared libraries, man pages, doc files, completions
            *.so|*.so.*) continue ;;
            usr/share/*) continue ;;
            usr/lib/*)
                # But keep things under lib/*/bin/ (like Java runtime)
                case "$rel" in
                    */bin/*) ;;
                    *) continue ;;
                esac
                ;;
        esac
        filtered="${filtered}${rel}
"
    done
    IFS="$IFS_SAVE"

    echo "$filtered" | sort -u | grep -v '^$'
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

This wizard creates a QPKG project from:
 - A standalone binary (executable file)
 - A .deb package (auto-extracts binaries)

Supports two modes:
 - Service: daemon with start/stop, port, boot
 - Standalone: CLI tool, just install the binary

QNAP quirks are handled automatically:
 - No su (uses sudo -u)
 - No nohup (uses bash &)
 - Proper privilege dropping

Press OK to begin." 22 56
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
        --menu "Where is the binary?" 14 60 4 \
        "local"    "Local file path (binary or .deb)" \
        "url"      "Download from URL (binary or .deb)" \
        "deb"      "Extract from a .deb package" \
        "later"    "I will copy it manually later"
    [ $? -ne 0 ] && return 1
    BIN_SOURCE=$(cat "$TMPFILE")

    case "$BIN_SOURCE" in
        local)
            ask --title "Binary/Package Path" \
                --inputbox "Full path to the binary or .deb file:" 10 60 \
                "${BIN_PATH:-}"
            [ $? -ne 0 ] && return 1
            BIN_PATH=$(cat "$TMPFILE")
            if [ ! -f "$BIN_PATH" ]; then
                show_error "File not found: $BIN_PATH"
                screen_binary_source
                return $?
            fi
            # Auto-detect .deb
            case "$BIN_PATH" in
                *.deb)
                    BIN_SOURCE="deb"
                    DEB_PATH="$BIN_PATH"
                    handle_deb_source || return 1
                    ;;
                *)
                    BIN_FILENAME=$(basename "$BIN_PATH")
                    ;;
            esac
            ;;
        url)
            ask --title "Binary URL" \
                --inputbox "Download URL for the binary or .deb:" 10 70 \
                "${BIN_URL:-}"
            [ $? -ne 0 ] && return 1
            BIN_URL=$(cat "$TMPFILE")

            # Auto-detect .deb URL
            local url_basename
            url_basename=$(basename "$BIN_URL" | sed 's/?.*//')
            case "$url_basename" in
                *.deb)
                    BIN_SOURCE="deb"
                    # Download the .deb first
                    DEB_TMPDIR=$(mktemp -d /tmp/qpkg-deb.XXXXXX)
                    DEB_PATH="${DEB_TMPDIR}/$(echo "$url_basename" | tr '[:upper:]' '[:lower:]')"
                    $DIALOG --title "Downloading" \
                        --infobox "Downloading .deb package...\n\n$BIN_URL" 8 65
                    if command -v wget >/dev/null 2>&1; then
                        wget -q -O "$DEB_PATH" "$BIN_URL" 2>/dev/null
                    elif command -v curl >/dev/null 2>&1; then
                        curl -sL -o "$DEB_PATH" "$BIN_URL" 2>/dev/null
                    else
                        show_error "Neither wget nor curl available to download."
                        return 1
                    fi
                    if [ ! -f "$DEB_PATH" ] || [ ! -s "$DEB_PATH" ]; then
                        show_error "Download failed: $BIN_URL"
                        return 1
                    fi
                    handle_deb_source || return 1
                    ;;
                *)
                    ask --title "Binary Filename" \
                        --inputbox "Save as filename (e.g. myapp):" 10 50 \
                        "${BIN_FILENAME:-$url_basename}"
                    [ $? -ne 0 ] && return 1
                    BIN_FILENAME=$(cat "$TMPFILE")
                    ;;
            esac
            ;;
        deb)
            ask --title "Deb Package Path" \
                --inputbox "Full path to the .deb file:" 10 60 \
                "${DEB_PATH:-}"
            [ $? -ne 0 ] && return 1
            DEB_PATH=$(cat "$TMPFILE")
            if [ ! -f "$DEB_PATH" ]; then
                show_error "File not found: $DEB_PATH"
                screen_binary_source
                return $?
            fi
            handle_deb_source || return 1
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

# Handle .deb extraction, binary selection, and metadata auto-fill.
# Expects DEB_PATH to be set. Sets BIN_PATH and BIN_FILENAME.
handle_deb_source() {
    # Check extraction tools
    if ! command -v dpkg-deb >/dev/null 2>&1 && ! command -v ar >/dev/null 2>&1; then
        show_error "Cannot extract .deb: need dpkg-deb or ar.\n\nInstall binutils (for ar) or dpkg."
        return 1
    fi

    $DIALOG --title "Extracting" \
        --infobox "Extracting .deb package..." 5 40

    if ! extract_deb "$DEB_PATH"; then
        show_error "Failed to extract .deb file."
        return 1
    fi

    # Parse control file for metadata
    if parse_deb_control; then
        # Auto-fill package info if not already set by user
        if [ -z "$PKG_NAME" ] || [ "$PKG_NAME" = "MyApp" ]; then
            # Sanitise deb package name for QPKG (replace dots with dashes)
            PKG_NAME=$(echo "$DEB_PKG_NAME" | sed 's/[^a-zA-Z0-9_-]/-/g')
        fi
        if [ -z "$PKG_DISPLAY" ] || [ "$PKG_DISPLAY" = "$PKG_NAME" ]; then
            PKG_DISPLAY="$DEB_PKG_NAME"
        fi
        [ -z "$PKG_VERSION" ] || [ "$PKG_VERSION" = "1.0.0" ] && PKG_VERSION="$DEB_VERSION"
        [ -z "$PKG_SUMMARY" ] && PKG_SUMMARY="$DEB_SUMMARY"
        if [ -n "$DEB_MAINTAINER" ]; then
            # Strip email from maintainer for author field
            PKG_AUTHOR=$(echo "$DEB_MAINTAINER" | sed 's/ *<[^>]*>//')
        fi

        # Show what we found
        local arch_note=""
        if [ -n "$DEB_ARCH" ] && [ "$DEB_ARCH" != "amd64" ] && [ "$DEB_ARCH" != "all" ]; then
            arch_note="\n\nWARNING: This .deb is for '${DEB_ARCH}'.\nQNAP TS-464 needs amd64 binaries!"
        fi
        $DIALOG --title "Deb Package Info" \
            --msgbox "\
Extracted from .deb control file:

Package:     ${DEB_PKG_NAME}
Version:     ${DEB_VERSION}
Description: ${DEB_SUMMARY}
Maintainer:  ${DEB_MAINTAINER}
Arch:        ${DEB_ARCH}${arch_note}

These values will be used as defaults." 16 60
    fi

    # Find executables
    local exe_list
    exe_list=$(find_deb_executables)

    if [ -z "$exe_list" ]; then
        show_error "No executables found in .deb package.\n\nThe package may contain only libraries or data files."
        return 1
    fi

    local exe_count
    exe_count=$(echo "$exe_list" | wc -l)

    if [ "$exe_count" -eq 1 ]; then
        # Only one executable - use it directly
        local exe_path="$exe_list"
        BIN_FILENAME=$(basename "$exe_path")
        BIN_PATH="${DEB_TMPDIR}/data/${exe_path}"

        $DIALOG --title "Binary Found" \
            --msgbox "Found executable:\n\n${exe_path}\n\nThis will be packaged as: ${BIN_FILENAME}" 12 60
    else
        # Multiple executables - let user pick
        local menu_args=""
        local i=1
        local IFS_SAVE="$IFS"
        IFS=$'\n'
        for exe in $exe_list; do
            local fname
            fname=$(basename "$exe")
            menu_args="$menu_args \"$exe\" \"$fname\""
            i=$((i + 1))
        done
        IFS="$IFS_SAVE"

        # Build the dialog command with eval since menu_args has quotes
        eval "ask --title \"Select Binary\" \
            --menu \"Multiple executables found. Which one is the main binary?\" 20 70 $((exe_count > 10 ? 10 : exe_count)) \
            $menu_args"
        [ $? -ne 0 ] && return 1
        local selected
        selected=$(cat "$TMPFILE")

        BIN_FILENAME=$(basename "$selected")
        BIN_PATH="${DEB_TMPDIR}/data/${selected}"
    fi

    # Verify the selected binary exists
    if [ ! -f "$BIN_PATH" ]; then
        show_error "Selected binary not found at:\n$BIN_PATH"
        return 1
    fi

    return 0
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
        deb)   bin_info="From .deb: $(basename "${DEB_PATH:-unknown}")" ;;
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
# Build QPKG package
# Works with qbuild (QDK) or standalone (any Linux with tar/gzip)
set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'
ok()  { echo -e "${GREEN}[  OK ]${NC} $1"; }
err() { echo -e "${RED}[ERROR]${NC} $1"; }
msg() { echo -e "${YELLOW}[BUILD]${NC} $1"; }

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

# Read qpkg.cfg values
source_cfg() {
    local key="$1" file="qpkg.cfg"
    sed -n "s/^${key}=\"\(.*\)\"/\1/p" "$file" | head -1
}

PKG_NAME=$(source_cfg QPKG_NAME)
PKG_DISPLAY=$(source_cfg QPKG_DISPLAY_NAME)
PKG_VER=$(source_cfg QPKG_VER)

# --- Standalone builder (no QDK needed) -----------------------------------

build_standalone() {
    msg "Building QPKG (standalone mode - no QDK)..."
    local WORK=$(mktemp -d)
    trap "rm -rf '$WORK'" EXIT

    # 1. Collect data files (what gets installed to QPKG_ROOT)
    local DATA_DIR="$WORK/data"
    mkdir -p "$DATA_DIR"
    # Copy binary
    cp "x86_64/__BIN_FILENAME__" "$DATA_DIR/"
    chmod +x "$DATA_DIR/__BIN_FILENAME__"
    # Copy service script
    cp "shared/__PKG_NAME__.sh" "$DATA_DIR/"
    chmod +x "$DATA_DIR/__PKG_NAME__.sh"
    # Copy icons if present
    if [ -d "icons" ] && ls icons/* >/dev/null 2>&1; then
        mkdir -p "$DATA_DIR/.qpkg_icon"
        cp icons/* "$DATA_DIR/.qpkg_icon/" 2>/dev/null || true
    fi
    ok "Data files collected"

    # 2. Create data.tar.gz
    (cd "$DATA_DIR" && tar czf "$WORK/data.tar.gz" .)
    ok "data.tar.gz created ($(du -h "$WORK/data.tar.gz" | cut -f1))"

    # 3. Create qinstall.sh (runs during .qpkg installation on NAS)
    cat > "$WORK/qinstall.sh" << 'QINSTEOF'
#!/bin/sh
# QPKG installer script - called during .qpkg installation
CONF="/etc/config/qpkg.conf"
QPKG_NAME="__PKG_NAME__"

# Find install path
PUBLIC_SHARE=$(/sbin/getcfg Public path -f /etc/config/smb.conf 2>/dev/null)
if [ -z "$PUBLIC_SHARE" ]; then
    PUBLIC_SHARE="/share/CACHEDEV1_DATA"
fi
QPKG_DIR="${PUBLIC_SHARE}/.qpkg/${QPKG_NAME}"

# Extract data
mkdir -p "$QPKG_DIR"
SCRIPT_LEN=$(sed -n '2p' /dev/stdin 2>/dev/null || echo 0)

# Source package_routines if present
[ -f package_routines ] && . ./package_routines

# Run pre-install
type pkg_pre_install >/dev/null 2>&1 && pkg_pre_install

# Copy files from extraction dir to install dir
if [ -d "data" ]; then
    cp -af data/* "$QPKG_DIR/" 2>/dev/null
fi

# Register in qpkg.conf
/sbin/setcfg "$QPKG_NAME" Name "$QPKG_NAME" -f "$CONF"
/sbin/setcfg "$QPKG_NAME" Install_Path "$QPKG_DIR" -f "$CONF"
/sbin/setcfg "$QPKG_NAME" Enable "TRUE" -f "$CONF"

# Read and apply settings from qpkg.cfg
if [ -f qpkg.cfg ]; then
    display=$(/bin/grep "^QPKG_DISPLAY_NAME=" qpkg.cfg | cut -d'"' -f2)
    version=$(/bin/grep "^QPKG_VER=" qpkg.cfg | cut -d'"' -f2)
    svc_prog=$(/bin/grep "^QPKG_SERVICE_PROGRAM=" qpkg.cfg | cut -d'"' -f2)
    svc_port=$(/bin/grep "^QPKG_SERVICE_PORT=" qpkg.cfg | cut -d'"' -f2)
    rc_num=$(/bin/grep "^QPKG_RC_NUM=" qpkg.cfg | cut -d'"' -f2)
    webui=$(/bin/grep "^QPKG_WEBUI=" qpkg.cfg | cut -d'"' -f2)
    web_port=$(/bin/grep "^QPKG_WEB_PORT=" qpkg.cfg | cut -d'"' -f2)

    [ -n "$display" ] && /sbin/setcfg "$QPKG_NAME" Display_Name "$display" -f "$CONF"
    [ -n "$version" ] && /sbin/setcfg "$QPKG_NAME" Version "$version" -f "$CONF"
    [ -n "$svc_prog" ] && /sbin/setcfg "$QPKG_NAME" Shell "$QPKG_DIR/$svc_prog" -f "$CONF"
    [ -n "$svc_port" ] && /sbin/setcfg "$QPKG_NAME" Service_Port "$svc_port" -f "$CONF"
    [ -n "$rc_num" ] && /sbin/setcfg "$QPKG_NAME" RC_Number "$rc_num" -f "$CONF"
    [ -n "$webui" ] && /sbin/setcfg "$QPKG_NAME" Web_URL "$webui" -f "$CONF"
    [ -n "$web_port" ] && /sbin/setcfg "$QPKG_NAME" Web_Port "$web_port" -f "$CONF"
fi

# Handle icons
if [ -d "$QPKG_DIR/.qpkg_icon" ]; then
    ICON_DIR="/home/httpd/RSS/pkg_icons"
    mkdir -p "$ICON_DIR"
    cp "$QPKG_DIR/.qpkg_icon"/* "$ICON_DIR/" 2>/dev/null
fi

# Run post-install
type pkg_post_install >/dev/null 2>&1 && pkg_post_install

echo "${QPKG_NAME} installed to ${QPKG_DIR}"
QINSTEOF
    sed -i "s|__PKG_NAME__|${PKG_NAME}|g" "$WORK/qinstall.sh"
    chmod +x "$WORK/qinstall.sh"

    # 4. Create control.tar.gz (contains qpkg.cfg, package_routines, qinstall.sh)
    cp qpkg.cfg "$WORK/qpkg.cfg"
    cp package_routines "$WORK/package_routines"
    (cd "$WORK" && tar czf "$WORK/control.tar.gz" qpkg.cfg package_routines qinstall.sh)
    ok "control.tar.gz created"

    # 5. Create control archive block (tar of control.tar.gz, padded to 20480 bytes)
    (cd "$WORK" && tar cf "$WORK/control_block.tar" control.tar.gz)
    local block_size=$(stat -c%s "$WORK/control_block.tar" 2>/dev/null || stat -f%z "$WORK/control_block.tar")
    if [ "$block_size" -lt 20480 ]; then
        dd if=/dev/zero bs=1 count=$((20480 - block_size)) >> "$WORK/control_block.tar" 2>/dev/null
    fi
    ok "Control block created (20480 bytes)"

    # 6. Create the shell script header
    cat > "$WORK/header.sh" << 'HDREOF'
#!/bin/sh
# QPKG package installer
# Generated by qpkg-builder (standalone mode)
set -e

echo "Installing __PKG_DISPLAY__ v__PKG_VER__..."

EXTRACT_DIR=$(mktemp -d /tmp/qpkg-install.XXXXXX)
trap "rm -rf '$EXTRACT_DIR'" EXIT

script_len=__SCRIPT_LEN__

# Extract control archive (20480 bytes after script header)
dd if="${0}" bs=$script_len skip=1 2>/dev/null | \
    tar xf - -C "$EXTRACT_DIR" 2>/dev/null

# Extract control.tar.gz within the control block
if [ -f "$EXTRACT_DIR/control.tar.gz" ]; then
    (cd "$EXTRACT_DIR" && tar xzf control.tar.gz 2>/dev/null)
fi

# Extract data archive (after script header + 20480 byte control block)
offset=$(expr $script_len + 20480)
mkdir -p "$EXTRACT_DIR/data"
dd if="${0}" bs=1 skip=$offset 2>/dev/null | \
    head -c __DATA_LEN__ | \
    tar xzf - -C "$EXTRACT_DIR/data" 2>/dev/null

# Run the installer
cd "$EXTRACT_DIR"
if [ -f qinstall.sh ]; then
    /bin/sh qinstall.sh
else
    echo "ERROR: qinstall.sh not found in package"
    exit 1
fi

echo "Done."
exit 0
HDREOF
    sed -i "s|__PKG_DISPLAY__|${PKG_DISPLAY}|g" "$WORK/header.sh"
    sed -i "s|__PKG_VER__|${PKG_VER}|g" "$WORK/header.sh"

    # Calculate script_len (we need to know the size after substitution)
    # Use a placeholder length, measure, then recalculate
    sed -i "s|__SCRIPT_LEN__|99999|" "$WORK/header.sh"
    local data_len=$(stat -c%s "$WORK/data.tar.gz" 2>/dev/null || stat -f%z "$WORK/data.tar.gz")
    sed -i "s|__DATA_LEN__|${data_len}|" "$WORK/header.sh"
    local hdr_len=$(stat -c%s "$WORK/header.sh" 2>/dev/null || stat -f%z "$WORK/header.sh")
    # script_len is the same digit count as 99999 (5 digits), so size stays stable
    sed -i "s|99999|$(printf '%05d' $hdr_len)|" "$WORK/header.sh"
    # Verify size didn't change
    local hdr_len2=$(stat -c%s "$WORK/header.sh" 2>/dev/null || stat -f%z "$WORK/header.sh")
    if [ "$hdr_len" -ne "$hdr_len2" ]; then
        # Size changed - recalculate
        sed -i "s|$(printf '%05d' $hdr_len)|$(printf '%05d' $hdr_len2)|" "$WORK/header.sh"
    fi

    # 7. Create 100-byte footer
    printf "%-10s%-40s%-10s%-20s%-10s%-10s" \
        "" "" "$(date +%s | cut -c1-10)" \
        "$PKG_DISPLAY" "$PKG_VER" "QNAPQPKG" \
        > "$WORK/footer.bin"

    # 8. Assemble the .qpkg file
    mkdir -p build
    local outfile="build/${PKG_NAME}_${PKG_VER}_x86_64.qpkg"
    cat "$WORK/header.sh" "$WORK/control_block.tar" "$WORK/data.tar.gz" "$WORK/footer.bin" > "$outfile"
    chmod +x "$outfile"
    ok "QPKG assembled: $outfile"
    ls -lh "$outfile"
}

# --- Try qbuild first, fall back to standalone ----------------------------

QBUILD=""
for path in $(which qbuild 2>/dev/null) \
    /usr/share/QDK/bin/qbuild \
    /usr/local/share/QDK/bin/qbuild \
    "$HOME/QDK/bin/qbuild" \
    /share/CACHEDEV1_DATA/.qpkg/QDK/bin/qbuild \
    /opt/QDK/bin/qbuild; do
    [ -x "$path" ] && QBUILD="$path" && break
done

if [ -n "$QBUILD" ]; then
    ok "Found qbuild: ${QBUILD}"
    msg "Building QPKG with QDK..."
    echo ""
    $QBUILD
    echo ""
    if [ -d "build" ] && ls build/*.qpkg >/dev/null 2>&1; then
        ok "Build complete!"
        ls -lh build/*.qpkg
    else
        err "qbuild failed - check output above"
        exit 1
    fi
else
    msg "qbuild not found - using standalone builder"
    build_standalone
fi

echo ""
msg "Install via:"
echo "  App Center > Install Manually > select .qpkg file"
echo "  or on NAS:  sh build/__PKG_NAME___*.qpkg"
BLDEOF

    sed -i "s|__BIN_FILENAME__|${BIN_FILENAME}|g" "$out"
    sed -i "s|__PKG_NAME__|${PKG_NAME}|g" "$out"
    sed -i "s|__PKG_DISPLAY__|${PKG_DISPLAY}|g" "$out"
    sed -i "s|__PKG_VER__|${PKG_VERSION}|g" "$out"
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
DEB_PATH="${DEB_PATH}"
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
        local|deb)
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

    # Show what was created
    local script_type="Service script"
    [ "$APP_TYPE" = "standalone" ] && script_type="Stub script (no-op)"

    $DIALOG --title "Project Created" --msgbox "\
QPKG project created at:
${project_dir}/

Contents:
  qpkg.cfg              Package config
  package_routines       Install/remove hooks
  shared/${PKG_NAME}.sh  ${script_type}
  x86_64/${BIN_FILENAME} Binary
  icons/                 Package icons
  build-qpkg.sh          Build helper
  qpkg-builder.conf      Saved config" 16 60

    # Offer to build the .qpkg now
    screen_build "$project_dir"
}

screen_build() {
    local project_dir="$1"

    # Detect qbuild (QDK)
    local qbuild_path=""
    for p in $(which qbuild 2>/dev/null) \
        /share/CACHEDEV1_DATA/.qpkg/QDK/bin/qbuild \
        /opt/QDK/bin/qbuild; do
        [ -x "$p" ] && qbuild_path="$p" && break
    done

    # Can't build if source was "later" (no binary yet)
    if [ "$BIN_SOURCE" = "later" ]; then
        $DIALOG --title "Build" --msgbox "\
Cannot build yet - no binary provided.

Copy your binary to:
  ${project_dir}/x86_64/${BIN_FILENAME}

Then build with:
  cd ${project_dir}
  bash build-qpkg.sh" 12 60
        return 0
    fi

    if [ -n "$qbuild_path" ]; then
        # QDK found
        $DIALOG --title "Build QPKG" \
            --yesno "\
QDK detected: ${qbuild_path}

Build the .qpkg package now?" 9 55
        if [ $? -ne 0 ]; then
            return 0
        fi
    else
        # No QDK - offer options
        ask --title "Build QPKG" \
            --menu "No QDK (qbuild) detected." 16 65 3 \
            "standalone" "Build now without QDK (standalone builder)" \
            "install"    "Install QDK first, then build" \
            "skip"       "Skip - I will build later"
        [ $? -ne 0 ] && return 0
        local choice
        choice=$(cat "$TMPFILE")

        case "$choice" in
            skip)
                $DIALOG --title "Build Later" --msgbox "\
To build later:
  cd ${project_dir}
  bash build-qpkg.sh" 8 55
                return 0
                ;;
            install)
                install_qdk || true
                # Re-check for qbuild after install
                for p in $(which qbuild 2>/dev/null) \
                    /usr/share/QDK/bin/qbuild \
                    /usr/local/share/QDK/bin/qbuild \
                    "$HOME/QDK/bin/qbuild" \
                    /share/CACHEDEV1_DATA/.qpkg/QDK/bin/qbuild \
                    /opt/QDK/bin/qbuild; do
                    [ -x "$p" ] && qbuild_path="$p" && break
                done
                if [ -z "$qbuild_path" ]; then
                    $DIALOG --title "QDK Install" \
                        --yesno "QDK install attempted. qbuild still not found.\n\nBuild with standalone builder instead?" 10 55
                    [ $? -ne 0 ] && return 0
                fi
                ;;
            standalone)
                # Fall through to build
                ;;
        esac
    fi

    # Run the build
    $DIALOG --title "Building..." \
        --infobox "Building .qpkg package...\n\nThis may take a moment." 7 50

    local build_output
    build_output=$(cd "$project_dir" && bash build-qpkg.sh 2>&1) || true

    # Check if build produced a .qpkg
    local qpkg_file
    qpkg_file=$(ls "${project_dir}"/build/*.qpkg 2>/dev/null | head -1)

    if [ -n "$qpkg_file" ] && [ -f "$qpkg_file" ]; then
        local qpkg_size
        qpkg_size=$(ls -lh "$qpkg_file" | awk '{print $5}')
        $DIALOG --title "Build Successful!" --msgbox "\
QPKG package built successfully!

File: ${qpkg_file}
Size: ${qpkg_size}

To install on QNAP:
  1. Copy .qpkg to NAS (scp, SMB, etc.)
  2. App Center > Install Manually
  or: sh $(basename "$qpkg_file")" 14 62
    else
        # Show build output on failure
        $DIALOG --title "Build Failed" --msgbox "\
Build failed. Output:\n\n${build_output}" 20 70
    fi
}

install_qdk() {
    # Detect platform and offer appropriate install method
    local platform="unknown"
    if [ -f /etc/config/qpkg.conf ]; then
        platform="qnap"
    elif grep -qi microsoft /proc/version 2>/dev/null; then
        platform="wsl"
    elif [ -f /etc/debian_version ]; then
        platform="debian"
    fi

    case "$platform" in
        qnap)
            $DIALOG --title "Install QDK" --msgbox "\
On QNAP, install QDK from App Center:
  App Center > Developer Tools > QDK

Or install via command line:
  /sbin/qpkg_cli -m QDK" 10 55
            return 1
            ;;
        wsl|debian)
            $DIALOG --title "Install QDK" \
                --yesno "\
Install QDK from GitHub?\n\n\
This will clone qnap-dev/QDK2 to ~/QDK\n\
and add it to your PATH.\n\n\
Requires: git" 12 55
            if [ $? -ne 0 ]; then
                return 1
            fi

            if ! command -v git >/dev/null 2>&1; then
                show_error "git is required but not installed.\n\nsudo apt install git"
                return 1
            fi

            $DIALOG --title "Installing QDK" \
                --infobox "Cloning QDK from GitHub..." 5 45

            if git clone https://github.com/qnap-dev/QDK2.git "$HOME/QDK" 2>/dev/null; then
                chmod +x "$HOME/QDK/bin/qbuild" 2>/dev/null
                export PATH="$HOME/QDK/bin:$PATH"
                $DIALOG --title "QDK Installed" --msgbox "\
QDK installed to ~/QDK

To make permanent, add to your ~/.bashrc:
  export PATH=\"\$HOME/QDK/bin:\$PATH\"" 10 55
                return 0
            else
                if [ -d "$HOME/QDK" ]; then
                    # Already exists
                    chmod +x "$HOME/QDK/bin/qbuild" 2>/dev/null
                    export PATH="$HOME/QDK/bin:$PATH"
                    $DIALOG --title "QDK" --msgbox "~/QDK already exists. Using it." 7 45
                    return 0
                fi
                show_error "Failed to clone QDK repository."
                return 1
            fi
            ;;
        *)
            $DIALOG --title "Install QDK" --msgbox "\
Install QDK manually from:
  https://github.com/qnap-dev/QDK2

Clone it and add bin/ to your PATH." 9 55
            return 1
            ;;
    esac
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
    screen_app_type || exit 0
    screen_binary_source || exit 0
    # After .deb extraction, fields may be auto-filled - let user confirm/edit
    screen_package_info || exit 0
    screen_author || exit 0
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
