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

PW_FILE="${AMT_PW_FILE:-${HOME}/.amt-mebx-password.txt}"
LOG_FILE="/tmp/amt-activate.log"
VERSION="0.2.0"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<EOF
amt-activate ${VERSION} — Activate Intel AMT in Client Control Mode from Linux

Usage: sudo amt-activate [--auto-resume | --resume]

Default (no flags) is interactive — it will:
  1. Check /dev/mei0 and rpc binary
  2. Run 'rpc amtinfo' to confirm pre-provisioning state
  3. Generate or reuse password at ~/.amt-mebx-password.txt
  4. Run 'rpc activate -local -ccm' and tee output to ${LOG_FILE}
  5. Verify activation and report AMT IP

If the firmware refuses with AMT_STATUS_NOT_PERMITTED (manageability
disabled in BIOS), amt-activate offers to stage the BIOS toggle from
Linux and install a one-shot systemd unit so activation completes
automatically at the next boot — your only action is the reboot.

Flags:
  --auto-resume   Non-interactive: on NOT_PERMITTED, stage the BIOS
                  toggle and enable the resume unit without prompting
  --resume        Used by the systemd unit at boot: reuse the saved
                  password, activate, disable the unit on success

Docs:    https://github.com/88plug/amt-activate-linux
Wiki:    https://github.com/88plug/amt-activate-linux/wiki
Issues:  https://github.com/88plug/amt-activate-linux/issues
EOF
    exit 0
fi

if [[ "${1:-}" == "--version" || "${1:-}" == "-v" ]]; then
    echo "amt-activate ${VERSION}"
    exit 0
fi

MODE="interactive"
case "${1:-}" in
    --resume)      MODE="resume" ;;
    --auto-resume) MODE="auto" ;;
esac

RED=$'\e[31m' GRN=$'\e[32m' YLW=$'\e[33m' RST=$'\e[0m'
err()  { echo "${RED}ERROR:${RST} $*" >&2; exit 1; }
info() { echo "${GRN}==>${RST} $*"; }
warn() { echo "${YLW}WARN:${RST} $*"; }

# Stage the BIOS manageability toggle from Linux (Lenovo think-lmi).
# Attribute name varies by platform: ManageabilityControl (P3 Ultra 30HA),
# AMTControl (T14 Gen 2+, X1 Gen 9+, M90q Gen 2+). Applies at next POST.
stage_bios_toggle() {
    local base=/sys/class/firmware-attributes/thinklmi/attributes attr
    for attr in ManageabilityControl AMTControl; do
        if [ -e "$base/$attr/current_value" ]; then
            info "Staging BIOS toggle: $attr=Enabled (applies at next POST)"
            echo Enabled | sudo tee "$base/$attr/current_value" >/dev/null && return 0
        fi
    done
    warn "No Lenovo think-lmi AMT attribute found."
    echo "  Dell:  sudo cctk --AdvancedAmt=Enable"
    echo "  Other: enable AMT in BIOS setup once, then re-run amt-activate"
    return 1
}

# Install a self-disabling one-shot unit so activation resumes at next boot.
install_resume_unit() {
    local self; self=$(readlink -f "$0")
    sudo tee /etc/systemd/system/amt-autoactivate.service >/dev/null <<UNIT
[Unit]
Description=Resume Intel AMT activation after BIOS manageability toggle applies
After=multi-user.target

[Service]
Type=oneshot
Environment=AMT_PW_FILE=${PW_FILE}
ExecStart=${self} --resume
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
UNIT
    sudo systemctl daemon-reload
    sudo systemctl enable amt-autoactivate.service
    info "amt-autoactivate.service enabled — reboot to complete activation automatically."
}

disable_resume_unit() {
    sudo systemctl disable amt-autoactivate.service 2>/dev/null || true
}

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
    [[ "$MODE" == "resume" ]] && disable_resume_unit
    exit 0
fi

echo "$AMT_INFO" | grep -qi "pre-provisioning" || \
    err "AMT not in pre-provisioning state (may already be configured differently)"

# ── password ───────────────────────────────────────────────────────────────
if [[ "$MODE" != "interactive" ]]; then
    # resume/auto: never prompt — reuse the saved password or create one
    if [ -f "$PW_FILE" ]; then
        PW=$(cat "$PW_FILE")
    else
        PW=$(openssl rand -base64 18 | tr -d '/+=' | head -c 14)
        PW="${PW}A9!x"
        echo "$PW" > "$PW_FILE"
        chmod 0600 "$PW_FILE"
    fi
elif [ -f "$PW_FILE" ]; then
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

# rpc exits non-zero on refusal (e.g. Error 4 AmtNotReady) — '|| true' keeps
# set -euo pipefail from killing the script before the handlers below run.
sudo rpc activate -local -ccm -password "$PW" 2>&1 | tee "$LOG_FILE" || true
echo ""

if grep -q "Device activated in Client Control Mode" "$LOG_FILE"; then
    info "Activation successful."
    [[ "$MODE" == "resume" ]] && disable_resume_unit
elif grep -qE "AMT_STATUS_NOT_PERMITTED|AmtNotReady" "$LOG_FILE"; then
    warn "Firmware refused activation: manageability is disabled in BIOS."
    if [[ "$MODE" == "resume" ]]; then
        # Toggle still not live (or staging never happened) — retry next boot.
        warn "Leaving amt-autoactivate.service enabled for next boot."
        exit 1
    fi
    if [[ "$MODE" == "auto" ]]; then
        stage_bios_toggle && install_resume_unit && exit 0
        exit 1
    fi
    if [ -t 0 ]; then
        read -rp "  Stage the BIOS toggle now and finish automatically after reboot? [Y/n] " yn
        if [[ ! "${yn:-y}" =~ ^[Nn] ]]; then
            stage_bios_toggle && install_resume_unit && exit 0
        fi
    fi
    echo "  Manual path — stage the toggle, reboot once, re-run amt-activate:"
    echo "    Lenovo:  ls /sys/class/firmware-attributes/thinklmi/attributes/ | grep -iE 'amt|manage'"
    echo "             echo Enabled | sudo tee /sys/class/firmware-attributes/thinklmi/attributes/ManageabilityControl/current_value"
    echo "    Dell:    sudo cctk --AdvancedAmt=Enable"
    echo "  The setting takes effect at next POST."
    exit 1
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
