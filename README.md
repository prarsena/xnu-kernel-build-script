# xnu-monterey

A reference build environment for **XNU 8020.140.41** (macOS 12.5 — the last publicly released Monterey kernel source) targeting a **2015 MacBook Pro (x86_64)**.

> **Note:** Apple stopped publishing open-source XNU after macOS 12.5. The `rel/macOS-12` GitHub branch is used as the stable pointer to the latest available Monterey sources. If you set `macos_version=12.7.6`, the build uses 12.5 sources — this is expected and correct.

---

## Prerequisites

### Host machine (dev — Macintosh HD)

| Requirement | Details |
|---|---|
| macOS 12.7.6 (Monterey) | Host must be Monterey to get correct SDK and toolchain behavior |
| Xcode with `MacOSX12.3.sdk` | Verify: `ls /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/` — you need `MacOSX12.3.sdk` present |
| No-space Xcode copy | XNU Makefiles break on space-containing paths. Must rsync Xcode to a no-space location: `rsync -a /Applications/Xcode.app/ ~/Xcode_nospace.app/`. Must be a real directory copy — not a symlink, which `make` resolves back to the original path |
| Xcode license accepted | `sudo xcodebuild -license accept && sudo xcodebuild -runFirstLaunch` |
| `git`, `rsync`, `perl`, `python3` | All present on macOS 12.7.6 by default |
| ~20 GB free disk space | XNU build tree with objects is ~8 GB; leave room for KC artifacts and rsync copies |

### Target machine (xnu-xnu)

| Requirement | Details |
|---|---|
| macOS 12.7.6 on a separate APFS volume | Must be in the **same APFS container** as Macintosh HD so you can mount it writably from the dev volume |
| KDK_12.7.6_21H1320.kdk | Download from [developer.apple.com/download/all](https://developer.apple.com/download/all) → search "Kernel Debug Kit 12.7.6". Install to `/Library/Developer/KDKs/` on xnu-xnu |
| SIP disabled | `csrutil disable` in Recovery Mode — one-time per fresh install |
| Authenticated Root disabled | `csrutil authenticated-root disable` in Recovery Mode — one-time per fresh install |
| No-space source tree | rsync the workspace from Macintosh HD to `~/xnu_monterey_nospace/` on xnu-xnu |
| No-space Xcode copy | rsync `Xcode_nospace.app` from dev to `~/Xcode_nospace.app/` on xnu-xnu, **or** install Xcode directly on xnu-xnu |
| `DEVELOPER_DIR` in shell profile | `echo 'export DEVELOPER_DIR=/Users/xnuman/Xcode_nospace.app/Contents/Developer' >> ~/.zprofile` — must survive new terminal sessions and sudo |

### Disk layout requirement

Both macOS installs **must share an APFS container**. The kernel is built on the dev volume, and `kmutil create` + `bless` must run on xnu-xnu while it is booted. You write to xnu-xnu's system partition by mounting `disk1s8` directly alongside the running snapshot.

```
APFS Container disk1
├── disk1s1  Macintosh HD        ← dev: build here
├── disk1s5  Macintosh HD - Data
├── disk1s7  xnu-xnu - Data
└── disk1s8  xnu-xnu             ← target: boot and deploy here
```

### Setup sequence (what we did to get here)

1. Installed macOS 12.7.6 on both APFS volumes (dev: disk1s1, target: disk1s8)
2. Installed Xcode with `MacOSX12.3.sdk` on Macintosh HD
3. Created no-space Xcode copy at `~/Xcode_nospace.app/` via rsync
4. Downloaded and installed `KDK_12.7.6_21H1320.kdk` on xnu-xnu
5. Disabled SIP and Authenticated Root on xnu-xnu (Recovery Mode, one-time)
6. Built XNU prerequisites via `make -f Makefile.xnudeps` (downloads and builds dtrace, libdispatch, AvailabilityVersions — see bugs fixed below)
7. Built XNU kernel via `make SDKROOT=... ARCH_CONFIGS=X86_64 KERNEL_CONFIGS=DEVELOPMENT`
8. rsync'd source tree to no-space path on xnu-xnu
9. rsync'd Xcode to `~/Xcode_nospace.app/` on xnu-xnu
10. Built KC via `verify-and-build-kc.sh` on xnu-xnu
11. Blessed new snapshot and rebooted with `kcsuffix=development`

---

## What Was Built

### Build system (`Makefile.xnudeps`)

Automated download and build of all XNU prerequisites for macOS 12.x.

**Bugs fixed during setup:**

| Bug | Root cause | Fix |
|-----|-----------|-----|
| `SyntaxError: invalid syntax` in version lookup | Python `try/except`+`for` collapsed to invalid one-liner by Make's `$(shell)` | Rewrote using `next()` + generator expression |
| `404: Not Found` for `macos-127` branch | Apple's GitHub only has tags through 12.5; `macos-127` never existed | Switched to `rel/macOS-12` (Apple's stable major-version branch pointer) |
| `mv: rename ir to dtrace-375.120.1` | `$$dir` in a `define` macro only survives one expansion level; Make reads `$d`+`ir` as the variable | Used `$$$$dir` / `$$$$(...)` for correct double-expansion |
| `An empty identity is not valid` (dtrace xcodebuild) | Newer Xcode requires a signing identity for command-line tool targets | Added `CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO` |
| `cannot initialize return object of type 'bool' with nullptr_t` | `return NULL` in a `bool` function — stricter Clang on newer Xcode | Changed to `return false` in `IOBufferMemoryDescriptor.cpp` |
| `env: python: No such file or directory` (lldbmacros install) | `python` (Python 2) removed from macOS; `PYTHON` variable undefined in XNU build system | Added `PYTHON = /usr/bin/python3` to `makedefs/MakeInc.cmd` |

