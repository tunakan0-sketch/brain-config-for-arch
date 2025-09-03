#!/bin/bash

reboot_brain () {
  umount /boot
  mount / -o remount,ro
  sync
  reboot -f
  sleep 5
  exit 0
}

check_commands () {
  if ! command -v dialog > /dev/null; then
      echo "dialog not found"
      sleep 5
      return 1
  fi
  for COMMAND in grep cut sed parted fdisk findmnt; do
    if ! command -v $COMMAND > /dev/null; then
      FAIL_REASON="$COMMAND not found"
      return 1
    fi
  done
  return 0
}

get_variables () {
  ROOT_PART_DEV=$(findmnt / -o source -n)
  ROOT_PART_NAME=$(echo "$ROOT_PART_DEV" | cut -d "/" -f 3)
  ROOT_DEV_NAME=$(echo /sys/block/*/"${ROOT_PART_NAME}" | cut -d "/" -f 4)
  ROOT_DEV="/dev/${ROOT_DEV_NAME}"
  ROOT_PART_NUM=$(cat "/sys/block/${ROOT_DEV_NAME}/${ROOT_PART_NAME}/partition")

  BOOT_PART_DEV=$(findmnt /boot -o source -n)
  BOOT_PART_NAME=$(echo "$BOOT_PART_DEV" | cut -d "/" -f 3)
  BOOT_DEV_NAME=$(echo /sys/block/*/"${BOOT_PART_NAME}" | cut -d "/" -f 4)
  BOOT_PART_NUM=$(cat "/sys/block/${BOOT_DEV_NAME}/${BOOT_PART_NAME}/partition")

  OLD_DISKID=$(fdisk -l "$ROOT_DEV" | sed -n 's/Disk identifier: 0x\([^ ]*\)/\1/p')

  ROOT_DEV_SIZE=$(cat "/sys/block/${ROOT_DEV_NAME}/size")
  TARGET_END=$((ROOT_DEV_SIZE - 1))

  PARTITION_TABLE=$(parted -m "$ROOT_DEV" unit s print | tr -d 's')

  LAST_PART_NUM=$(echo "$PARTITION_TABLE" | tail -n 1 | cut -d ":" -f 1)

  ROOT_PART_LINE=$(echo "$PARTITION_TABLE" | grep -e "^${ROOT_PART_NUM}:")
  ROOT_PART_START=$(echo "$ROOT_PART_LINE" | cut -d ":" -f 2)
  ROOT_PART_END=$(echo "$ROOT_PART_LINE" | cut -d ":" -f 3)
}

fix_partuuid() {
  mount -o remount,rw "$ROOT_PART_DEV"
  mount -o remount,rw "$BOOT_PART_DEV"
  
  # Arch Linuxではhwrngデバイスがないことがあるのでurandomにフォールバック
  if [ -c /dev/hwrng ]; then
    DISKID="$(tr -dc 'a-f0-9' < /dev/hwrng | dd bs=1 count=8 2>/dev/null)"
  else
    DISKID="$(tr -dc 'a-f0-9' < /dev/urandom | dd bs=1 count=8 2>/dev/null)"
  fi
  
  fdisk "$ROOT_DEV" > /dev/null <<EOF
x
i
0x$DISKID
r
w
EOF
  if [ "$?" -eq 0 ]; then
    sed -i "s/${OLD_DISKID}/${DISKID}/g" /etc/fstab
    
    # Arch Linuxでは複数のbootloaderの可能性があるので対応
    if [ -f /boot/cmdline.txt ]; then
      # Raspberry Pi用のcmdline.txt
      sed -i "s/${OLD_DISKID}/${DISKID}/" /boot/cmdline.txt
    fi
    
    # systemd-bootの場合
    if [ -d /boot/loader/entries ]; then
      find /boot/loader/entries -name "*.conf" -exec sed -i "s/${OLD_DISKID}/${DISKID}/g" {} \;
    fi
    
    # GRUBの場合は自動で処理されるのでスキップ
    
    sync
  fi

  mount -o remount,ro "$ROOT_PART_DEV"
  mount -o remount,ro "$BOOT_PART_DEV"
}

check_variables () {
  if [ "$BOOT_DEV_NAME" != "$ROOT_DEV_NAME" ]; then
      FAIL_REASON="Boot and root partitions are on different devices"
      return 1
  fi

  if [ "$ROOT_PART_NUM" -ne "$LAST_PART_NUM" ]; then
    FAIL_REASON="Root partition should be last partition"
    return 1
  fi

  if [ "$ROOT_PART_END" -gt "$TARGET_END" ]; then
    FAIL_REASON="Root partition runs past the end of device"
    return 1
  fi

  if [ ! -b "$ROOT_DEV" ] || [ ! -b "$ROOT_PART_DEV" ] || [ ! -b "$BOOT_PART_DEV" ] ; then
    FAIL_REASON="Could not determine partitions"
    return 1
  fi
}

main () {
  get_variables

  if ! check_variables; then
    return 1
  fi

  if [ "$ROOT_PART_END" -eq "$TARGET_END" ]; then
    reboot_brain
  fi

  if ! parted -m "$ROOT_DEV" u s resizepart "$ROOT_PART_NUM" "$TARGET_END"; then
    FAIL_REASON="Root partition resize failed"
    return 1
  fi

  fix_partuuid

  return 0
}

# 必要なファイルシステムをマウント
mount -t proc proc /proc
mount -t sysfs sys /sys
mount -t tmpfs tmp /run
mkdir -p /run/systemd

mount /boot
mount / -o remount,ro

# cmdline.txtからinit parameterを削除（Raspberry Pi用）
if [ -f /boot/cmdline.txt ]; then
  sed -i 's| init=/usr/lib/brain-config/init_resize\.sh||' /boot/cmdline.txt
  sed -i 's| sdhci\.debug_quirks2=4||' /boot/cmdline.txt
  
  if ! grep -q splash /boot/cmdline.txt; then
    sed -i "s/ quiet//g" /boot/cmdline.txt
  fi
fi

mount /boot -o remount,ro
sync

if ! check_commands; then
  reboot_brain
fi

if main; then
  dialog --infobox "Resized root filesystem. Rebooting in 5 seconds..." 10 60
  sleep 5
else
  dialog --msgbox "Could not expand filesystem, please try manual resize.\n${FAIL_REASON}" 10 60
  sleep 5
fi

reboot_brain