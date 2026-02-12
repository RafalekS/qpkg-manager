#!/bin/bash
# ============================================================================
# Build Gitea QPKG on QNAP NAS
#
# Usage:
#   1. Copy this entire qpkg/ folder to the NAS
#   2. SSH into NAS as admin/root
#   3. cd into the qpkg/ folder
#   4. Run: sudo bash build-qpkg.sh
#
# Requires: QDK installed (confirmed at /share/CACHEDEV1_DATA/.qpkg/QDK)
# ============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok()   { echo -e "${GREEN}[  OK ]${NC} $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1"; }
msg()  { echo -e "${YELLOW}[BUILD]${NC} $1"; }

# Check we're on QNAP
if [ ! -f /sbin/getcfg ]; then
    err "This script must run on the QNAP NAS"
    exit 1
fi

# Check QDK is installed
QBUILD=$(which qbuild 2>/dev/null)
if [ -z "$QBUILD" ]; then
    # Try common QDK paths
    for path in /share/CACHEDEV1_DATA/.qpkg/QDK/bin/qbuild /opt/QDK/bin/qbuild; do
        if [ -x "$path" ]; then
            QBUILD="$path"
            break
        fi
    done
fi

if [ -z "$QBUILD" ] || [ ! -x "$QBUILD" ]; then
    err "qbuild not found. Is QDK installed?"
    err "Install QDK from App Center first."
    exit 1
fi

ok "Found qbuild: ${QBUILD}"

# Check binary exists
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

if [ ! -f "x86_64/gitea" ]; then
    # Try to use existing binary from home dir
    if [ -f "/share/homes/rls1203/gitea" ]; then
        msg "Copying binary from /share/homes/rls1203/gitea ..."
        mkdir -p x86_64
        cp /share/homes/rls1203/gitea x86_64/gitea
        chmod +x x86_64/gitea
        ok "Binary copied"
    else
        err "No gitea binary found in x86_64/ or /share/homes/rls1203/"
        exit 1
    fi
fi

# Verify required files
for f in qpkg.cfg package_routines shared/Gitea.sh; do
    if [ ! -f "$f" ]; then
        err "Missing required file: $f"
        exit 1
    fi
done

# Set permissions
chmod +x shared/Gitea.sh
chmod +x package_routines
chmod +x x86_64/gitea

msg "Building QPKG..."
echo ""

# Build
$QBUILD

echo ""
if [ -d "build" ]; then
    ok "Build complete! Output:"
    ls -lh build/*.qpkg 2>/dev/null
    echo ""
    msg "To install:"
    echo "  Method 1: QTS App Center > Install Manually > select the .qpkg file"
    echo "  Method 2: sh build/Gitea_*.qpkg"
    echo ""
    msg "After install:"
    echo "  1. Enable Gitea in App Center"
    echo "  2. Open http://192.168.0.166:3004/"
    echo "  3. Complete the web installer"
else
    err "Build directory not found - check output above for errors"
    exit 1
fi
