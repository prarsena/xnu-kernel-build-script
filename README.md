# xnu-monterey

A reference build environment for **XNU 8020.140.41** (macOS 12.5 — the last publicly released Monterey kernel source) targeting a **2015 MacBook Pro (x86_64)**.

> **Note:** Apple stopped publishing open-source XNU after macOS 12.5. The `rel/macOS-12` GitHub branch is used as the stable pointer to the latest available Monterey sources. If you set `macos_version=12.7.6`, the build uses 12.5 sources — this is expected and correct.

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
make SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX12.3.sdk \
  ARCH_CONFIGS=X86_64 \
  KERNEL_CONFIGS=DEVELOPMENT \
  HOST_ARCHS=X86_64 \
  HOST_OS_ARCH=x86_64 \
  WERROR="" \
  EXTRA_CFLAGS="-Wno-null-pointer-subtraction -Wno-four-char-constants -Wno-error" \
  EXTRA_CXXFLAGS="-Wno-null-pointer-subtraction -Wno-c++11-narrowing -Wno-suggest-override -Wno-suggest-destructor-override -Wno-error"
```

`DEVELOPMENT` vs `RELEASE`: the development kernel includes debug assertions, extra logging, and KASAN instrumentation. Slower, but panics give far more information. Use `RELEASE` only once things are stable.

---

## XNU Architecture (Quick Reference)

XNU is a **hybrid kernel**: Mach microkernel + BSD (FreeBSD-derived) + I/O Kit (C++ driver framework), all in a single address space for performance. Relevant to this project:

- **Mach** — tasks, threads, VM, IPC (Mach ports/messages). Handles `fork()`, scheduling, virtual memory, context switches.
- **BSD** — POSIX syscalls, VFS, networking, security (SIP/sandbox via MAC framework), signals.
- **I/O Kit** — C++ device driver objects, loaded as kexts. Drivers communicate with userspace through controlled interfaces.
- **Kext Collection (KC)** — on Monterey, the bootloader does not load the kernel file directly. It boots a `BootKernelExtensions.kc` which bundles the kernel + essential drivers into one binary blob. You must rebuild the KC after swapping the kernel.

---

## Deploying to the 2015 MBP

### The core challenge: Signed System Volume (SSV)

macOS 12 (Monterey) seals the system volume with a cryptographic hash. Any modification — including replacing the kernel — breaks the seal and the system won't boot. You must **break the seal on your lab volume** before writing anything.

### Step 0 — Prepare a Lab Volume

You don't need a new partition. Create a 30 GB APFS volume inside your existing macOS container:

```bash
diskutil apfsAddVolume disk0s2 APFS "macOS Lab" -quota 30g
```

Install a fresh copy of macOS 12 onto it from Recovery or use `softwareupdate --fetch-full-installer`. This is your expendable OS. Your primary 12.7.6 install is never touched.

### Step 1 — Install the KDK (Kernel Debug Kit)

Download from [developer.apple.com/download/more](https://developer.apple.com/download/more/) → search "Kernel Debug Kit 12". Install the `.pkg`.

Installed to: `/Library/Developer/KDKs/KDK_12.x.x_<build>.kdk`

The KDK provides private headers and a `System.kext` needed to link the kernel collection against your custom kernel. Without it, `kmutil create` fails.

### Step 2 — Break the SSV (one-time, Recovery Mode)

Boot the 2015 MBP into **Recovery Mode** (`Cmd+R` at startup). Open **Utilities → Terminal**:

```bash
csrutil disable
csrutil authenticated-root disable
```

Reboot into the Lab Volume.

### Step 3 — Mount the Lab Volume read-write

The SSV presents the system volume as a read-only snapshot. Mount the underlying writable volume:

```bash
# Find your lab volume's disk slice (e.g. disk0s5)
diskutil list

mkdir ~/live_mount
sudo mount -o nobrowse -t apfs /dev/disk0s5 ~/live_mount
```

> Use `nobrowse` so Finder doesn't index it. The slice identifier is the **volume** slice, not the snapshot (no trailing `s1` like you see in `mount` output for the live root).

### Step 4 — Copy the kernel

```bash
sudo cp /path/to/xnu-8020.140.41/BUILD/obj/DEVELOPMENT_X86_64/kernel.development \
    ~/live_mount/System/Library/Kernels/kernel.development
```

Apple's stock kernel stays at `.../Kernels/kernel` — untouched. You're adding a parallel file, not replacing anything.

### Step 5 — Build the Kext Collection

This must be run on the **target machine** (the 2015 MBP), not a cross-compile host.

```bash
cd /path/to/xnu-8020.140.41

kmutil create \
  -a x86_64 -Z \
  -n boot \
  -B BUILD/BootKernelExtensions.kc.development \
  -S BUILD/SystemKernelExtensions.kc.development \
  -k BUILD/obj/DEVELOPMENT_X86_64/kernel.development \
  --elide-identifier com.apple.driver.AppleIntelTGLGraphicsFramebuffer
```

Then copy into the live mount:

```bash
sudo ditto BUILD/BootKernelExtensions.kc.development \
    ~/live_mount/System/Library/KernelCollections/BootKernelExtensions.kc.development

sudo ditto BUILD/SystemKernelExtensions.kc.development \
    ~/live_mount/System/Library/KernelCollections/SystemKernelExtensions.kc.development
```

### Step 6 — Seal the new snapshot and bless

```bash
sudo bless \
  --folder ~/live_mount/System/Library/CoreServices \
  --bootefi --create-snapshot
```

To test for **one boot only** (safest first attempt):

```bash
sudo nvram boot-args="kcsuffix=development wlan.skywalk.enable=0 -v serial=3"
```

- `kcsuffix=development` — tells the booter to load `*.kc.development` instead of `*.kc`
- `wlan.skywalk.enable=0` — disable Skywalk (not in open-source XNU; will panic otherwise)
- `-v` — verbose boot (white text on black screen; you need this to read a panic)
- `serial=3` — output to serial as well (useful with Thunderbolt Ethernet + `socat` on a second machine)

### Step 7 — First boot

Reboot. You should see verbose boot output. If it panics:

**Hold the power button.** Because the NVRAM `boot-args` persist but `--nextonly` was not used, you may need to clear them from Recovery if the machine won't get far enough:

```bash
# From Recovery Terminal:
nvram -d boot-args
```

This returns you to the standard, Apple-signed `*.kc` (no suffix).

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
| Won't boot at all | Hold power button; boot Recovery; `nvram -d boot-args`; reboot |
| Panic on every boot of Lab Volume | Recovery → `csrutil enable` → wipes SSV seal change; reinstall Lab OS |
| Primary macOS volume affected | It shouldn't be — you never touched it. Verify with `diskutil list` |
| FreeBSD partition affected | Only at risk if you `mount` or `bless` the wrong slice — double-check slice identifiers before every `mount` command |
