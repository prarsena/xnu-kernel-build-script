## bsd/kern/syscalls.master

syscalls.master is the **authoritative source of truth** for every BSD system call in XNU. It's not compiled directly — it's a DSL that `makesyscalls.sh` processes to auto-generate four files:

| Generated file | What it becomes |
|---|---|
| `bsd/kern/init_sysent.c` | The `sysent[]` table — the actual dispatch array indexed by syscall number |
| `bsd/kern/syscalls.c` | String names table (for `ktrace`, panic backtraces) |
| `bsd/sys/syscall.h` | `SYS_read = 3`, `SYS_fork = 2`, etc. — the constants userspace uses |
| `bsd/sys/sysproto.h` | Kernel-side function prototypes for every handler |
| `security/audit_syscalls.c` | BSM audit event mappings |

The format of each line in syscalls.master:

```
NUMBER   AUDIT_EVENT   FILES   { return_type name(args) [NO_SYSCALL_STUB]; }
```

- **NUMBER** — the `SYS_*` number sent in `rax`/`x16` by the userspace `syscall` instruction. Must be strictly sequential.
- **AUDIT_EVENT** — which BSM audit event fires for this call (`AUE_NULL` = no audit).
- **FILES** — which files to emit the entry into: `ALL`, or any combination of `T`(table) `N`(names) `H`(header) `P`(prototypes).
- **Prototype** — the kernel-side handler signature. `user_addr_t` means a userspace pointer (handled 32/64 agnostically). `NO_SYSCALL_STUB` means libSystem won't generate a stub (the call is made differently, e.g. via `__pthread_kill`).
- Entries marked `enosys` or `nosys` are reserved/retired slots kept to preserve numbering.

---

## What's in `bsd/kern/` as a whole

This directory is essentially **the entire BSD personality of XNU**. It implements everything that makes macOS look like a Unix to userspace. Rough groupings:

**Process & threading lifecycle**
- `kern_fork.c` — `fork()`, `vfork()`
- `kern_exec.c` — `execve()`, image activation, dyld handoff
- `kern_exit.c` — `exit()`, `wait4()`, zombie reaping
- `kern_proc.c` — process table, `proc` structure lifecycle
- `kern_sig.c` — signal delivery, `sigaction`, `kill`
- `kern_synch.c` — `sleep`/`wakeup`, `tsleep`, condition variables

**Credentials & security**
- `kern_credential.c` — `kauth_cred_t` lifecycle, UID/GID manipulation
- kern_priv.c — `priv_check_cred()` (privilege gate)
- `kern_cs.c` — code signing enforcement
- `kern_csr.c` — SIP (System Integrity Protection) state
- `kern_authorization.c` — kauth scope/listener framework
- `kern_prot.c` — `setuid`, `setgid`, `getgroups`
- `policy_check.c` — additional policy checks

**File descriptors & I/O**
- `kern_descrip.c` — fd table, `dup`, `dup2`, `close`, `fcntl`
- `sys_generic.c` — `read`, `write`, `ioctl`, `select`, `poll` dispatch
- `kern_guarded.c` — guarded file descriptors (crash-safe fd handles)
- `kern_lockf.c` — POSIX file locking (`fcntl F_SETLK`)
- `kern_aio.c` — POSIX async I/O

**Virtual memory (BSD side)**
- `kern_mman.c` — `mmap`, `munmap`, `mprotect`, `madvise`, `mincore`
- `ubc_subr.c` — Unified Buffer Cache, vnode/VM object coupling

**Networking glue**
- `uipc_socket.c`, `uipc_socket2.c` — `socket()`, accept/connect state machine
- `uipc_syscalls.c` — `bind`, `connect`, `listen`, `sendto`, `recvfrom`
- `uipc_mbuf.c` / `kpi_mbuf.c` — mbuf allocator and KPI for drivers
- `sys_socket.c` — `setsockopt`/`getsockopt`
- `uipc_usrreq.c` — Unix domain sockets

**Sysctls & tunables**
- `kern_sysctl.c` — `sysctl(3)` handler, static OID tree registration
- `kern_newsysctl.c` — dynamic sysctl registration/traversal
- `kern_mib.c` — `CTL_KERN` subtree (kern.version, kern.hostname, etc.)
- `kern_resource.c` — `getrusage`, `setrlimit`, `getpriority`

**Time**
- `kern_clock.c` — `gettimeofday`, `clock_gettime`, `adjtime`
- `kern_time.c` — `nanosleep`, `setitimer`, `getitimer`
- `kern_ntptime.c` — NTP kernel discipline (`ntp_adjtime`)

