# Kernel Customization Guide

You've successfully booted your own XNU kernel on the 2015 MBP. This document maps the source files you can modify, what each controls, and the rebuild/redeploy loop.

---

## The Rebuild Loop

Every change to any source file requires the same cycle:

1. **Edit** the source on Macintosh HD (this workspace)
2. **Sync** the changed file(s) to the no-space working copy on xnu-xnu
3. **Build** the kernel on xnu-xnu
4. **Run** `verify-and-build-kc.sh` to produce new `*.kc.development` on `~/live_mount`
5. **Bless** the new snapshot
6. **Reboot** into xnu-xnu

### Step 2 — Sync edited files to no-space copy

Edits made in this workspace (`/Volumes/Macintosh HD/Users/pete/Developer/xnu-monterey/`) must be
synced to the no-space copy before building, otherwise the build uses stale source.

**Sync a single file** (fast, preferred for incremental work):
```bash
# Example: after editing config/version.c on Macintosh HD:
rsync -av \
  "/Volumes/Macintosh HD/Users/pete/Developer/xnu-monterey/xnu-8020.140.41/config/version.c" \
  "/Users/xnuman/xnu_monterey_nospace/xnu-8020.140.41/config/version.c"

touch /Users/xnuman/xnu_monterey_nospace/xnu-8020.140.41/config/version.c
```

**Sync the entire tree** (use after a batch of edits or if unsure what changed):
```bash
rsync -a --delete \
  "/Volumes/Macintosh HD/Users/pete/Developer/xnu-monterey/" \
  "/Users/xnuman/xnu_monterey_nospace/"
```

> **Why is this required?** XNU's Makefiles fail silently or produce wrong binaries when any
> path component contains a space. `/Volumes/Macintosh HD/...` cannot be used directly as
> `SRCROOT`. The no-space copy at `~/xnu_monterey_nospace/` is the actual build root.

```bash
# On xnu-xnu (booted target):

export DEVELOPER_DIR=/Users/xnuman/Xcode_nospace.app/Contents/Developer
SDKROOT="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/SDKs/MacOSX12.3.sdk"

# Build kernel (takes 5-15 min depending on what changed):
cd /Users/xnuman/xnu_monterey_nospace/xnu-8020.140.41
make SDKROOT="$SDKROOT" \
  ARCH_CONFIGS=X86_64 KERNEL_CONFIGS=DEVELOPMENT \
  WERROR="" \
  EXTRA_CFLAGS="-Wno-null-pointer-subtraction -Wno-four-char-constants -Wno-error" \
  EXTRA_CXXFLAGS="-Wno-null-pointer-subtraction -Wno-c++11-narrowing -Wno-suggest-override -Wno-suggest-destructor-override -Wno-error"


# Rebuild KC + bless:

mkdir -p ~/live_mount
sudo mount -o nobrowse -t apfs /dev/disk1s8 ~/live_mount
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

sudo bless --folder ~/live_mount/System/Library/CoreServices --bootefi --create-snapshot
sudo umount ~/live_mount


# set boot commands and reboot

sudo nvram boot-args="kcsuffix=development wlan.skywalk.enable=0 -v serial=3 debug=0x8"
sudo reboot
```

---

## DEVELOPMENT vs RELEASE — Boot Time and Tradeoffs

| Config | Boot time | Panic backtraces | KASAN | Build output |
|---|---|---|---|---|
| `DEVELOPMENT` | 3–7 min | Full | Yes | `BUILD/obj/DEVELOPMENT_X86_64/kernel.development` |
| `RELEASE` | ~30 sec | Minimal | No | `BUILD/obj/RELEASE_X86_64/kernel` |

**Why DEVELOPMENT boots slowly:**