### XNU kernel (`xnu-8020.140.41`)

Successfully compiled a `DEVELOPMENT` kernel for `x86_64`:

```
BUILD/obj/DEVELOPMENT_X86_64/kernel.development
```

**Build command:**
```bash

make SDKROOT=macosx \
  ARCH_CONFIGS=X86_64 \
  KERNEL_CONFIGS=DEVELOPMENT \
  HOST_ARCHS=X86_64 \
  HOST_OS_ARCH=x86_64 \
  WERROR="" \
  EXTRA_CFLAGS="-Wno-null-pointer-subtraction -Wno-four-char-constants -Wno-error" \
  EXTRA_CXXFLAGS="-Wno-null-pointer-subtraction -Wno-c++11-narrowing -Wno-suggest-override -Wno-suggest-destructor-override -Wno-error"

# specific (explicit Monterey-era SDK from the other volume)
make SDKROOT="/Volumes/Macintosh HD/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX12.3.sdk" \
  ARCH_CONFIGS=X86_64 \
  KERNEL_CONFIGS=DEVELOPMENT \
  HOST_ARCHS=X86_64 \
  HOST_OS_ARCH=x86_64 \
  WERROR="" \
  EXTRA_CFLAGS="-Wno-null-pointer-subtraction -Wno-four-char-constants -Wno-error" \
  EXTRA_CXXFLAGS="-Wno-null-pointer-subtraction -Wno-c++11-narrowing -Wno-suggest-override -Wno-suggest-destructor-override -Wno-error"
```

`DEVELOPMENT` vs `RELEASE`:

| Config | Boot time | Panic backtraces | KASAN | Use case |
|---|---|---|---|---|
| `DEVELOPMENT` | 3–7 min | Full | Yes | Active development — catches memory bugs |
| `RELEASE` | ~30 sec | Minimal | No | Performance testing, stable code |

The slow boot on `DEVELOPMENT` is caused by KASAN shadow-mapping the entire kernel address space before any driver loads (2–4 min on 16 GB RAM), zone initialization, and assert/lock-order checks on every operation. This is the correct config for development — panics give complete backtraces. Switch to `RELEASE` only once a change is known stable.

To monitor build progress (from a second terminal):
```bash
pgrep -x make && echo "running" || echo "done"
ls -l BUILD/obj/DEVELOPMENT_X86_64/kernel.development 2>/dev/null || echo "not linked yet"
```

---

## XNU Architecture (Quick Reference)

XNU is a **hybrid kernel**: Mach microkernel + BSD (FreeBSD-derived) + I/O Kit (C++ driver framework), all in a single address space for performance. Relevant to this project:

