#!/bin/sh

# Function to get drive name
DISK=""
get_drive() {
  lsblk
  printf "\nEnter the drive name (e.g., sda, sdb, vda): "
  read DISK
  if [ -z "${DISK}" ]; then
    echo "No drive name entered. Exiting."
    exit 1
  fi

  DISK="/dev/${DISK}"

  printf "WARNING: All data on %s will be erased. Are you sure? [Y/n] " "${DISK}"
  read confirmation
  case "$confirmation" in
  "n" | "N")
    echo "Operation canceled."
    exit 0
    ;;
  "" | "y" | "Y")
    echo "Proceeding with the operation on ${DISK}."
    printf "Wiping drive in "
    for i in 3 2 1; do
      printf '%d...' $i
      sleep 1
    done
    echo ""
    ;;
  *)
    echo "Invalid input. Defaulting to 'No'."
    exit 0
    ;;
  esac

  echo "Drive ${DISK} confirmed for installation."
}

setup_partitions() {
  if [ ! -d "/sys/firmware/efi" ]; then # Checking for bios system
    echo "BIOS systems are not supported."
  fi

  umount -A -R /mnt         # make sure everything is unmounted before we start
  sgdisk -Z ${DISK}         # zap all on disk
  sgdisk -a 2048 -o ${DISK} # new gpt disk 2048 alignment

  # Create partitions
  sgdisk -n 1::+1G --typecode=1:ef00 --change-name=1:"BOOT" ${DISK} # partition 1 (UEFI boot partition)
  sgdisk -n 2::+4G --typecode=2:8200 --change-name=1:"SWAP" ${DISK} # partition 2 (Swap partition)
  sgdisk -n 3::-0 --typecode=3:8300 --change-name=1:"ROOT" ${DISK}  # partition 3 (Root), default start, remaining
  partprobe ${DISK}                                                 # reread partition table to ensure it is correct

  # Create filesystems
  mkfs.fat -F32 -n "BOOT" ${DISK}1
  mkswap -f ${DISK}3
  mkfs.ext4 -F -L "ROOT" ${DISK}3

  # Mount
  mount ${DISK}3 /mnt
  if [ $? -ne 0 ]; then
    echo "Failed to mount the ROOT partition."
    exit 2 # Exit if mounting ROOT partition fails
  fi

  mount --mkdir ${DISK}1 /mnt/boot
  if [ $? -ne 0 ]; then
    echo "Failed to mount the BOOT partition."
    exit 2 # Exit if mounting BOOT partition fails
  fi

  swapon ${DISK}2
}

# Setup systemdboot as the bootloader
setup_bootloader() {
  bootctl install

  BOOTLOADER_ENTRY="/boot/loader/entries/arch.conf"
  ARCH_ENTRY_TEMPLATE="/usr/share/systemd/bootctl/arch.conf"

  # Get PARTUUID for the root partition
  PARTUUID=$(blkid | grep "${DISK}3" | awk -F= '{print $NF}' | tr -d '\"')

  if [ -z "$PARTUUID" ]; then
    echo "Error: Unable to find PARTUUID for ${DISK}3."
    exit 3
  fi

  # Create a new entry based on the template and PARTUUID
  echo "Creating bootloader entry with PARTUUID=$PARTUUID"

  sed "s/^options.*/options root=PARTUUID=$PARTUUID rw splash/" "$ARCH_ENTRY_TEMPLATE" >"$BOOTLOADER_ENTRY"

  if [ $? -eq 0 ]; then
    echo "Successfully created bootloader entry: $BOOTLOADER_ENTRY"
  else
    echo "Error: Failed to create the bootloader entry."
    exit 3
  fi
}

# Main execution flow
case $1 in
"install" | "")
  # Ask for the drive to install on
  get_drive

  # Partition, create filesystems and mount
  setup_partitions

  # Then install the kernel and some required packages
  pacstrap -K /mnt base linux linux-firmware networkmanager

  genfstab -U /mnt >>/mnt/etc/fstab

  # Copy the script to the new environment for the chroot part
  cp ./install.sh /mnt/tmp/
  echo "DISK=${DISK}" >/mnt/etc/install-script-variables.conf

  arch-chroot /mnt /bin/bash -c "/tmp/install.sh chroot"

  umount -A -R /mnt # Unmount everything for safety
  printf "\n==> Installation finished, you can now reboot.\n"
  ;;

"chroot")
  echo "Running the chroot side"

  . /tmp/install-script-variables.conf

  # Setup base locales
  ln -sf /usr/share/zoneinfo/Europe/Paris /etc/localtime
  locale-gen
  echo LANG=en_US.UTF-8 >/etc/locale.conf
  echo hostname >/etc/hostname

  echo "root:password" | chpasswd

  systemctl enable NetworkManager

  setup_bootloader

  ;;
esac
