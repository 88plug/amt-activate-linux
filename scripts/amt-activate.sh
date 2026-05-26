#!/usr/bin/env bash
# amt-activate — Enable Intel AMT in Client Control Mode from Linux
# No MEBx visit, no reboot, no provisioning server required.
# Uses rpc-go (Intel Device Management Toolkit) via /dev/mei0.
#
# Requirements:
#   - Intel vPro Enterprise CPU + Q/W-series chipset (AMT 11.8+)
#   - AMT enabled in BIOS (but never configured/visited MEBx)
#   - MEI driver loaded: modprobe mei_me
#   - rpc installed: yay -S rpc-go-bin
#   - Run as normal user (will sudo for rpc calls)

set -euo pipefail

PW_FILE="${HOME}/.amt-mebx-password.txt"
LOG_FILE="/tmp/amt-activate.log"

RED=$'\e[31m' GRN=$'\e[32m' YLW=$'\e[33m' RST=$'\e[0m'
err()  { echo "${RED}ERROR:${RST} $*" >&2; exit 1; }
info() { echo "${GRN}==>${RST} $*"; }
warn() { echo "${YLW}WARN:${RST} $*"; }

# ── prerequisites ──────────────────────────────────────────────────────────
[ -e /dev/mei0 ] || err "/dev/mei0 not found — run: sudo modprobe mei_me"
command -v rpc &>/dev/null || err "'rpc' not found — install rpc-go-bin: yay -S rpc-go-bin"
command -v openssl &>/dev/null || err "'openssl' not found — install openssl"

# ── check current AMT state ────────────────────────────────────────────────
info "Checking AMT state..."
AMT_INFO=$(sudo rpc amtinfo 2>&1) || err "rpc amtinfo failed — is /dev/mei0 accessible?"
echo "$AMT_INFO"
echo ""

if echo "$AMT_INFO" | grep -qi "activated in client control mode"; then
    info "AMT already activated in CCM. Nothing to do."
    AMT_IP=$(echo "$AMT_INFO" | grep "AMT IP" | head -1 | awk '{print $NF}')
    echo "AMT IP: ${AMT_IP:-check router DHCP table}"
    exit 0
fi

echo "$AMT_INFO" | grep -qi "pre-provisioning" || \
    err "AMT not in pre-provisioning state (may already be configured differently)"

# ── password ───────────────────────────────────────────────────────────────
if [ -f "$PW_FILE" ]; then
    warn "Password file already exists at $PW_FILE"
    read -rp "  Use existing password? [Y/n] " yn
    if [[ "${yn:-y}" =~ ^[Nn] ]]; then
        PW=$(openssl rand -base64 18 | tr -d '/+=' | head -c 14)
        PW="${PW}A9!x"
        echo "$PW" > "$PW_FILE"
        chmod 0600 "$PW_FILE"
    else
        PW=$(cat "$PW_FILE")
    fi
else
    # 18 chars: 14 random alphanumeric + guaranteed upper + digit + special
    PW=$(openssl rand -base64 18 | tr -d '/+=' | head -c 14)
    PW="${PW}A9!x"
    echo "$PW" > "$PW_FILE"
    chmod 0600 "$PW_FILE"
fi

info "AMT password saved to $PW_FILE (mode 0600, ${#PW} chars)"
info "This becomes your MEBx admin password — back it up."
echo ""

# ── activate ───────────────────────────────────────────────────────────────
info "Activating Intel AMT — Client Control Mode..."
echo "  Two 'Execution timeout after 20s' warnings are normal."
echo "  Total time: ~40 seconds on CSME 16.x."
echo ""

sudo rpc activate -local -ccm -password "$PW" 2>&1 | tee "$LOG_FILE"
echo ""

if grep -q "Device activated in Client Control Mode" "$LOG_FILE"; then
    info "Activation successful."
else
    err "Activation may have failed — check $LOG_FILE"
fi

# ── verify ─────────────────────────────────────────────────────────────────
info "Verifying state (AMT IP may need 15-30s for DHCP)..."
sleep 5
sudo rpc amtinfo 2>&1

echo ""
info "Done. To find your AMT IP:"
echo "  sudo rpc amtinfo | grep 'AMT IP'"
echo "  nmap -p 16992,16993 \$(ip route | awk '/default/{print \$3}' | sed 's/\.[0-9]*$/.0/')/24 --open -oG - | grep open"
echo ""
echo "Next: connect with intel-amt-linux (yay -S intel-amt-linux)"
