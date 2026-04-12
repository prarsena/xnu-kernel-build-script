## Code change deploy workflow

For the starting point of changing the kernel version info:

```bash

# Sync changes

rsync -av \
  "/Volumes/Macintosh HD/Users/pete/Developer/xnu-monterey/xnu-8020.140.41/config/version.c" \
  "/Users/xnuman/xnu_monterey_nospace/xnu-8020.140.41/config/version.c"

touch /Users/xnuman/xnu_monterey_nospace/xnu-8020.140.41/config/version.c

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

# Set boot params and reboot

sudo nvram boot-args="kcsuffix=development wlan.skywalk.enable=0 -v serial=3 debug=0x8"
sudo reboot

```

After you run `kmutil create` (via the `verify-and-build-kc` script), you can invoke `what` and `strings` on the kernel.development binary:

```bash

DEV_KERNEL="/Users/xnuman/xnu_monterey_nospace/xnu-8020.140.41/BUILD/obj/DEVELOPMENT_X86_64/kernel.development"

what $DEV_KERNEL
#	VERSION: Darwin 21.6.0 | --3V3 B1T 7H3 @PPL3-- [p3t3] | Sun Apr 12 14:11:59 PDT 2026 | xnu-8020.140.41/BUILD/obj/DEVELOPMENT_X86_64 |

strings $DEV_KERNEL | grep "Darwin"
#@(#)VERSION: Darwin 21.6.0 | --3V3 B1T 7H3 @PPL3-- [p3t3] | Sun Apr 12 14:11:59 PDT 2026 | xnu-8020.140.41/BUILD/obj/DEVELOPMENT_X86_64 |
#Darwin

strings $DEV_KERNEL | grep "3V3"   
#@(#)VERSION: Darwin 21.6.0 | --3V3 B1T 7H3 @PPL3-- [p3t3] | Sun Apr 12 14:11:59 PDT 2026 | xnu-8020.140.41/BUILD/obj/DEVELOPMENT_X86_64 |
#  >~~~> 3V3 B1T 7H3 @PPL3 21.6.0 <~~~< 
```

Later, after you bless the kernel and reboot into it, you can print your custom kernel info:

```bash
uname -a
#Darwin xumann 21.6.0   >~~~> 3V3 B1T 7H3 @PPL3 21.6.0 <~~~<    [p3t3] :: Sun Apr 12 14:11:59 PDT 2026    :: xnu-8020.140.41/BUILD/obj/DEVELOPMENT_X86_64 x86_64

uname -v
#  >~~~> 3V3 B1T 7H3 @PPL3 21.6.0 <~~~<    [p3t3] :: Sun Apr 12 14:11:59 PDT 2026    :: xnu-8020.140.41/BUILD/obj/DEVELOPMENT_X86_64

sysctl kern.version
#kern.version:   >~~~> 3V3 B1T 7H3 @PPL3 21.6.0 <~~~< 
# [p3t3] :: Sun Apr 12 14:11:59 PDT 2026 
# :: xnu-8020.140.41/BUILD/obj/DEVELOPMENT_X86_64

```