## Code change deploy


```bash

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

# set boot commands and reboot
sudo nvram boot-args="kcsuffix=development wlan.skywalk.enable=0 -v serial=3 debug=0x8"
sudo reboot

```