**IPC**
- `sysv_msg.c`, `sysv_sem.c`, `sysv_shm.c`, `sysv_ipc.c` — SysV IPC (msgget, semop, shmget)
- `posix_sem.c`, `posix_shm.c` — POSIX named semaphores and shared memory
- `sys_ulock.c` — `ulock_wait`/`ulock_wake` (Swift/libdispatch's futex)
- `sys_eventlink.c` — `eventlink` (newer cross-process sync primitive)

**Execution**
- `mach_loader.c` — Mach-O / FAT binary parser, segment mapping, dyld launch
- `mach_fat.c` — FAT (universal binary) slice selection
- `imageboot.c` — `kern.bootuuid`, ramdisk-based boot

**TTY / terminal**
- `tty.c`, `tty_pty.c`, `tty_ptmx.c` — TTY discipline, BSD ptys, ptmx

**Memory status / jetsam**
- `kern_memorystatus.c` — jetsam priority lists, OOM killer
- `kern_memorystatus_freeze.c` — app freezing
- `kern_memorystatus_notify.c` — pressure notifications to processes

**Observability**
- `kdebug.c` / `kdebug_common.c` — `kdebug` tracepoint infrastructure (Instruments/`ktrace` backend)
- `stackshot.c` — `stackshot` syscall (produces the data Spindump/Instruments parse)
- `subr_prf.c` — `kprintf`, `printf` backend, panic output
- `subr_log.c` — klog and syslog kernel side
- `kern_backtrace.c` — in-kernel stack unwinder

**Misc**
- `bsd_init.c` — BSD layer initialization, called from `kernel_bootstrap`
- `kern_malloc.c` — `MALLOC` / `FREE` wrappers (thin layer over zone allocator)
- `makesyscalls.sh` — the script that processes syscalls.master
- syscalls.master — this file

---

syscalls.master is the single most important file to understand if you want to add or instrument a syscall — everything else derives from it.

---

## Custom Syscalls: pete_log (552) and pete_gettimeofday (553)

Two custom syscalls have been added to this kernel build. Both use `NO_SYSCALL_STUB` — they are not exposed through libSystem and are called via `syscall(N, ...)` from userspace.

### Syscall 552 — `pete_log`

**Implementation:** `bsd/kern/kern_syscallmefordinner.c`

**`syscalls.master` entry:**
```
552  AUE_NULL  ALL  { int pete_log(user_addr_t msg, user_size_t len) NO_SYSCALL_STUB; }
```

**What it does:** Copies a userspace string (up to 255 bytes) into kernel memory and emits it via `kprintf`. Output goes to `dmesg` and to the serial console when `serial=3` is in boot-args.

**Calling convention:**
```c
#include <unistd.h>
#include <sys/syscall.h>

const char *msg = "syscall me for dinner";
syscall(552, msg, strlen(msg));
```

**Errors:** `EINVAL` if `len` is 0 or > 255; `EFAULT` on a bad pointer.

**To modify:** Edit `bsd/kern/kern_syscallmefordinner.c`. Change `PETE_LOG_MAX` to adjust max length. Swap `kprintf` for `os_log(OS_LOG_DEFAULT, ...)` to route output to the Unified Log instead of serial.

---

### Syscall 553 — `pete_gettimeofday`

**Implementation:** `bsd/kern/kern_pete_time.c`

**`syscalls.master` entry:**
```
553  AUE_NULL  ALL  { int pete_gettimeofday(user_addr_t tp, user_addr_t tzp) NO_SYSCALL_STUB; }
```

**What it does:** A clone of `gettimeofday(2)` with a live-tunable sysctl offset. Returns wall-clock time via `copyout` into the caller's `struct timeval`. The `tzp` argument is accepted but always returns a zeroed `struct timezone` (timezone has been deprecated since POSIX.1-2008). The skew sysctl lets you demonstrate custom kernel behavior without a reboot.

**Calling convention:**
```c
#include <unistd.h>
#include <sys/syscall.h>
#include <sys/time.h>

struct timeval tv;
int err = (int)syscall(553, &tv, NULL);
if (err == 0) {
    printf("pete time: %ld.%06d\n", (long)tv.tv_sec, tv.tv_usec);
}
```

**Errors:** `EFAULT` on a bad pointer.

**Live skew tunable (no reboot needed):**
```bash
# Apply +1 hour offset:
sudo sysctl -w kern.pete_time_skew=3600

# Verify:
sysctl kern.pete_time_skew

# Restore:
sudo sysctl -w kern.pete_time_skew=0
```

**To modify:** Edit `bsd/kern/kern_pete_time.c`. The skew is applied to `secs` after `clock_gettimeofday()` and before `copyout`. Add any transform here — multiply, quantize, add jitter, etc.

---

### Rebuild after modifying a custom syscall

**Implementation change only** (no `syscalls.master` edits) — sync the changed `.c` and run an incremental build:

```bash
# From Macintosh HD, sync changed file to the no-space build root:
rsync -av \
  "/Volumes/Macintosh HD/Users/pete/Developer/xnu-monterey/xnu-8020.140.41/bsd/kern/kern_pete_time.c" \
  "/Users/xnuman/xnu_monterey_nospace/xnu-8020.140.41/bsd/kern/kern_pete_time.c"

# Incremental build on xnu-xnu (~30s compile + 2-3 min link):
export DEVELOPER_DIR=/Users/xnuman/Xcode_nospace.app/Contents/Developer
SDKROOT="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/SDKs/MacOSX12.3.sdk"
cd /Users/xnuman/xnu_monterey_nospace/xnu-8020.140.41
make SDKROOT="$SDKROOT" ARCH_CONFIGS=X86_64 KERNEL_CONFIGS=DEVELOPMENT \
  WERROR="" \
  EXTRA_CFLAGS="-Wno-null-pointer-subtraction -Wno-four-char-constants -Wno-error" \
  EXTRA_CXXFLAGS="-Wno-null-pointer-subtraction -Wno-c++11-narrowing -Wno-suggest-override -Wno-suggest-destructor-override -Wno-error"
```

**`syscalls.master` change** (new syscall, different signature, or new number) — also sync `syscalls.master` and `bsd/conf/files` before building. The build regenerates `init_sysent.c`, `syscalls.c`, `syscall.h`, `sysproto.h`, and `audit_syscalls.c` automatically.

---

### Adding a third custom syscall

1. Pick the next number (currently **554**).
2. Add an entry to `bsd/kern/syscalls.master` after 553.
3. Create `bsd/kern/kern_<name>.c` implementing `int <name>(struct proc *p, struct <name>_args *uap, int32_t *retval)`.
4. Add `bsd/kern/kern_<name>.c  standard` to `bsd/conf/files` (near the other custom entries at line ~471).
5. Run a full build — `sysproto.h` will pick up the new args struct automatically.

---

### Testing on the booted target kernel

**Smoke test — run on xnu-xnu after booting the custom KC:**
```bash
# 1. pete_log — verify kprintf output in dmesg
sudo python3 -c "import ctypes; ctypes.CDLL(None).syscall(552, b'syscall me for dinner', 21)"
dmesg | grep pete-dinner
# expect:  [pete-dinner] syscall me for dinner

# 2. pete_gettimeofday — should match system time within 1 second
python3 -c "
import ctypes, struct, time
buf = ctypes.create_string_buffer(16)
ctypes.CDLL(None).syscall(553, buf, None)
pete_sec = struct.unpack('Q', buf[:8])[0]
sys_sec = int(time.time())
print(f'pete={pete_sec}  sys={sys_sec}  delta={pete_sec - sys_sec}')
"

# 3. Verify the skew sysctl exists and works
sysctl kern.pete_time_skew        # expect: kern.pete_time_skew: 0
sudo sysctl -w kern.pete_time_skew=3600
python3 -c "
import ctypes, struct, time
buf = ctypes.create_string_buffer(16)
ctypes.CDLL(None).syscall(553, buf, None)
pete_sec = struct.unpack('Q', buf[:8])[0]
print(f'skew delta = {pete_sec - int(time.time())}')  # expect: ~3600
"
sudo sysctl -w kern.pete_time_skew=0
```

**DTrace probes on the custom syscalls:**
```bash
sudo dtrace -x nolibs -n '
  syscall::pete_log:entry          { printf("pete_log: pid=%d comm=%s", pid, execname); }
  syscall::pete_gettimeofday:entry { printf("pete_gettimeofday: pid=%d comm=%s", pid, execname); }
'
```

**If a syscall returns `ENOSYS` (38):** The KC was built from a kernel that didn't include the new entries — verify the build used the updated `syscalls.master` and that `init_sysent.c` in `BUILD/obj/` was regenerated (check its mtime vs. `syscalls.master`).