- **Mach** — tasks, threads, VM, IPC (Mach ports/messages). Handles `fork()`, scheduling, virtual memory, context switches.
- **BSD** — POSIX syscalls, VFS, networking, security (SIP/sandbox via MAC framework), signals.
- **I/O Kit** — C++ device driver objects, loaded as kexts. Drivers communicate with userspace through controlled interfaces.
- **Kext Collection (KC)** — on Monterey, the bootloader does not load the kernel file directly. It boots a `BootKernelExtensions.kc` which bundles the kernel + essential drivers into one binary blob. You must rebuild the KC after swapping the kernel.

---

## Deploying to the 2015 MBP

### Machine layout (this machine)

```
/dev/disk0 — 251 GB internal SSD
  disk0s1   EFI
  disk0s2   APFS Container (disk1) — 160 GB
    disk1s1   Macintosh HD          (dev machine — macOS 12.7.6)
    disk1s5   Macintosh HD - Data   (dev machine data)
    disk1s7   xnu-xnu - Data        (target machine data)
    disk1s8   xnu-xnu               (target machine — macOS 12.7.6)  ← deploy target
  disk0s3   WORKSPACE (MS Basic Data, 18 GB)
  disk0s4   FreeBSD UFS (62 GB)
  disk0s5   FreeBSD Swap (3 GB)
```

Both macOS installs are in the **same APFS container** (`disk1`). You build on "Macintosh HD" and boot into "xnu-xnu" to test. Files can be shared between them (e.g. via `/Volumes/xnu-xnu`), but applications cannot be run cross-volume.

The **KDK is already installed** on xnu-xnu at:
```
/Volumes/xnu-xnu/Library/Developer/KDKs/KDK_12.7.6_21H1320.kdk/
```

---

### What is the SSV (Signed System Volume)?

Starting with macOS 11 (Big Sur), Apple cryptographically seals the system volume. The seal is a hash tree over every file in `/System`. If any file changes — even touching `/System/Library/Kernels/kernel` — the volume's seal is broken and the bootloader **refuses to boot it**.

"Breaking the SSV" means running `csrutil authenticated-root disable` in Recovery, which tells the bootloader to stop enforcing that seal check on your volume. After you do this, you can mount the underlying writable APFS volume (not the snapshot that `-root` normally presents), make changes, and re-seal with a new snapshot via `bless --create-snapshot`. SIP (`csrutil disable`) also needs to be off so you can write to `/System` at all.

**This is a one-time step per fresh OS install on xnu-xnu. Your dev volume (Macintosh HD) is never affected.**

---

### Step 1 — Break the SSV (one-time, Recovery Mode)

Restart and hold `Cmd+R` to enter Recovery. Open **Utilities → Terminal**:

```bash
csrutil disable
csrutil authenticated-root disable
```

Reboot back into **xnu-xnu**.

Verify it worked:
```bash
csrutil status
# Expected: System Integrity Protection status: disabled.
csrutil authenticated-root status
# Expected: Authenticated Root status: disabled
```

---

### Step 2 — Optional: copy the custom kernel to xnu-xnu

You can do this step from the **dev machine** (Macintosh HD) while xnu-xnu is not booted, by writing directly through `/Volumes/xnu-xnu`. But the SSV mount trick (Step 3) **must be done while booted into xnu-xnu**, because you need to bless it from within the target volume.

The successful wrapper flow in Step 3 uses the built kernel directly from the build tree for `kmutil -k`, so this copy is optional. Keep this step only if you also want `kernel.development` staged inside the target volume.

From the dev machine (while booted into Macintosh HD):

```bash
# macOS auto-mounts xnu-xnu as a read-only snapshot at /Volumes/xnu-xnu.
# Unmount that snapshot first, then mount the underlying writable volume:
sudo diskutil unmount /Volumes/xnu-xnu

mkdir ~/xnu_target
sudo mount -o nobrowse -t apfs /dev/disk1s8 ~/xnu_target

sudo cp /Users/pete/Developer/xnu-monterey/xnu-8020.140.41/BUILD/obj/DEVELOPMENT_X86_64/kernel.development \
    ~/xnu_target/System/Library/Kernels/kernel.development

sudo diskutil unmount ~/xnu_target
```

Apple's stock kernel stays at `.../Kernels/kernel` — untouched.

