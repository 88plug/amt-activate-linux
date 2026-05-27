# amt-activate-linux

**Activate Intel AMT / vPro from Linux — no reboot, no BIOS, no MEBx.**

One command. ~40 seconds on CSME 16.1+. Confirmed working on Lenovo ThinkStation P360 Ultra (Raptor Lake, CSME 16.1.27) from factory pre-provisioning state with zero prior BIOS interaction.

[![AUR intel-amt-activate](https://img.shields.io/aur/version/intel-amt-activate?label=AUR%20intel-amt-activate&style=flat-square)](https://aur.archlinux.org/packages/intel-amt-activate)
[![AUR rpc-go-bin](https://img.shields.io/aur/version/rpc-go-bin?label=AUR%20rpc-go-bin&style=flat-square)](https://github.com/88plug/rpc-go-bin)
[![License](https://img.shields.io/badge/license-MIT-blue?style=flat-square)](LICENSE)
[![rpc-go-bin repo](https://img.shields.io/badge/repo-rpc--go--bin-181717?style=flat-square&logo=github)](https://github.com/88plug/rpc-go-bin)
[![intel-amt-linux repo](https://img.shields.io/badge/repo-intel--amt--linux-181717?style=flat-square&logo=github)](https://github.com/88plug/intel-amt-linux)

*Tested end-to-end: push to main → auto-tag → AUR publish ≤ 60s, fully PAT-free pipeline.*

---

## What this does

Intel AMT (Active Management Technology) is the out-of-band management engine built into Intel vPro Enterprise platforms. Once activated, you can remotely power cycle, console (SOL), KVM, and boot machines even when the OS is crashed or the machine is powered off.

The standard guidance everywhere on the internet is: **reboot into MEBx (Ctrl+P at POST), set the MEBx password, enable AMT, configure provisioning**. That guidance is wrong for the modern Linux path. None of it is required.

This repo documents what Intel's own documentation buries in SDK PDFs: that the CSME firmware accepts a `CFG_StartConfigurationHBased` MEI command from an OS-level root process and transitions directly from `pre-provisioning` to `activated in client control mode`. No reboot. No BIOS visit. No Ctrl+P. No provisioning server.

---

## Why this matters

vPro Enterprise ships in every business-class Intel machine since 2016 — millions of ThinkPads, OptiPlexes, EliteBooks, NUC Pros, and Precision/Z workstations. The standard "reboot and enter MEBx" guidance forces a truck roll for every machine that needs OOB management. **This entire flow can be replaced with one SSH session + one command.**

As of May 2026, exhaustive search across Reddit, HackerNews, GitHub, ServeTheHome, Intel community forums, and tech blogs found **zero public walkthroughs** of `rpc-go -local -ccm` on Linux from pre-provisioning with no MEBx — only frustrated homelab threads asking how to do it. Intel's own engineers have filed bugs against this exact path (rpc-go issues #1082, #1119, #1208), confirming the doc gap.

This repo also documents that our **40-second activation on CSME 16.1.27 is significantly faster** than Intel's own rpc-go issue #1119 reports (5-6 min expected on AMT 16, 15 min on AMT 18). Worth reporting back upstream.

---

## Quick start (Arch / Manjaro)

```bash
yay -S intel-amt-activate
```

```bash
sudo modprobe mei_me
```

```bash
sudo amt-activate
```

That's it. Tool checks state, generates a strong password, activates, verifies. ~40-90 seconds total.

---

## Manual flow (any distro)

```bash
# 1. Install rpc-go
curl -sL https://github.com/device-management-toolkit/rpc-go/releases/latest/download/rpc_linux_x64.tar.gz | tar xz
sudo install -m755 rpc_linux_x64 /usr/local/bin/rpc

# 2. Load MEI driver
sudo modprobe mei_me

# 3. Verify pre-provisioning state
sudo rpc amtinfo | grep "Control Mode"
# Expected: Control Mode : pre-provisioning state

# 4. Generate strong password (≥8 chars, upper+lower+digit+special)
PW=$(openssl rand -base64 18 | tr -d '/+=' | head -c 14)
PW="${PW}A9!x"
echo "$PW" > ~/.amt-mebx-password.txt
chmod 0600 ~/.amt-mebx-password.txt

# 5. Activate
sudo rpc activate -local -ccm -password "$PW"

# 6. Verify and get AMT IP (may need 15-30s for DHCP)
sudo rpc amtinfo | grep -E "Control Mode|AMT IP"
```

---

## Expected output during activation

```
time="..." level=info  msg="Failed to connect to LMS, using local transport instead."
time="..." level=warn  msg="Execution timeout after 20s"
time="..." level=warn  msg="Execution timeout after 20s"
time="..." level=info  msg="Status: Device activated in Client Control Mode"
```

All three messages are **normal**:
- `Failed to connect to LMS` — `rpc-go` falls back to direct MEI transport. LMS is not required for `-local -ccm` on AMT 11–18
- Two `Execution timeout after 20s` — firmware-side handshake delays during `pre-provisioning → CCM` transition
- Final `Device activated in Client Control Mode` — success

After activation, `rpc amtinfo` shows `DHCP Mode` flipping from `passive` → `active`. The AMT NIC then requests a DHCP lease (separate from the OS IP, same physical port via MAC multiplexing).

---

## Hardware compatibility matrix

### AMT version × CSME firmware

| Generation | Year | CSME | AMT | Local CCM via rpc-go |
|---|---|---|---|---|
| Kaby Lake | 2016 | 11.8 | 11.8 | ✅ supported |
| Coffee Lake | 2017–18 | 12.x | 12.x | ✅ supported |
| Whiskey/Comet Lake | 2019–20 | 14.x | 14.x | ✅ supported |
| Tiger Lake | 2020 | 15.x | 15.x | ✅ supported |
| Alder Lake | 2021 | 16.0–16.1 | 16.x | ✅ supported (TLS-only post-activation on 16.1+) |
| Raptor Lake | 2022 | 16.1.27 | 16.x | ✅ **confirmed this repo, 41s** |
| Meteor Lake / Core Ultra | 2023+ | 18.x | 18.x | ⚠️ slow (15 min per rpc-go #1119) |
| Lunar/Arrow Lake | 2024+ | 19.x | 19.x | ❌ **LMS now required** (rpc-go #1208) |

**Minimum:** AMT 11.8 (Kaby Lake, 2016). Earlier generations (Sandy–Skylake, AMT 7–11.0) have HBC in the Intel SDK but `rpc-go` isn't tested against them.

**AMT 19+ regression:** Intel removed the LME interface for non-LMS provisioning in CSME 19.x. Local CCM activation now requires LMS daemon running. Workaround: install Intel LMS (see [intel-amt-linux](https://github.com/88plug/intel-amt-linux) which ships LMS in Docker).

### Per-vendor compatibility

#### Lenovo

| Line | Models | Local CCM | Notes |
|---|---|---|---|
| **ThinkPad** | T480, T490/T490s, T14 Gen 1–5, T16, X1 Carbon Gen 6+, X280/X390/X13, P14s/P15s/P16s | ✅ vPro Enterprise SKUs only | i5/i7-vPro suffix required; vPro Essentials SKUs lack AMT |
| **ThinkPad L-series** | L13, L14, L15 | ❌ | vPro Essentials only — no AMT firmware |
| **ThinkCentre** | M70q/s/t, M80q/s/t, M90q/s/t Gen 1–6, M90n Nano | ✅ | M75/M9 AMD variants excluded |
| **ThinkStation** | P330, P340, P350, P360, P3 Ultra/Tower/Tiny, P520, P720 | ✅ | **P360/P3 Ultra confirmed in this repo** |
| **ThinkStation P620** | (AMD Threadripper Pro) | ❌ | AMD platform — no AMT |

**Lenovo BIOS toggle from Linux:** `think-lmi` exposes `/sys/class/firmware-attributes/thinklmi/attributes/AMTControl` on T14 Gen 2+, X1 Gen 9+, M90q Gen 2+, P3 Ultra. Set to `Enable`, save, then `rpc activate`. No BIOS visit required if your platform exposes this attribute.

#### Dell

| Line | Models | Local CCM | Notes |
|---|---|---|---|
| **OptiPlex** | 5000/7000/9000 Tower, SFF, Micro, AIO | ✅ | 3000-series is consumer Q-suffix, NOT vPro Enterprise |
| **Latitude** | 5330, 5430/5431, 5530/5531, 5350/5450/5550, 7230/7330/7430/7530, 9330/9430 | ✅ vPro Enterprise SKUs only | Lower trims and AMD models are vPro Essentials — no AMT |
| **Precision Mobile** | 3470/3571, 5470/5570/5770, 7670/7770 | ✅ | |
| **Precision Tower** | 3260 Compact, 3460 SFF, 3660 Tower | ✅ | Dell's modern AMT workstation line |

**Dell BIOS toggle from Linux:** `cctk` (Dell Command Configure Toolkit) — install via Dell's Linux repo, then:
```bash
sudo cctk --AdvancedAmt=Enable
sudo cctk --setuppwd=<bios-admin-pwd>  # required if not set
# reboot, then: sudo amt-activate
```

**Dell regression (KB 000210568):** CSME 16.1.25.1991+ removed non-TLS port 16992 on Latitude 5330–9430, OptiPlex 5000/7000 MFF, 5400/7400 AIO, Precision 3460/3470/3570/3571/3660/5470–7770, XPS 9315/9320/9520/9720. Activation still works; post-activation management requires TLS (port 16993).

#### HP

| Line | Models | Local CCM |
|---|---|---|
| **EliteBook** | 840/850/860/1040 G5+ with vPro CPUs | ✅ |
| **EliteDesk / Elite Mini/SFF/Tower** | 800 G6/G7/G8/G9 (Q670) with vPro CPUs | ✅ |
| **Z2** | Mini/SFF/Tower G9 (W680) with vPro CPUs | ✅ |
| **EliteDesk 805 G6+** | AMD Ryzen PRO | ❌ DASH, not AMT |

**HP caveat:** Some corporate HP images preset an MEBx password unknown to the user. If `rpc activate` fails with auth errors, BIOS reset / "Unconfigure AMT" first.

#### Intel NUC (now ASUS NUC)

| Model | Local CCM | Notes |
|---|---|---|
| **NUC 11/12/13/14 Pro with `v7`/`v9` SKUs** (e.g. NUC13ANHi7) | ✅ vPro Enterprise | |
| **NUC `v5` and non-`v` SKUs** | ❌ | vPro Essentials or none |
| **NUC 12/13 Extreme on i9-vPro CPUs** | ✅ | Specific SKUs only |

#### DIY W680 (consumer CPU + workstation chipset)

| Board | Local CCM | Notes |
|---|---|---|
| **Supermicro X13SAE / X13SAE-F** | ✅ | -F variant adds separate ASPEED IPMI (BMC) on top |
| **ASUS Pro WS W680-ACE / ACE IPMI** | ✅ | IPMI variant has BMC + AMT |
| **ASRock Rack W680D4U / W680D4U-2L2T** | ✅ | Has IPMI also; AMT via i219LM |
| **MSI / Gigabyte / consumer Z690/Z790** | ❌ | Z690/Z790 ≠ W680, no AMT |
| **Supermicro X13SAV / server boards** | ❌ | Xeon E doesn't carry vPro, BMC only |

#### Other OEMs

- **ASUS Pro Q670M-C-CSM**: ✅ vPro Enterprise
- **ASUS Pro Q670M-CE / D4-CSM**: ❌ vPro Essentials only
- **Acer Veriton X/N/M** with vPro: ✅
- **Fujitsu Esprimo Q/P/D "PRO" SKUs**: ✅ (Q958+ confirmed)
- **Panasonic Toughbook 40/55** with vPro: ✅
- **Server motherboards (Xeon Scalable, EPYC)**: ❌ Use IPMI/Redfish/iDRAC

### Does NOT work on

- Consumer chipsets: H/B/Z series — no AMT firmware
- AMD platforms (Ryzen, EPYC, Threadripper Pro) — use ASMB/DASH instead
- Xeon Scalable servers — use IPMI/Redfish/iDRAC
- vPro Essentials SKUs — limited DASH only, no AMT/KVM
- ARM
- Apple Silicon

---

## BIOS prerequisites

The firmware accepts `-local -ccm` when all of these are true:

1. **AMT enabled in BIOS** — most vPro machines ship with this on by default; setting paths:
   - **Lenovo**: BIOS → Security → Intel(R) AMT → Enabled
   - **Dell**: BIOS → System Management → Intel AMT Capability → Enabled
   - **HP**: BIOS → Advanced → System Options → Intel Active Management Technology → Enabled
   - **ASUS Pro**: BIOS → Advanced → AMT Configuration → Enabled
2. **MEBx password unchanged** — pre-provisioning state means MEBx default (`admin`) is still set; you do not need to know or set it
3. **MEI driver loaded** — `lsmod | grep mei` shows `mei_me`
4. **AMT in pre-provisioning state** — `rpc amtinfo` → `Control Mode: pre-provisioning state`

Items 1 and 2 can be set from Linux on Lenovo (`think-lmi`) and Dell (`cctk`) — see vendor table above.

No provisioning server, no certificates, no network needed for activation itself.

---

## After activation

```bash
yay -S intel-amt-linux    # native Linux GUI + CLI for KVM, SOL, IDER
intel-amt-linux           # launch
```

Or scan your subnet for the AMT IP:
```bash
nmap -p 16992,16993 192.168.1.0/24 --open -oG - | grep open
```

Or check `rpc amtinfo` repeatedly until `AMT IP Address` shows up.

To change AMT NIC to static IP from Linux:
```bash
node /opt/intel-amt-linux/src/tools/amt-net.js static <amt-ip> admin "$(cat ~/.amt-mebx-password.txt)" 10.0.0.5 255.255.255.0 10.0.0.1 8.8.8.8
```

To deactivate AMT:
```bash
sudo rpc deactivate -local
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `rpc: HECIDriverNotDetected` | Not running as root, or `/dev/mei0` missing | Use `sudo`; verify `lsmod \| grep mei_me`, then `sudo modprobe mei_me` |
| `rpc amtinfo` hangs | MEI driver loaded but ME not responding | Verify AMT enabled in BIOS; check `dmesg \| grep mei` |
| Activation hangs 5-15 minutes | Expected on AMT 16.1.25 / AMT 18.x without LMS | Be patient. AMT 16.1.27 takes ~40s. AMT 18 may take 15 min per rpc-go #1119 |
| Activation never completes on AMT 19+ | LME interface removed in CSME 19.x | Install LMS daemon: `yay -S intel-amt-linux` ships LMS in Docker |
| `Execution timeout after 20s` × 3 then exit | AMT not in pre-provisioning, BIOS has AMT disabled, or OEM-preset MEBx password | Check `rpc amtinfo`; reset BIOS / Unconfigure AMT if MEBx is locked |
| IP stays `0.0.0.0` after activation | DHCP not yet leased | Wait 30-60s, re-run `rpc amtinfo`. AMT NIC requests DHCP after CCM transition completes |
| `401 Unauthorized` after activation | Known WiFi/802.1x sync bug on certain firmware | rpc-go #1310 — open issue as of May 2026 |
| `wsmancli`/`openwsman` build fails on Arch | Upstream openwsman is dead since 2019; Ruby rdoc build crash | Use `rpc-go-bin` instead; do not install wsmancli on Arch |
| `cctk: command not found` (Dell) | Dell Command Configure Toolkit not installed | Install from Dell Linux repo or use `sudo` BIOS toggle path |
| `think-lmi` shows no AMT attribute (Lenovo) | Model predates think-lmi exposure of AMTControl | Use BIOS UI once; Lenovo added the attribute progressively across Gens |

### Known rpc-go upstream issues (as of May 2026)

- **#1119** — Local CCM without LMS slow on AMT 16+ (closed)
- **#1208** — AMT 19+ doesn't support LME; non-LMS activation broken (open)
- **#1271** — `amtinfo --proxy`/`--userCert` need LMS on AMT 19+ (open)
- **#1310** — Local ACM 802.1x/WiFi sync fails with 401 after AdminSetup (open)
- **#1082** — Intermittent AMT provisioning issues on Ubuntu without LMS (open)

---

## CCM vs ACM — which mode is this?

| Mode | What | Requires | KVM Consent |
|---|---|---|---|
| **CCM** (Client Control Mode) | What this repo activates | Just `rpc activate -local -ccm` | Required on screen at AMT machine |
| **ACM** (Admin Control Mode) | Full headless management | Provisioning certificate, DNS suffix match, MeshCentral or Intel EMA infrastructure | Not required |

For homelabs and most sysadmin use: **CCM is the right choice**. The "user consent required" KVM prompt only matters if nobody is at the keyboard — for power cycle, SOL, IDER (boot from ISO), CCM gives full access.

ACM activation is also possible via `rpc activate -local -acm` but requires a trusted root certificate and stricter prerequisites (rpc-go #1191, #1310 track ACM issues).

---

## See also

- [intel-amt-linux](https://github.com/88plug/intel-amt-linux) — native Linux GUI + CLI for managing AMT after activation
- [rpc-go](https://github.com/device-management-toolkit/rpc-go) — Intel Device Management Toolkit
- [MeshCentral](https://github.com/Ylianst/MeshCentral) — full-stack AMT/MeshAgent management server
- [Intel AMT Implementation Guide](https://software.intel.com/sites/manageability/AMT_Implementation_and_Reference_Guide/)
- [ThinkWiki AMT support matrix](https://www.thinkwiki.org/wiki/Intel_Active_Management_Technology_(AMT))

---

*Intel®, Intel vPro®, and Intel® Active Management Technology are trademarks of Intel Corporation or its subsidiaries. This project is not affiliated with Intel Corporation.*
