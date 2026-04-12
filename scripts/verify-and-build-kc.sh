#!/bin/zsh
set -euo pipefail

# Runs KC preflight checks, then executes kmutil create if checks pass.

print_usage() {
  cat <<'EOF'
Usage:
  scripts/verify-and-build-kc.sh \
    --kdk-root <path> \
    --target-root <path> \
    [--kernel <path>] \
    [--symbolset-root <path>] \
    [--boot-path <path>] \
    [--system-path <path>] \
    [--arch x86_64] \
    [--variant development] \
    [--elide-identifier <bundle-id>] ... \
    [--yes] \
    [--no-sudo]

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
  --elide-identifier
                   Repeatable. Exclude this bundle identifier from kmutil input.
  --yes            Do not prompt before running kmutil.
  --no-sudo        Run kmutil without sudo.
EOF
}

fail() {
  echo "[FAIL] $*" >&2
  exit 1
}

note() {
  echo "[INFO] $*"
}

kernel=""
kdk_root=""
target_root=""
symbolset_root=""
boot_path=""
system_path=""
arch="x86_64"
variant="development"
auto_yes=0
use_sudo=1
elide_ids=()

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
    --elide-identifier) elide_ids+=("$2"); shift 2 ;;
    --yes) auto_yes=1; shift ;;
    --no-sudo) use_sudo=0; shift ;;
    -h|--help) print_usage; exit 0 ;;
    *) fail "Unknown argument: $1" ;;
  esac
done

[[ -n "$kdk_root" ]] || fail "--kdk-root is required"
[[ -n "$target_root" ]] || fail "--target-root is required"

script_dir="$(cd "$(dirname "$0")" && pwd)"
verify_script="${script_dir}/verify-kc-prereqs.sh"
[[ -x "$verify_script" ]] || fail "Verifier script is missing or not executable: $verify_script"

kdk_ext="${kdk_root}/System/Library/Extensions"
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

  # If a symbolset path from an XNU build tree is provided, prefer the
  # matching built kernel over a potentially stale target-root kernel.
  if [[ -n "$symbolset_root" ]]; then
    local_obj_root=""
    if [[ -f "${symbolset_root}/System.kext/PlugIns/BSDKernel.kext/Info.plist" ]]; then
      local_obj_root="$(cd "${symbolset_root}/.." && pwd)"
    elif [[ -f "${symbolset_root}/BSDKernel.kext/Info.plist" ]]; then
      local_obj_root="$(cd "${symbolset_root}/../../.." && pwd)"
    fi

    if [[ -n "$local_obj_root" && -f "${local_obj_root}/kernel.development" ]]; then
      kernel="${local_obj_root}/kernel.development"
      note "Auto-selected built kernel from symbolset tree: ${kernel}"
    fi
  fi
fi

verify_cmd=("$verify_script" --kernel "$kernel" --kdk-root "$kdk_root" --target-root "$target_root" --arch "$arch" --variant "$variant" --boot-path "$boot_path" --system-path "$system_path")
if [[ -n "$symbolset_root" ]]; then
  verify_cmd+=(--symbolset-root "$symbolset_root")
fi

echo "== Running preflight verifier =="
"${verify_cmd[@]}"

declare -a kmutil_cmd
if (( use_sudo )); then
  kmutil_cmd=(sudo kmutil)
else
  kmutil_cmd=(kmutil)
fi

kmutil_cmd+=(create -v -a "$arch" -Z -V "$variant" -n boot system -B "$boot_path" -S "$system_path" -k "$kernel")
if [[ -n "$symbolset_root" ]]; then
  kmutil_cmd+=(-r "$symbolset_root")
fi
kmutil_cmd+=(-r "$kdk_ext" -r "$tgt_ext" -r "$tgt_drvext")
for id in "${elide_ids[@]}"; do
  kmutil_cmd+=(--elide-identifier "$id")
done

echo
echo "== Command to execute =="
printf '%q ' "${kmutil_cmd[@]}"
echo

if (( ! auto_yes )); then
  echo -n "Proceed with kmutil create? [y/N]: "
  read -r answer
  if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
    echo "Aborted."
    exit 0
  fi
fi

echo
echo "== Running kmutil create =="
"${kmutil_cmd[@]}"

echo
echo "[ OK ] KC build completed"