---

### Step 3 — Build the Kext Collection (run on xnu-xnu)

Boot into **xnu-xnu**. This step must run on the target machine.

### Requirements for the successful KC build

This is the exact set of requirements that produced a successful `kmutil create` in this workspace:

1. Build/run from no-space paths:
  - source: `/Users/xnuman/xnu_monterey_nospace/xnu-8020.140.41`
  - scripts: `/Users/xnuman/xnu_monterey_nospace/scripts`
2. Use a valid no-space Xcode toolchain path:
  - `export DEVELOPER_DIR=/Users/xnuman/Xcode_nospace.app/Contents/Developer`
3. Use the freshly built kernel for `-k`:
  - `/Users/xnuman/xnu_monterey_nospace/xnu-8020.140.41/BUILD/obj/DEVELOPMENT_X86_64/kernel.development`
4. Include XNU symbolset pseudo-kext exporters as a repository:
  - `/Users/xnuman/xnu_monterey_nospace/xnu-8020.140.41/BUILD/obj/DEVELOPMENT_X86_64/config/System.kext/PlugIns`
5. Include KDK + target extension repositories:
  - `/Library/Developer/KDKs/KDK_12.7.6_21H1320.kdk/System/Library/Extensions`
  - `~/live_mount/System/Library/Extensions`
  - `~/live_mount/System/Library/DriverExtensions`
6. Elide missing AppleRSM-dependent USB bundles (needed on this install):
  - `com.apple.driver.usb.AppleUSBVHCICommonRSM`
  - `com.apple.driver.usb.AppleUSBVHCIRSM`
  - `com.apple.driver.usb.AppleUSBVHCIFirmwareRSM`
  - `com.apple.driver.usb.AppleUSBRecoveryHost`

Mount the writable system volume:

```bash
# You are booted INTO xnu-xnu — it is your root /.
# There is no /Volumes/xnu-xnu to unmount here.
# Simply mount the underlying writable APFS volume alongside the running snapshot:
mkdir ~/live_mount
sudo mount -o nobrowse -t apfs /dev/disk1s8 ~/live_mount
```

Set the toolchain explicitly before running helper scripts:

```bash
export DEVELOPER_DIR=/Users/xnuman/Xcode_nospace.app/Contents/Developer
```

Preflight check (recommended before every `kmutil create` run):

```bash
# Script locations:
#   /Users/xnuman/xnu_monterey_nospace/scripts/verify-kc-prereqs.sh
#   /Users/xnuman/xnu_monterey_nospace/scripts/verify-and-build-kc.sh

# Example: verify with explicit built kernel + symbolset exporters
/Users/xnuman/xnu_monterey_nospace/scripts/verify-kc-prereqs.sh \
  --kernel /Users/xnuman/xnu_monterey_nospace/xnu-8020.140.41/BUILD/obj/DEVELOPMENT_X86_64/kernel.development \
  --kdk-root /Library/Developer/KDKs/KDK_12.7.6_21H1320.kdk \
  --target-root ~/live_mount \
  --symbolset-root /Users/xnuman/xnu_monterey_nospace/xnu-8020.140.41/BUILD/obj/DEVELOPMENT_X86_64/config/System.kext/PlugIns \
  --variant development
```

Wrapper behavior:

- If `--kernel` is omitted and `--symbolset-root` points into `BUILD/obj/.../config/System.kext/PlugIns`, `verify-and-build-kc.sh` auto-selects the matching `BUILD/obj/.../kernel.development`.
- Otherwise it falls back to `~/live_mount/System/Library/Kernels/kernel.development`.

One-shot helper (verify first, then run `kmutil create`):

```bash
/Users/xnuman/xnu_monterey_nospace/scripts/verify-and-build-kc.sh \
  --kdk-root /Library/Developer/KDKs/KDK_12.7.6_21H1320.kdk \
  --target-root ~/live_mount \
  --symbolset-root /Users/xnuman/xnu_monterey_nospace/xnu-8020.140.41/BUILD/obj/DEVELOPMENT_X86_64/config/System.kext/PlugIns \
  --variant development \
  --elide-identifier com.apple.driver.usb.AppleUSBVHCICommonRSM \
  --elide-identifier com.apple.driver.usb.AppleUSBVHCIRSM \
  --elide-identifier com.apple.driver.usb.AppleUSBVHCIFirmwareRSM \
  --elide-identifier com.apple.driver.usb.AppleUSBRecoveryHost \
  --yes
```

