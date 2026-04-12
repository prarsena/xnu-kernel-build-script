#!/bin/zsh
set -euo pipefail

# Verifies inputs needed to build a development KC with kmutil.
# It catches the common missing-symbolset case before kmutil fails with code 31.

print_usage() {
  cat <<'EOF'
Usage:
  scripts/verify-kc-prereqs.sh \
    --kdk-root <path> \
    --target-root <path> \
    [--kernel <path>] \
    [--symbolset-root <path>] \
    [--boot-path <path>] \
    [--system-path <path>] \
    [--arch x86_64] \
    [--variant development]

Required:
  --kdk-root       KDK root directory that contains System/Library/Extensions.
  --target-root    Mounted target root (for example ~/live_mount).

Optional:
  --kernel         Path to kernel used with kmutil -k.
                   Default: <target-root>/System/Library/Kernels/kernel.development
  --symbolset-root Path containing System.kext symbolset plugins.
                   Example: /tmp/xnu-dst/System/Library/Extensions/System.kext/PlugIns
  --boot-path      Output BootKernelExtensions path.
  --system-path    Output SystemKernelExtensions path.
  --arch           Default: x86_64
  --variant        Default: development
EOF
}

fail() {
  echo "[FAIL] $*" >&2
  exit 1
}

warn() {
  echo "[WARN] $*"
}

pass() {
  echo "[ OK ] $*"
}

require_file() {
  local p="$1"
  local label="$2"
  [[ -f "$p" ]] || fail "$label is missing: $p"
  [[ -r "$p" ]] || fail "$label is not readable: $p"
  pass "$label exists"
}

require_dir() {
  local p="$1"
  local label="$2"
  [[ -d "$p" ]] || fail "$label is missing: $p"
  [[ -r "$p" ]] || fail "$label is not readable: $p"
  pass "$label exists"
}

check_symbol_in_bin() {
  local bin="$1"
  local sym="$2"
  local symbols=""
  local nm_output=""
  local nm_status=0

  if command -v nm >/dev/null 2>&1; then
    nm_output="$(nm -gj "$bin" 2>&1)" || nm_status=$?
    if (( nm_status != 0 )); then
      fail "nm failed while checking $(basename "$bin"): ${nm_output}. Fix xcode-select or set DEVELOPER_DIR."
    fi

    symbols="$nm_output"
    # Avoid pipefail+grep -q SIGPIPE false negatives on large symbol lists.
    if grep -Fqx -- "$sym" <<< "$symbols"; then
      pass "$(basename "$bin") exports ${sym}"
      return 0
    fi
    fail "$(basename "$bin") does not export ${sym}"
  fi

  warn "nm not available; skipped symbol check for ${sym} in $bin"
}

kernel=""
kdk_root=""
target_root=""
symbolset_root=""
boot_path=""
system_path=""
arch="x86_64"
variant="development"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kernel) kernel="$2"; shift 2 ;;
    --kdk-root) kdk_root="$2"; shift 2 ;;
    --target-root) target_root="$2"; shift 2 ;;
    --symbolset-root) symbolset_root="$2"; shift 2 ;;
    --boot-path) boot_path="$2"; shift 2 ;;
    --system-path) system_path="$2"; shift 2 ;;
    --arch) arch="$2"; shift 2 ;;
    --variant) variant="$2"; shift 2 ;;
    -h|--help) print_usage; exit 0 ;;
    *) fail "Unknown argument: $1" ;;
  esac
done

[[ -n "$kdk_root" ]] || fail "--kdk-root is required"
[[ -n "$target_root" ]] || fail "--target-root is required"

kdk_ext="${kdk_root}/System/Library/Extensions"
kdk_kernels="${kdk_root}/System/Library/Kernels"
tgt_ext="${target_root}/System/Library/Extensions"
tgt_drvext="${target_root}/System/Library/DriverExtensions"
tgt_kc="${target_root}/System/Library/KernelCollections"

if [[ -z "$boot_path" ]]; then
  boot_path="${tgt_kc}/BootKernelExtensions.kc.${variant}"
fi
if [[ -z "$system_path" ]]; then
  system_path="${tgt_kc}/SystemKernelExtensions.kc.${variant}"
fi
if [[ -z "$kernel" ]]; then
  kernel="${target_root}/System/Library/Kernels/kernel.development"
fi

echo "== Verifying KC prerequisites =="
require_file "$kernel" "Kernel (-k)"
require_dir "$kdk_ext" "KDK extensions root"
require_dir "$kdk_kernels" "KDK kernels root"
require_dir "$tgt_ext" "Target System/Library/Extensions"
require_dir "$tgt_drvext" "Target System/Library/DriverExtensions"
require_dir "$tgt_kc" "Target KernelCollections directory"

if [[ -n "$symbolset_root" ]]; then
  require_dir "$symbolset_root" "Symbolset plugin root"

  bsd_plist="${symbolset_root}/BSDKernel.kext/Info.plist"
  bsd_bin="${symbolset_root}/BSDKernel.kext/BSDKernel"
  pvt_plist="${symbolset_root}/Private.kext/Info.plist"
  pvt_bin="${symbolset_root}/Private.kext/Private"

  require_file "$bsd_plist" "BSDKernel.kext Info.plist"
  require_file "$pvt_plist" "Private.kext Info.plist"
  require_file "$bsd_bin" "BSDKernel.kext binary"
  require_file "$pvt_bin" "Private.kext binary"

  check_symbol_in_bin "$bsd_bin" "_vfs_getvfs_with_vfsops"
  check_symbol_in_bin "$pvt_bin" "_tty_trylock"
  check_symbol_in_bin "$pvt_bin" "_csvnode_invalidate_flags"
else
  warn "--symbolset-root not provided."
  warn "If kmutil reports missing _vfs_getvfs_with_vfsops/_tty_trylock/_csvnode_invalidate_flags,"
  warn "build/install XNU symbolsets and pass --symbolset-root to this script."
fi

echo
echo "== Suggested kmutil command =="
echo "sudo kmutil create -v -a ${arch} -Z -V ${variant} \\"
echo "  -n boot system \\"
echo "  -B \"${boot_path}\" \\"
echo "  -S \"${system_path}\" \\"
echo "  -k \"${kernel}\" \\"
if [[ -n "$symbolset_root" ]]; then
  echo "  -r \"${symbolset_root}\" \\"
fi
echo "  -r \"${kdk_ext}\" \\"
echo "  -r \"${tgt_ext}\" \\"
echo "  -r \"${tgt_drvext}\""

echo
pass "Verification complete"