1. **KASAN** — instruments every memory access to detect buffer overflows and use-after-free at runtime. Before any driver loads it must shadow-map the entire kernel address space. On 16 GB RAM this takes 2–4 minutes alone.
2. **Eager zone initialization** — all VM zones fully initialized at boot rather than on demand. The long list of `0xffffff...` zone ranges in verbose boot output is this step.
3. **Assertions on every operation** — every `assert()`, lock-ordering check, and `DCHECK` runs live. IOKit driver matching fires hundreds per attached driver.
4. **Reduced optimization** — compiled at lower optimization levels so stack frames stay readable in the debugger.

**Use DEVELOPMENT while actively writing and testing kernel code.** Switch to RELEASE when you want to performance-test a change or confirm a stable build boots quickly.

To build RELEASE:
```bash
make SDKROOT="$SDKROOT" \
  ARCH_CONFIGS=X86_64 KERNEL_CONFIGS=RELEASE \
  WERROR="" \
  EXTRA_CFLAGS="-Wno-null-pointer-subtraction -Wno-four-char-constants -Wno-error" \
  EXTRA_CXXFLAGS="-Wno-null-pointer-subtraction -Wno-c++11-narrowing -Wno-suggest-override -Wno-suggest-destructor-override -Wno-error"
```

Then use `--variant release` in the scripts and `kcsuffix=release` in boot-args:
```bash
sudo nvram boot-args="kcsuffix=release wlan.skywalk.enable=0 -v debug=0x8"
```

---

## 1. Kernel Identity Strings

### `config/version.c` — the version banner visible in `uname -a`

This is the first thing you'll want to customize. The template file is processed by `config/newvers.pl` on every build, which substitutes the `###KERNEL_*###` tokens.

**Current state** (both strings updated with the tag):
```c
// File: xnu-8020.140.41/config/version.c

// for what(1):
const char __kernelVersionString[] __attribute__((used)) =
    "@(#)VERSION: " OSTYPE " Kernel Diversion [pete] ###KERNEL_VERSION_LONG###: "
    "###KERNEL_BUILD_DATE###; ###KERNEL_BUILDER###:###KERNEL_BUILD_OBJROOT###";

// for uname -a and sysctl kern.version:
const char version[] =
    OSTYPE " Kernel Diversion [pete] ###KERNEL_VERSION_LONG###: "
    "###KERNEL_BUILD_DATE###; ###KERNEL_BUILDER###:###KERNEL_BUILD_OBJROOT###";
```

> **Important:** Both strings must be updated. `__kernelVersionString` feeds `what(1)`. `version[]` feeds `uname -a` and `sysctl kern.version`. If only one is updated, they will disagree.

> **Make pitfall:** `config/version.c` is a template processed by `newvers.pl` on every build — but `make` only recompiles it when the file's mtime changes. If you rsync the file and the content changed but make's `.o` is newer, touch the file first: `touch config/version.c` then re-run make.

After the build, verify with:
```bash
uname -a
sysctl kern.version

what /Users/xnuman/xnu_monterey_nospace/xnu-8020.140.41/BUILD/obj/DEVELOPMENT_X86_64/kernel.development
# Should show: Kernel Diversion [pete]


strings /Users/xnuman/xnu_monterey_nospace/xnu-8020.140.41/BUILD/obj/DEVELOPMENT_X86_64/kernel.development | grep "Darwin"
# @(#)VERSION: Darwin 3V3 B1T 7H3 @PPL3 [p3t3] 21.6.0: Sun Apr 12 13:43:34 PDT 2026; xnuman:xnu-8020.140.41/BUILD/obj/DEVELOPMENT_X86_64
# Darwin  ><(((*>  >~~~> 3V3 B1T 7H3 @PPL3 <~~~<  <(*)))><
# Darwin
```

### `config/MasterVersion` — the kernel version number

```
21.6.0
```

This sets the three-part version number seen everywhere. If you want to distinguish your builds:

```
21.6.1
```