If the script reports missing `BSDKernel.kext/BSDKernel` or `Private.kext/Private`, run XNU install first so symbolset binaries are materialized:

```bash
# Important: XNU makefiles do not reliably handle source paths with spaces
# (for example: /Volumes/Macintosh HD/...). If you see errors like:
#   Makefile:344: /Volumes/Macintosh: No such file or directory
# use a real no-space working copy (not a symlink), because xnu make can
# resolve symlinks back to the original space-containing path.
# If you previously made xnu_monterey_nospace a symlink, remove it first.
if [ -L "$HOME/xnu_monterey_nospace" ]; then rm "$HOME/xnu_monterey_nospace"; fi
mkdir -p "$HOME/xnu_monterey_nospace"
rsync -a --delete \
  "/Volumes/Macintosh HD/Users/pete/Developer/xnu-monterey/" \
  "$HOME/xnu_monterey_nospace/"

cd "$HOME/xnu_monterey_nospace/xnu-8020.140.41"

# DEVELOPER_DIR must be a real no-space path.
# Use Xcode_nospace.app (full rsync'd copy from the dev volume) — this is the
# canonical path used by all build commands and xcode-select on xnu-xnu.
export DEVELOPER_DIR="$HOME/Xcode_nospace.app/Contents/Developer"

# Also switch the system developer directory for sudo/root tools.
# (Without this, sudo xcodebuild can still resolve to CommandLineTools.)
sudo xcode-select --switch "$DEVELOPER_DIR"
sudo xcode-select -p

# One-time per OS install (or after Xcode updates):
sudo xcodebuild -runFirstLaunch
sudo xcodebuild -license accept

# Use the explicit macOS 12.3 SDK path (not the default SDK).
# Keep this path no-space and non-symlink as well, or XNU make can split it.
mkdir -p "$HOME/SDKs"
rsync -a --delete \
  "$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/SDKs/MacOSX12.3.sdk/" \
  "$HOME/SDKs/MacOSX12.3.sdk/"

SDKROOT_12_3="$HOME/SDKs/MacOSX12.3.sdk"
unset SDKROOT
echo "$PWD"
echo "$DEVELOPER_DIR"
echo "$SDKROOT_12_3"
ls -ld "$SDKROOT_12_3"

make install_kernels \
  SDKROOT="$SDKROOT_12_3" \
  ARCH_CONFIGS=X86_64 \
  KERNEL_CONFIGS=DEVELOPMENT \
  DSTROOT=/tmp/xnu-dst
```

Paths (verified on xnu-xnu):

| Path | What it is |
|------|-----------|
| `/Users/xnuman/xnu_monterey_nospace/xnu-8020.140.41/BUILD/obj/DEVELOPMENT_X86_64/kernel.development` | Freshly built development kernel used by `kmutil -k` |
| `/Users/xnuman/xnu_monterey_nospace/xnu-8020.140.41/BUILD/obj/DEVELOPMENT_X86_64/config/System.kext/PlugIns` | XNU symbolset pseudo-kext exporters (`BSDKernel`, `Private`) |
| `/Library/Developer/KDKs/KDK_12.7.6_21H1320.kdk/System/Library/Extensions/` | KDK kexts (debug versions with dSYMs) |
| `~/live_mount/System/Library/Extensions/` | Target system kexts |
| `~/live_mount/System/Library/DriverExtensions/` | Target DriverKit extensions |
| `~/live_mount/System/Library/KernelCollections/BootKernelExtensions.kc.development` | Generated boot KC (development suffix) |
| `~/live_mount/System/Library/KernelCollections/SystemKernelExtensions.kc.development` | Generated system KC (development suffix) |

Note: `-k` selects the kernel embedded into generated `*.kc.development`. Using an out-of-date copied kernel in `~/live_mount/System/Library/Kernels/` can reproduce unresolved-symbol failures.

### What this step gives the system (and practical meaning)

After a successful `verify-and-build-kc.sh` / `kmutil create` run, the target volume gets two new development-suffix KC files:

