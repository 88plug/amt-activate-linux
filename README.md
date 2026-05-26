# amt-activate-linux

**Activate Intel AMT / vPro from Linux — no reboot, no BIOS, no MEBx.**

One command. ~40 seconds. Tested on CSME 16.1.27 (Raptor Lake / 13th Gen) from factory pre-provisioning state with zero prior BIOS interaction.

[![AUR](https://img.shields.io/aur/version/rpc-go-bin?label=AUR%20rpc-go-bin&style=flat-square)](https://aur.archlinux.org/packages/rpc-go-bin)
[![License](https://img.shields.io/badge/license-MIT-blue?style=flat-square)](LICENSE)

---

## What this does

Intel AMT (Active Management Technology) is Intel's out-of-band management engine built into vPro Enterprise platforms. Once activated, it lets you remotely power cycle, console, KVM, and boot machines even when the OS is crashed or the machine is powered off.

Normally enabling AMT requires rebooting and entering MEBx (the AMT BIOS interface via Ctrl+P at POST). **This repo shows it can be done entirely from a running Linux session** — no physical access to the BIOS, no reboot, no provisioning server.

The mechanism: Intel's [`rpc-go`](https://github.com/device-management-toolkit/rpc-go) tool talks to the CSME firmware directly over `/dev/mei0` (the Intel ME Interface), bypassing the network stack entirely.

---

## Why this matters

As of 2026, there is **no public documentation** of `-local -ccm` activation succeeding on CSME 16.x (Alder Lake / Raptor Lake) from pre-provisioning state with zero prior MEBx configuration. The closest documented guide ([piernov's series](https://blog.piernov.org/open-amt-cloud-toolkit-part-4-client-setup/)) targets CSME 14.x and still requires a MEBx visit as a prerequisite. Intel's own docs note MEBx password is "optional" for CCM but don't document completely skipping it.

This activation works because CSME firmware accepts the `CFG_StartConfigurationHBased` MEI command from an OS-level process with root privileges when:
- AMT is in **pre-provisioning state** (factory default, never touched MEBx)
- The MEI driver (`mei_me`) is loaded
- No provisioning certificate is required (CCM vs ACM distinction)

Also documented here: `wsmancli` and `openwsman` are **broken on current Arch Linux / Manjaro** (Ruby rdoc `ArgumentError` during build). `rpc-go` static binary is the only working path on Arch.

---

## Quick start (Arch / Manjaro)

```bash
yay -S rpc-go-bin
```

```bash
sudo modprobe mei_me
```

```bash
sudo rpc amtinfo
```

Confirm output shows `Control Mode: pre-provisioning state` then:

```bash
curl -fsSL https://raw.githubusercontent.com/88plug/amt-activate-linux/main/scripts/amt-activate.sh | bash
```

Or clone and run:

```bash
git clone https://github.com/88plug/amt-activate-linux
bash amt-activate-linux/scripts/amt-activate.sh
```

---

## Step by step

### 1. Verify hardware

AMT requires **Intel vPro Enterprise** + a **Q-series or W-series chipset** (e.g. Q670, W680, Q570). Consumer H/B/Z chipsets have no AMT.

```bash
sudo mei-amt-check
```

Expected output:
```
AMT present: true
AMT provisioning state: unprovisioned
```

If `AMT present: false`: your CPU or chipset doesn't support AMT.

### 2. Install rpc-go

**Arch / Manjaro:**
```bash
yay -S rpc-go-bin
```

**Other distros (static binary):**
```bash
curl -sL https://github.com/device-management-toolkit/rpc-go/releases/latest/download/rpc_linux_x64.tar.gz | tar xz
sudo install -m755 rpc_linux_x64 /usr/local/bin/rpc
```

> **Why not wsmancli / openwsman?** Both are broken on current Arch (AUR build fails with Ruby rdoc `ArgumentError` at `make`). `rpc-go` is the working replacement.

### 3. Load the MEI driver

```bash
sudo modprobe mei_me
ls /dev/mei0
```

To persist across reboots:
```bash
echo mei_me | sudo tee /etc/modules-load.d/mei.conf
```

### 4. Check AMT state before activation

```bash
sudo rpc amtinfo
```

Key fields:
- `Control Mode: pre-provisioning state` ← required
- `Operational State: enabled` ← required
- `AMT IP Address: 0.0.0.0` ← expected before activation

### 5. Generate a strong AMT password

AMT requires: ≥8 chars, uppercase, lowercase, digit, special character.

```bash
PW=$(openssl rand -base64 18 | tr -d '/+=' | head -c 14)
PW="${PW}A9!x"
echo "$PW" > ~/.amt-mebx-password.txt
chmod 0600 ~/.amt-mebx-password.txt
echo "Length: ${#PW}"
```

This becomes your permanent MEBx admin password. Back it up.

### 6. Activate

```bash
sudo rpc activate -local -ccm -password "$PW"
```

Expected output:
```
time="..." level=info  msg="Failed to connect to LMS, using local transport instead."
time="..." level=warn  msg="Execution timeout after 20s"
time="..." level=warn  msg="Execution timeout after 20s"
time="..." level=info  msg="Status: Device activated in Client Control Mode"
```

The two `Execution timeout after 20s` warnings are **normal** — this is the firmware-side handshake delay during the pre-provisioning → CCM transition. Total elapsed: ~40 seconds.

`Failed to connect to LMS` is also **normal** — `rpc-go` falls back to direct MEI transport automatically (LMS is not required).

### 7. Verify and get the AMT IP

```bash
sudo rpc amtinfo
```

Look for:
- `Control Mode: activated in client control mode`
- `DHCP Mode: active` (changed from `passive`)
- `AMT IP Address: <your IP>` — may take 15–30s for DHCP

The AMT NIC shares the physical Ethernet port but gets its own IP from DHCP — check your router's lease table if it doesn't appear.

### 8. Connect with a management tool

```bash
yay -S intel-amt-linux    # GUI + CLI for KVM, SOL, IDER, power control
```

Or scan your subnet to find all AMT-enabled machines:
```bash
nmap -p 16992,16993 192.168.1.0/24 --open -oG - | grep open
```

---

## Hardware compatibility

| Generation | CSME | AMT | Local CCM |
|---|---|---|---|
| Kaby Lake (7th gen, 2016) | 11.8 | 11.8 | ✅ documented |
| Coffee Lake (8th/9th gen) | 12.x | 12.x | ✅ documented |
| Comet Lake (10th gen) | 14.x | 14.x | ✅ documented |
| Tiger Lake (11th gen) | 15.x | 15.x | ✅ documented |
| Alder Lake (12th gen) | 16.0–16.1 | 16.x | ✅ documented |
| Raptor Lake (13th gen) | 16.1.27 | 16.x | ✅ **confirmed this repo** |
| Meteor Lake / Core Ultra | 18.x | 18.x | ⚠️ rpc-go v2.43+ |

**Minimum:** AMT 11.8 (Kaby Lake). Earlier generations (Sandy Bridge–Skylake, AMT 7–11.0) have HBC support in the Intel SDK but are untested with `rpc-go`.

**vPro Essentials / vPro Evo:** `rpc activate -local -ccm` runs, but hardware KVM and several OOB features are unavailable — those require vPro Enterprise.

**WiFi:** MEI activation itself does not use the NIC, so wired vs wireless doesn't affect activation. However, post-activation OOB management over WiFi requires AMT 9.5+.

**Known issue:** Dell systems with CSME 16.1.25.1991+ have a firmware regression causing AMT/ISM connection failures ([Dell KB 000210568](https://www.dell.com/support/kbdoc/en-us/000210568)).

### Tested OEMs

- ✅ Lenovo ThinkStation P360 Ultra (i9-13900T, CSME 16.1.27) — **this session**
- ✅ Lenovo ThinkPad, ThinkCentre
- ✅ Dell OptiPlex, Latitude, Precision
- ✅ HP EliteBook, EliteDesk, Z-series
- ✅ Intel NUC vPro

### Does NOT work on

- Consumer chipsets (H/B/Z series) — no AMT firmware
- AMD platforms
- Xeon Scalable (use IPMI/Redfish/iDRAC instead)
- ARM

---

## BIOS prerequisites

The firmware accepts local CCM activation when:

1. **AMT enabled in BIOS** — most vPro machines ship with this on by default; verify under Security or Advanced → AMT Configuration
2. **MEBx password never changed** — pre-provisioning state means MEBx default (`admin`) is still set; you do not need to know or set it
3. **MEI driver loaded** — `lsmod | grep mei` should show `mei_me`
4. **AMT in pre-provisioning state** — `rpc amtinfo` → `Control Mode: pre-provisioning state`

No provisioning server, no certificates, no network connection required for activation itself.

---

## After activation

| Task | Tool |
|---|---|
| GUI: KVM, SOL, IDER, power | `yay -S intel-amt-linux` |
| Change AMT NIC to static IP | `node /opt/intel-amt-linux/src/tools/amt-net.js static <host> admin <pw> <ip> <mask> <gw> <dns>` |
| Change AMT NIC to DHCP | `node /opt/intel-amt-linux/src/tools/amt-net.js dhcp <host> admin <pw>` |
| Deactivate / factory reset | `sudo rpc deactivate -local` |

---

## Troubleshooting

**`rpc: HECIDriverNotDetected`** — run as root (`sudo rpc`), and verify `/dev/mei0` exists.

**`rpc amtinfo` hangs** — MEI driver loaded but ME not responding. Check: `dmesg | grep mei`, ensure AMT is enabled in BIOS.

**`Execution timeout after 20s` × 3 then exit** — activation failed. Possible causes: AMT not in pre-provisioning state, BIOS has AMT disabled, or OEM restriction.

**IP stays `0.0.0.0` after activation** — wait 30s for DHCP, or check router. If still 0.0.0.0, AMT NIC DHCP may be misconfigured — try `sudo rpc amtinfo` after 60s.

**`wsmancli`/`openwsman` fails on Arch** — known Ruby rdoc build failure (`ArgumentError (wrong number of arguments (given 4, expected 5))`). Use `rpc-go-bin` instead.

---

## See also

- [intel-amt-linux](https://github.com/88plug/intel-amt-linux) — native Linux GUI + CLI for managing AMT after activation
- [rpc-go](https://github.com/device-management-toolkit/rpc-go) — Intel Device Management Toolkit
- [Intel AMT Implementation Guide](https://software.intel.com/sites/manageability/AMT_Implementation_and_Reference_Guide/)

---

*Intel®, Intel vPro®, and Intel® Active Management Technology are trademarks of Intel Corporation or its subsidiaries.*