Note: changing major/minor here does not affect SIP enforcement (that's tied to the OS install, not the kernel number). It can affect version comparisons inside kexts/drivers that check `version_major`.

### `bsd/kern/bsd_init.c` — the boot copyright banner printed before the console is up

```c
// Line ~207: printed by printf(copyright) at bsd_init() time
const char *const copyright =
    "Copyright (c) 1982, 1986, 1989, 1991, 1993\n\t"
    "The Regents of the University of California. "
    "All rights reserved.\n\n";
```

You can append a line:
```c
const char *const copyright =
    "Copyright (c) 1982, 1986, 1989, 1991, 1993\n\t"
    "The Regents of the University of California. "
    "All rights reserved.\n\n"
    "Kernel Diversion [pete] — custom build\n\n";
```

This text is printed to the serial console and system log during `bsd_init`. With `-v` boot-arg it appears on screen.

---

## 2. Sysctls — Exposing Your Own Knobs

Adding a sysctl is the safest, most practical way to add live tunables or diagnostic readouts to your kernel without touching core logic.

**File:** `bsd/kern/kern_sysctl.c`

### Read-only string (e.g. owner banner):

```c
// Add after the existing version sysctl (~line 1768):
static const char kern_owner[] = "pete";
SYSCTL_STRING(_kern, OID_AUTO, owner,
    CTLFLAG_RD | CTLFLAG_LOCKED,
    __DECONST(char *, kern_owner), 0, "Kernel owner tag");
```

Test from userspace:
```bash
sysctl kern.owner
# kern.owner: pete
```

### Read/write integer tunable:

```c
static int my_debug_level = 0;
SYSCTL_INT(_debug, OID_AUTO, pete_debug,
    CTLFLAG_RW | CTLFLAG_LOCKED,
    &my_debug_level, 0, "pete's debug level");
```

Set at runtime:
```bash
sudo sysctl -w debug.pete_debug=1
```

### `SYSCTL_PROC` — dynamic handler for complex reads:

```c
static int
sysctl_pete_status(__unused struct sysctl_oid *oidp,
    __unused void *arg1, __unused int arg2,
    struct sysctl_req *req)
{
    char buf[128];
    int n = scnprintf(buf, sizeof(buf),
        "alive on cpu %d uptime %llu ns\n",
        cpu_number(), mach_absolute_time());
    return sysctl_io_string(req, buf, n + 1, 0, NULL);
}
SYSCTL_PROC(_kern, OID_AUTO, pete_status,
    CTLTYPE_STRING | CTLFLAG_RD | CTLFLAG_LOCKED,
    0, 0, sysctl_pete_status, "A", "pete's custom status");
```

---

## 3. Scheduler

**File:** `osfmk/kern/sched_prim.c`

The scheduler has several `TUNABLE()` macros — these mean the value can be overridden at boot via NVRAM boot-args with the given name, **or** by changing the constant and rebuilding.

| Constant | Location (line ~) | Default | What it controls |
|---|---|---|---|
| `DEFAULT_PREEMPTION_RATE` | line 242 | `100` | Timeslice rate (Hz). Lower = longer quanta. E.g. `50` → 20ms quanta |
| `DEFAULT_BG_PREEMPTION_RATE` | line 246 | `400` | Background thread timeslice rate |
| `MAX_UNSAFE_QUANTA` | line 249 | `800` | Quanta before an unsafe thread is marked "hogging" |
| `MAX_POLL_QUANTA` | line 252 | `2` | Polling thread quantum limit |

**Boot-arg override** (no recompile needed):
```bash
sudo nvram boot-args="kcsuffix=development ... preempt=50"
```

**Source change** example — halve the preemption rate for lower context-switch overhead:
```c
// osfmk/kern/sched_prim.c line ~242
#define DEFAULT_PREEMPTION_RATE   50    /* was 100 — 20ms quanta instead of 10ms */
```

After a change here, the boot log will confirm:
```
standard timeslicing quantum is 20000 us
```

### Scheduler algorithms

XNU ships with multiple scheduler implementations selectable via boot-arg:

| Boot-arg | File | Description |
|---|---|---|
| (default) | `sched_clutch.c` | Clutch scheduler — Apple's current default, work-loop aware |
| `sched=traditional` | `sched_traditional.c` | Classic BSD MLFQ run-queue |
| `sched=dualq` | `sched_dualq.c` | Two-level run queue (foreground/background split) |
| `sched=multiq` | `sched_multiq.c` | Multi-queue variant |

You can add your own by implementing the `sched_dispatch_table` vtable defined in `osfmk/kern/sched.h`.

---

## 4. VM / Memory Management

**Files:** `osfmk/vm/vm_pageout.c`, `osfmk/vm/vm_fault.c`, `osfmk/vm/bsd_vm.c`

Key tunable values (set as global variables, initialized from physical RAM at `vm_pageout_scan_init()`):

| Variable | What it controls |
|---|---|
| `vm_page_free_target` | Number of free pages the daemon targets to maintain |
| `vm_page_free_min` | Hard floor; below this, the system is under serious pressure |
| `vm_page_free_reserved` | Pages reserved for kernel wiring only |

You can add SYSCTL_INT entries for these to make them live-tunable, e.g.:

```c
// In osfmk/vm/vm_pageout.c, after the variable declarations:
SYSCTL_UINT(_vm, OID_AUTO, page_free_min,
    CTLFLAG_RD | CTLFLAG_LOCKED,
    &vm_page_free_min, 0, "VM page free minimum");
```

This lets you watch memory pressure thresholds without recompiling.

---

## 5. System Call Interception (BSD layer)

**File:** `bsd/kern/kern_exec.c` — process execution path  
**File:** `bsd/kern/kern_fork.c` — fork/vfork  
**File:** `bsd/kern/kern_proc.c` — process lifecycle  
**File:** `bsd/kern/sys_generic.c` — `read`/`write`/`ioctl` dispatch

Every BSD syscall goes through the syscall table in `bsd/kern/syscalls.master` (the authoritative list) which generates `bsd/kern/init_sysent.c`.

To add logging to a syscall, find its implementation and add `kprintf` or `os_log`:

```c
// Example: log every exec in kern_exec.c, find exec_activate_image():
kprintf("[pete] exec: pid %d execing %s\n", 
        proc_pid(p), vnode_getname(nd.ni_vp));
```

Use `os_log(OS_LOG_DEFAULT, ...)` for production (goes to unified log). Use `kprintf(...)` for debug output that appears on serial console.

To add a **new syscall**:

1. Add an entry to `bsd/kern/syscalls.master` (assigns a number and prototype). Use `NO_SYSCALL_STUB` to suppress libSystem stub generation — callers invoke the syscall via `syscall(N, ...)` directly.
2. Register the new `.c` file in `bsd/conf/files` as `standard` (or `optional development` for dev/debug-only handlers).
3. Implement the handler in `bsd/kern/`. The standard signature is:
   ```c
   int my_syscall(struct proc *p, struct my_syscall_args *uap, int32_t *retval);
   ```
   The `my_syscall_args` struct is auto-generated into `bsd/sys/sysproto.h` — include `<sys/sysproto.h>` in your implementation file.
4. Run the normal top-level `make` on xnu-xnu. The build system automatically regenerates all derived files from `syscalls.master` via `makesyscalls.sh`. There is no separate `make syscalls` target.

> **Five files are regenerated**, not just `init_sysent.c`: `bsd/kern/init_sysent.c`, `bsd/kern/syscalls.c`, `bsd/sys/syscall.h`, `bsd/sys/sysproto.h`, and `security/audit/audit_syscalls.c`.

---

## 6. MAC Framework Hooks (Security Policy)

**File:** `security/mac_base.c`, `security/mac_policy.h`

The MAC framework lets you register a policy module that intercepts security-relevant operations across the kernel. Every check is a hook in `struct mac_policy_ops`.

You can add a minimal always-allow policy that logs calls:

```c
// New file: security/pete_policy.c
#include <security/mac_framework.h>
#include <security/mac_policy.h>

static int
pete_proc_check_run_cs_invalid(proc_t p __unused,
    vnode_t v __unused, off_t offset __unused,
    team_id_array_t teamids __unused,
    uint32_t teamidcount __unused,
    int can_load_csblob __unused,
    int is_developer_binary __unused)
{
    kprintf("[pete-policy] exec cs check triggered\n");
    return 0; /* allow */
}

static struct mac_policy_ops pete_policy_ops = {
    .mpo_proc_check_run_cs_invalid = pete_proc_check_run_cs_invalid,
};

mac_policy_handle_t pete_policy_handle;
static struct mac_policy_conf pete_policy_conf = {
    .mpc_name            = "pete_policy",
    .mpc_fullname        = "Pete's custom MAC policy",
    .mpc_labelnames      = NULL,
    .mpc_labelname_count = 0,
    .mpc_ops             = &pete_policy_ops,
    .mpc_loadtime_flags  = MPC_LOADTIME_FLAG_UNLOADOK,
    .mpc_field_off       = NULL,
    .mpc_runtime_flags   = 0,
};
```

Register it with `mac_policy_register` during kernel init. You must add it to the Makefile's source list to get it compiled in.

---

## 7. IOKit Drivers (in-tree kext changes)

**Directory:** `iokit/`

These are compiled into the KC, not loaded separately. Changes to in-tree iokit files (e.g. `IOKit/IOService.cpp`) go into the KC automatically via `kmutil create`.

Useful places to hook:

| File | What it controls |
|---|---|
| `iokit/Kernel/IOService.cpp` | Driver attach/detach lifecycle, matching, `start()`/`stop()` |
| `iokit/Kernel/IOUserClient.cpp` | Userspace ↔ driver IPC (IOKit user clients) |
| `iokit/Kernel/IOMemoryDescriptor.cpp` | DMA/memory mapping |
| `iokit/Kernel/IOPM.cpp` | Power management events |

Example — log every driver `start()`:
```cpp
// In IOService::startCandidate() just before the start() call:
kprintf("[pete] IOKit: starting %s on %s\n",
    candidate->getName(), provider->getName());
```

---

## 8. Panic Customization

**File:** `osfmk/kern/debug.c`

The panic log header is assembled in `handle_debugger_trap()`. Line ~1170:

```c
paniclog_append_noflush("panic(cpu %d caller 0x%lx): ",
    (unsigned) cpu_number(), debugger_panic_caller);
```

You can inject a custom marker:
```c
paniclog_append_noflush("[Kernel Diversion pete] panic(cpu %d caller 0x%lx): ",
    (unsigned) cpu_number(), debugger_panic_caller);
```

This will appear at the top of every panic log and in the NVRAM `aapl,panic-info` blob.

After a panic, retrieve the log from NVRAM (no reboot needed):
```bash
nvram -p | grep aapl,panic-info | awk '{print $2}' | xxd -r -p | gunzip 2>/dev/null | head -50
```

---

## 9. kprintf / Tracing — Adding Your Own Logging

`kprintf()` is the simplest path to kernel output. It goes to:
- The serial console (if `serial=3` in boot-args)
- The kernel log buffer readable via `dmesg` if the system fully boots
- The panic log if you panic before userspace

`os_log()` goes to the Unified Log system (readable with `log show` or Console.app). Available after `STARTUP_SUB_OSLOG` phase.

Pattern for conditional debug output:
```c
// At file scope:
TUNABLE(int, pete_verbose, "pete_verbose", 0);
// In code:
if (__improbable(pete_verbose)) {
    kprintf("[pete] interesting event: %s\n", description);
}
```

Enable at boot:
```bash
sudo nvram boot-args="kcsuffix=development ... pete_verbose=1"
```

---

## 10. Build Incrementally — Avoid Full Rebuilds

When you only change one file, you don't need a full rebuild:

```bash
# 1. Sync just the changed file from Macintosh HD to no-space copy:
rsync -av \
  "/Volumes/Macintosh HD/Users/pete/Developer/xnu-monterey/xnu-8020.140.41/bsd/kern/bsd_init.c" \
  "/Users/xnuman/xnu_monterey_nospace/xnu-8020.140.41/bsd/kern/bsd_init.c"

# 2. Re-link only (rsync updates mtime, make sees the file as newer):
export DEVELOPER_DIR=/Users/xnuman/Xcode_nospace.app/Contents/Developer
SDKROOT="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/SDKs/MacOSX12.3.sdk"
cd /Users/xnuman/xnu_monterey_nospace/xnu-8020.140.41

# Run make — it will only recompile changed files + relink:
make SDKROOT="$SDKROOT" \
  ARCH_CONFIGS=X86_64 KERNEL_CONFIGS=DEVELOPMENT \
  WERROR="" \
  EXTRA_CFLAGS="-Wno-null-pointer-subtraction -Wno-four-char-constants -Wno-error" \
  EXTRA_CXXFLAGS="-Wno-null-pointer-subtraction -Wno-c++11-narrowing -Wno-suggest-override -Wno-suggest-destructor-override -Wno-error"
```

Typical incremental build time for a single changed `.c` file: **~30 seconds**. Only the link step is slow (~2–3 min).

---

## 11. Privilege System — `kern_priv.c` and `mac_priv.c`

### What these files do

**`bsd/kern/kern_priv.c`** implements `priv_check_cred()` — the **central privilege enforcement gate** for the BSD layer. Every kernel subsystem that wants to restrict an operation to privileged callers uses this single function. The logic is:

1. Ask MAC policies: **can this be denied?** (`mac_priv_check`) — any deny wins unconditionally
2. If not denied and UID == 0 (root), **grant** (unless `PRIVCHECK_DEFAULT_UNPRIVILEGED_FLAG` is set)
3. Ask MAC policies: **can this be granted?** (`mac_priv_grant`) — any grant wins
4. Otherwise: return `EPERM`

**`security/mac_priv.c`** is the TrustedBSD MAC Framework hook layer. It iterates all loaded MAC policy modules and calls their `priv_check` / `priv_grant` entry points. This is how SandboxD, AMFI, and similar kexts restrict or extend privileges beyond simple UID=0 checks.

**`bsd/sys/priv.h`** defines all named privilege identifiers. These are integer constants naming *types of operations*, not runtime state. Selected examples:

| Constant | Value | What it guards |
|---|---|---|
| `PRIV_ADJTIME` | 1000 | Set system time adjustment |
| `PRIV_ENDPOINTSECURITY_CLIENT` | 1016 | Connect as an EndpointSecurity client |
| `PRIV_VM_JETSAM` | 6001 | Adjust jetsam configuration |
| `PRIV_VM_FOOTPRINT_LIMIT` | 6002 | Adjust process memory footprint limit |
| `PRIV_NET_PRIVILEGED_TRAFFIC_CLASS` | 10000 | Set `SO_PRIVILEGED_TRAFFIC_CLASS` |
| `PRIV_NET_PRIVILEGED_SOCKET_DELEGATE` | 10001 | Delegate a socket to another process |
| `PRIV_NETINET_RESERVEDPORT` | 11000 | Bind a port below 1024 |
| `PRIV_VFS_SNAPSHOT` | 14002 | Create/rename/delete APFS snapshots |

Yes, these enforce real security — if `priv_check_cred` returns `EPERM`, the calling subsystem aborts the operation.

---

### Tracing privilege checks with DTrace

**Known issue:** On macOS, running `dtrace` without flags auto-includes `/usr/lib/dtrace/darwin.d`, which contains a `uthread_t` typedef that conflicts with kernel type definitions and causes:

```
syntax error near "uthread_t"
```

**Fix:** always pass `-x nolibs` to suppress the auto-include. The `fbt` provider works fine without it.

#### Trace every `priv_check_cred` call (pid, process name, privilege ID):

```bash
sudo dtrace -x nolibs -n '
  fbt::priv_check_cred:entry {
    printf("pid=%d comm=%s priv=%d\n", pid, execname, arg1);
  }
'
```

`arg1` is the `priv` integer — cross-reference against `bsd/sys/priv.h`.

#### Also trace the result (0 = granted, 1 = EPERM):

```bash
sudo dtrace -x nolibs -n '
  fbt::priv_check_cred:return {
    printf("pid=%d comm=%s -> %d\n", pid, execname, arg1);
  }
'
```

#### Watch a specific privilege only (e.g. `PRIV_NETINET_RESERVEDPORT` = 11000):

```bash
sudo dtrace -x nolibs -n '
  fbt::priv_check_cred:entry
  /arg1 == 11000/ {
    printf("reserved-port attempt: pid=%d comm=%s\n", pid, execname);
  }
'
```

#### Combined entry+return showing full decision:

```bash
sudo dtrace -x nolibs -n '
  fbt::priv_check_cred:entry {
    self->priv = arg1;
  }
  fbt::priv_check_cred:return
  /self->priv/ {
    printf("pid=%d %s priv=%d result=%s\n",
      pid, execname, self->priv,
      arg1 == 0 ? "GRANTED" : "DENIED");
    self->priv = 0;
  }
'
```

---

### Patching the decision logic (sysctl-gated bypass)

The privilege identifiers in `priv.h` are compile-time constants — there is no "value" to set at runtime. What you can change is the **decision logic** in `priv_check_cred`.

**Option A — sysctl-controlled bypass table in `kern_priv.c`** (simplest, stays in-tree):

```c
// bsd/kern/kern_priv.c — add at top of priv_check_cred(), before MAC checks:
static int priv_bypass_enabled = 0;
SYSCTL_INT(_kern, OID_AUTO, priv_bypass,
    CTLFLAG_RW | CTLFLAG_LOCKED,
    &priv_bypass_enabled, 0, "Bypass priv_check_cred (debug only)");

int
priv_check_cred(kauth_cred_t cred, int priv, int flags)
{
    if (__improbable(priv_bypass_enabled)) {
        return 0;  /* grant everything — DANGEROUS, debug builds only */
    }
    /* ... existing logic ... */
```

Then at runtime:
```bash
sudo sysctl -w kern.priv_bypass=1   # open the gate
sudo sysctl -w kern.priv_bypass=0   # restore enforcement
```

**Option B — MAC policy `priv_grant` hook** (the designed extensibility point):

Implement `mpo_priv_grant` in your MAC policy (see Section 6). Return `0` for the specific privilege IDs you want to always grant. This is revocable and composable with other policies.

**Option C — LLDB live patch** (development KC with `debug` boot-arg, no recompile):

Set a breakpoint on `priv_check_cred:return`, inspect `$rax` (x86) or `$x0` (ARM), and override it to `0` to force a grant. Useful for one-off testing without a rebuild cycle.

---

## Quick Reference — Files to Edit

| What you want to change | File |
|---|---|
| Kernel version string / name tag | `config/version.c` |
| Kernel version number | `config/MasterVersion` |
| Boot copyright banner | `bsd/kern/bsd_init.c` line ~207 |
| Add custom sysctl knobs | `bsd/kern/kern_sysctl.c` or any `.c` file using `SYSCTL_INT/STRING/PROC` |
| Scheduler quantum / preemption rate | `osfmk/kern/sched_prim.c` line ~242 |
| Swap scheduler algorithm | boot-arg `sched=traditional` or edit `sched_clutch.c` |
| VM memory pressure thresholds | `osfmk/vm/vm_pageout.c` |
| Fork/exec/process lifecycle hooks | `bsd/kern/kern_fork.c`, `kern_exec.c`, `kern_proc.c` |
| Security policy interception | `security/mac_base.c` + new policy file |
| IOKit driver lifecycle | `iokit/Kernel/IOService.cpp` |
| Panic log customization | `osfmk/kern/debug.c` |
| Add a new syscall | `bsd/kern/syscalls.master` + implementation file |
| Privilege enforcement logic | `bsd/kern/kern_priv.c`, `security/mac_priv.c` |
| Privilege identifier constants | `bsd/sys/priv.h` |
