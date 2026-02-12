#!/bin/bash
# ============================================================================
# QNAP Recon Script - Gather system info for Gitea setup
# Run as root on QNAP NAS: sudo ./qnap-recon.sh
# Output saved to: /share/homes/rls1203/gitea-recon.txt
# ============================================================================

OUTPUT="/share/homes/rls1203/gitea-recon.txt"

# Ensure running as root
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Run as root (sudo ./qnap-recon.sh)"
    exit 1
fi

# Start clean
> "$OUTPUT"

section() { echo -e "\n========== $1 ==========" >> "$OUTPUT"; }
run()     { echo "$ $1" >> "$OUTPUT"; eval "$1" >> "$OUTPUT" 2>&1; echo "" >> "$OUTPUT"; }

echo "Gathering QNAP system info..."

# --- System ---
section "SYSTEM"
run "uname -a"
run "cat /etc/version 2>/dev/null || echo 'no /etc/version'"
run "cat /etc/platform.conf 2>/dev/null || echo 'no platform.conf'"
run "getcfg System 'Model Name' -f /etc/config/uLinux.conf 2>/dev/null || echo 'getcfg not available'"
run "getcfg System 'Firmware Version' -f /etc/config/uLinux.conf 2>/dev/null"
run "cat /etc/QTS_Build_version 2>/dev/null || echo 'no QTS_Build_version'"
run "hostname"
run "uptime"

# --- CPU/Memory/Disk ---
section "HARDWARE"
run "cat /proc/cpuinfo | head -20"
run "free -h"
run "df -h"

# --- Users ---
section "USER INFO"
run "id rls1203"
run "grep rls1203 /etc/passwd"
run "groups rls1203"
run "ls -la /share/homes/rls1203/"
run "cat /etc/shells 2>/dev/null"

# --- Network ---
section "NETWORK"
run "ip addr show | grep 'inet '"
run "hostname -I 2>/dev/null || echo 'hostname -I not available'"

# --- Port check ---
section "PORT USAGE"
run "netstat -tlnp 2>/dev/null | head -30 || ss -tlnp 2>/dev/null | head -30"
echo "Port 3004 specifically:" >> "$OUTPUT"
run "netstat -tlnp 2>/dev/null | grep ':3004' || ss -tlnp 2>/dev/null | grep ':3004' || echo 'Port 3004 is FREE'"

# --- Init system ---
section "INIT SYSTEM"
run "which systemctl 2>/dev/null && systemctl --version 2>/dev/null || echo 'No systemd'"
run "which initctl 2>/dev/null || echo 'No upstart'"
run "ls /etc/init.d/ 2>/dev/null | head -30"
run "ls /etc/rcS.d/ 2>/dev/null | head -20"
run "ls /etc/rc.d/ 2>/dev/null | head -20"
run "cat /proc/1/comm 2>/dev/null"
run "ps -p 1 -o comm= 2>/dev/null"

# --- Autorun.sh ---
section "AUTORUN.SH"
run "which hal_app || ls /sbin/hal_app 2>/dev/null || echo 'hal_app NOT found'"
# Try to mount and read existing autorun.sh
if [ -f /sbin/hal_app ]; then
    BOOT_DEV=$(/sbin/hal_app --get_boot_pd port_id=0)6
    echo "Boot device: $BOOT_DEV" >> "$OUTPUT"
    mount -t ext2 "$BOOT_DEV" /tmp/config 2>/dev/null
    if [ -f /tmp/config/autorun.sh ]; then
        echo "Existing autorun.sh contents:" >> "$OUTPUT"
        cat /tmp/config/autorun.sh >> "$OUTPUT"
    else
        echo "No autorun.sh exists yet" >> "$OUTPUT"
    fi
    echo "" >> "$OUTPUT"
    echo "Config partition contents:" >> "$OUTPUT"
    ls -la /tmp/config/ >> "$OUTPUT" 2>&1
    umount /tmp/config 2>/dev/null
else
    echo "Cannot check - hal_app missing" >> "$OUTPUT"
fi

# --- QTS autorun setting ---
section "QTS AUTORUN SETTING"
run "getcfg Misc 'Run Autorun' -f /etc/config/uLinux.conf 2>/dev/null || echo 'Cannot read autorun setting'"

# --- Crontab ---
section "CRONTAB"
echo "root crontab:" >> "$OUTPUT"
run "crontab -l 2>/dev/null || echo 'No root crontab'"
echo "rls1203 crontab:" >> "$OUTPUT"
run "crontab -l -u rls1203 2>/dev/null || echo 'No rls1203 crontab'"
echo "System crontab:" >> "$OUTPUT"
run "cat /etc/crontab 2>/dev/null | head -30"
run "ls /etc/cron.d/ 2>/dev/null"

# --- Installed packages / tools ---
section "AVAILABLE TOOLS"
for cmd in git wget curl nohup screen tmux bash sh sqlite3 openssl gpg; do
    loc=$(which "$cmd" 2>/dev/null)
    if [ -n "$loc" ]; then
        ver=$("$cmd" --version 2>/dev/null | head -1)
        echo "$cmd: $loc ($ver)" >> "$OUTPUT"
    else
        echo "$cmd: NOT FOUND" >> "$OUTPUT"
    fi
done

# --- Package managers ---
section "PACKAGE MANAGERS"
run "which opkg 2>/dev/null && opkg list-installed 2>/dev/null | wc -l && echo 'packages installed via opkg' || echo 'No opkg'"
run "which entware 2>/dev/null || echo 'No entware command'"
run "ls /opt/bin/ 2>/dev/null | head -20 || echo 'No /opt/bin/'"

# --- QNAP apps / Malware Remover ---
section "QNAP APPS"
run "ls /share/CACHEDEV1_DATA/.qpkg/ 2>/dev/null || echo 'No .qpkg directory found'"
echo "Malware Remover:" >> "$OUTPUT"
run "ls /share/CACHEDEV1_DATA/.qpkg/MalwareRemover/ 2>/dev/null || echo 'Malware Remover not found in .qpkg'"

# --- Existing Gitea ---
section "EXISTING GITEA"
run "pgrep -a gitea 2>/dev/null || echo 'No gitea process running'"
run "find /share/homes/rls1203 -name 'gitea' -type f 2>/dev/null"
run "find /share/homes/rls1203 -name 'app.ini' 2>/dev/null"
run "ls -la /share/homes/rls1203/gitea 2>/dev/null || echo 'No gitea binary in home'"
run "ls -la /share/homes/rls1203/gitea-server/ 2>/dev/null || echo 'No gitea-server directory'"
run "ls -la /share/homes/rls1203/custom/ 2>/dev/null || echo 'No custom directory'"

# --- Filesystem ---
section "FILESYSTEM LAYOUT"
run "ls -la /share/"
run "ls -la /share/homes/"
run "mount | grep share"
run "cat /etc/fstab 2>/dev/null | grep -v '^#'"

# --- Running services ---
section "RUNNING SERVICES (port listeners)"
run "netstat -tlnp 2>/dev/null || ss -tlnp 2>/dev/null"

# --- Docker ---
section "DOCKER"
run "which docker 2>/dev/null && docker --version 2>/dev/null || echo 'No docker'"
run "docker ps 2>/dev/null | head -20 || echo 'Docker not running or not available'"

# --- Done ---
echo ""
echo "============================================"
echo "Done! Output saved to: $OUTPUT"
echo "Size: $(wc -c < "$OUTPUT") bytes"
echo "============================================"
echo ""
echo "Transfer this file back with:"
echo "  scp rls1203@192.168.0.166:~/gitea-recon.txt ."