- `~/live_mount/System/Library/KernelCollections/BootKernelExtensions.kc.development`
- `~/live_mount/System/Library/KernelCollections/SystemKernelExtensions.kc.development`

These are rebuilt collections that include your selected `-k` kernel input and the resolved kext graph for the `development` suffix.

Practical meaning:

1. Your custom kernel is now packaged into bootable KC artifacts, but not active yet.
2. The machine will still boot the normal production KCs unless you boot with `kcsuffix=development`.
3. The change becomes boot-visible only after you bless/create a new snapshot (next step) and reboot.
4. If `kcsuffix=development` is removed, macOS falls back to standard non-development KCs.

You can verify outputs immediately with:

```bash
ls -l ~/live_mount/System/Library/KernelCollections/BootKernelExtensions.kc.development \
  ~/live_mount/System/Library/KernelCollections/SystemKernelExtensions.kc.development
shasum ~/live_mount/System/Library/KernelCollections/BootKernelExtensions.kc.development \
   ~/live_mount/System/Library/KernelCollections/SystemKernelExtensions.kc.development
```

Example from this successful run:

- `BootKernelExtensions.kc.development`: `71729152` bytes, SHA1 `1a1adb9bee73f16245441d393f4bccfe635fd917`
- `SystemKernelExtensions.kc.development`: `426459136` bytes, SHA1 `df7667a072178d086c0f4308601c2821f4b85329`

---

### Step 4 — Seal the new snapshot and bless

Why this step is required:

- `kmutil create` writes `*.kc.development` files to the mounted writable system volume.
- Those files are not boot-active until they are captured in a new APFS system snapshot.
- `bless --create-snapshot` creates that snapshot and marks it bootable.
- On next boot, `boot-args` with `kcsuffix=development` tells the bootloader to use `BootKernelExtensions.kc.development` and `SystemKernelExtensions.kc.development` from that blessed snapshot.
- Without `kcsuffix=development`, boot continues to use the default `*.kc` files.

```bash
sudo bless \
  --folder ~/live_mount/System/Library/CoreServices \
  --bootefi --create-snapshot

sudo umount ~/live_mount
```

> **Disk space:** every `bless --create-snapshot` creates a new multi-GB COW APFS snapshot of the entire system volume. They accumulate fast. You only ever need the most recent one (rollback lifeboat if the next kernel panics at boot). Prune after every confirmed-good boot.

#### Pruning old snapshots

Two snapshot types exist on the xnu-xnu system volume and they serve different purposes:

| Name prefix | Created by | Purgeable | Keep? |
|---|---|---|---|
| `com.apple.os.update-*` | macOS system update / initial install | No | Yes — do not delete; this is the original sealed OS snapshot |
| `com.apple.bless.*` | `bless --create-snapshot` | Yes | Only the newest (currently booted) one |

Every `bless --create-snapshot` run adds one more `com.apple.bless.*` snapshot. They accumulate across kernel development iterations. Only the one marked "Will root to this snapshot" in `diskutil apfs listSnapshots` matters — the rest are dead weight.

**Current state (as of 2026-04-12):** `disk1s8` has 5 stale `com.apple.bless.*` snapshots (XIDs 35392–40847) and 1 active snapshot at XID 41613 (`com.apple.bless.FF149885-5F6E-499C-A659-EBF191C05FFA`). The stale 5 are safe to delete.

List all snapshots on the target volume:

```bash
sudo mount -o nobrowse -t apfs /dev/disk1s8 ~/live_mount
diskutil apfs listSnapshots disk1s8
```

Delete a specific snapshot by UUID (preferred — avoids name quoting issues):

```bash
sudo diskutil apfs deleteSnapshot disk1s8 -uuid <UUID>
```

**Nuke all bless snapshots except the newest** (safe to run after confirming the system boots OK):

```bash
sudo mount -o nobrowse -t apfs /dev/disk1s8 ~/live_mount

snapshots=$(diskutil apfs listSnapshots disk1s8 | grep 'com.apple.bless' | awk '{print $NF}')
latest=$(echo "$snapshots" | tail -1)
echo "$snapshots" | grep -v "$latest" | while read snap; do
  echo "Deleting $snap"
  sudo /System/Library/Filesystems/apfs.fs/Contents/Resources/apfs_systemsnapshot \
    -r "$snap" -v ~/live_mount
done

sudo umount ~/live_mount
```

