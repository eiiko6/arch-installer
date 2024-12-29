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
  mkswap ${DISK}3
  mkfs.ext4 -L "ROOT" ${DISK}3

  # Mount
  mount ${DISK}3 /mnt
  if [ $? -ne 0 ]; then
    echo "Failed to mount the ROOT partition."
    return 1 # Exit if mounting ROOT partition fails
  fi

  mount --mkdir ${DISK}1 /mnt/boot
  if [ $? -ne 0 ]; then
    echo "Failed to mount the BOOT partition."
    return 1 # Exit if mounting BOOT partition fails
  fi

  swapon ${DISK}2
}

# Main execution flow
get_drive

# cat /usr/share/systemd/bootctl/arch.conf | sed "s/^options.*/options root=PARTUUID=$(blkid | grep vda3 | awk -F= '{print $NF}' | tr -d '\"') rw splash/" >/boot/loader/entries/arch.conf