After cleanup: one `com.apple.os.update-*` (original seal) + one `com.apple.bless.*` (current boot target). Subsequent `bless --create-snapshot` runs will add one more bless snapshot; prune again after the next confirmed boot.

---

### Step 5 — Set boot-args and reboot

```bash
sudo nvram boot-args="kcsuffix=development wlan.skywalk.enable=0 -v serial=3 debug=0x8"
```

- `kcsuffix=development` — tells the bootloader to load `*.kc.development` collections instead of `*.kc`
- `wlan.skywalk.enable=0` — disables Skywalk (not in open-source XNU; will panic otherwise)
- `-v` — verbose boot (white text on black screen — essential for reading panics)
- `serial=3` — also output to serial (useful with a Thunderbolt-Ethernet adapter + `socat` on another machine)
- `debug=0x8` — writes panic log to disk even if the kernel can't complete the normal crash write path

> **DEVELOPMENT kernel boots slowly (3–7 min) — this is expected.** KASAN must shadow-map all of RAM before drivers load. Do not power off during this phase. The login screen will eventually appear.

Reboot. You should see verbose boot text.

Post-reboot verification (recommended):

```bash
# Confirm boot-args still include development KC suffix:
nvram -p | grep boot-args

# Confirm the loaded prelinked kernel path uses development suffix:
kmutil showloaded --list-only --variant-suffix development | head -n 20

# Optional: verify currently installed development KC artifact metadata:
ls -l /System/Library/KernelCollections/BootKernelExtensions.kc.development \
  /System/Library/KernelCollections/SystemKernelExtensions.kc.development
```

Expected practical result:

- `boot-args` contains `kcsuffix=development`.
- `kmutil showloaded` with `--variant-suffix development` returns loaded entries instead of an empty result.

### If it panics — recovery

**Hold the power button** to force power off. Boot into Recovery (`Cmd+R`), open Terminal:

```bash
nvram -d boot-args
```

This clears the boot-args. The machine will boot normally using the standard `*.kc` (no suffix) — Apple's fully sealed, signed collections. Your xnu-xnu install is unaffected.

---

## Known Limitations of the Open-Source XNU Build

These are missing from the open-source drop and will cause reduced functionality on any booted kernel:

| Feature | Status |
|---------|--------|
| WLAN (Skywalk) | Missing — use `wlan.skywalk.enable=0`; no Wi-Fi |
| XCPM (CPU power management) | Missing — sleep/wake may not work |
| DriverKit networking (`dk=0`) | May need disabling if Skywalk-related panics occur |

---

## Capturing Panic Logs

A **Thunderbolt-to-Ethernet adapter** is strongly recommended. If the kernel panics before the filesystem mounts, the panic log won't be written to disk. Two options:

1. **Serial over Thunderbolt-Ethernet**: boot with `serial=3`, run `socat` on a second machine connected via Ethernet and a USB serial adapter
2. **KDP (Kernel Debugger Protocol)**: connect a second Mac via Ethernet, run `lldb` with the kernel's `.dSYM` from `BUILD/obj/DEVELOPMENT_X86_64/kernel.development.dSYM`

For KDP, set in NVRAM before booting:
```bash
sudo nvram boot-args="... kdp_match_name=en0 -v"
```
Then on the debug host: `lldb` → `kdp-remote <ip-of-target>`

---

## Recovery Checklist

| Symptom | Fix |
|---------|-----|
| Won't boot at all | Hold power button; boot Recovery (`Cmd+R`); `nvram -d boot-args`; reboot |
| Panic on every boot of xnu-xnu | Recovery → reinstall macOS onto disk1s8; re-do Steps 1–5 |
| Macintosh HD (dev) volume affected | It shouldn't be — it's disk1s1/disk1s5, never touched by these steps. Verify with `diskutil list` |
| Mounted wrong slice | Always confirm `diskutil list` before mounting. xnu-xnu system = **disk1s8**, dev system = **disk1s1** |
| FreeBSD partition affected | Only at risk if you `mount` or `bless` the wrong slice — disk0s4 is FreeBSD, never touch it |
