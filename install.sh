#!/bin/sh

# User inputs
HOSTNAME=""
ROOT_PASSWORD=""
USERNAME=""
USER_PASSWORD=""

install_deps() {
  echo "You will need commands like mkfs.ext4, sgisk and pacstrap."
  printf "Try to install them with pacman (if you are on arch linux)? [Y/n] "
  read CONFIRMATION
  case "$CONFIRMATION" in
  "n" | "N")
    echo "Operation canceled."
    return
    ;;
  "" | "y" | "Y")
    echo "Installing dependencies"
    sudo pacman -S --needed --noconfirm dosfstools gptfdisk arch-install-scripts
    echo ""
    ;;
  *)
    echo "Invalid input. Defaulting to 'No'."
    exit 0
    ;;
  esac
}

send_status_message() {
  term_width=$(tput cols 2>/dev/null || echo 80)
  msg="$1"
  edge=$(printf '%*s' "$term_width" '' | tr ' ' '=')
  printf "\n%s\n" "$edge"
  printf "%*s\n" $(((${#msg} + term_width) / 2)) "$msg"
  printf "%s\n\n" "$edge"
}

get_config_inputs() {
  send_status_message "CONFIGURATION: Getting user inputs"

  while [ -z "$HOSTNAME" ]; do
    printf "Enter hostname: "
    read HOSTNAME

    if [ -z "$HOSTNAME" ]; then
      echo "Hostname cannot be empty."
      continue
    fi
    break
  done
  echo ""

  while [ -z "$ROOT_PASSWORD" ]; do
    printf "Enter root password: "
    read -s ROOT_PASSWORD
    printf "\nConfirm root password: "
    read -s CONFIRM_ROOT_PASSWORD

    if [ "$ROOT_PASSWORD" != "$CONFIRM_ROOT_PASSWORD" ]; then
      echo "Root passwords do not match."
      ROOT_PASSWORD=""
      CONFIRM_ROOT_PASSWORD=""
      continue
    fi
    break
  done
  echo ""
  echo ""

  while [ -z "$USERNAME" ]; do
    printf "Enter username: "
    read USERNAME

    if [ -z "$USERNAME" ]; then
      echo "Username cannot be empty."
      continue
    fi
    break
  done
  echo ""

  while [ -z "$USER_PASSWORD" ]; do
    printf "Enter user password: "
    read -s USER_PASSWORD
    printf "\nConfirm user password: "
    read -s CONFIRM_USER_PASSWORD

    if [ "$USER_PASSWORD" != "$CONFIRM_USER_PASSWORD" ]; then
      echo "User passwords do not match."
      USER_PASSWORD=""
      CONFIRM_USER_PASSWORD=""
      continue
    fi
    break
  done
}

# Function to get drive name
DISK=""
get_drive() {
  send_status_message "DRIVE SETUP: Selecting and confirming target drive"

  lsblk
  printf "\nEnter the drive name (e.g., sda, sdb, vda, nvme0n1): "
  read DISK
  if [ -z "${DISK}" ]; then
    echo "No drive name entered. Exiting."
    exit 1
  fi

  DISK="/dev/${DISK}"
  PART_PREFIX="$DISK"
  case "$DISK" in
  *nvme*n*) PART_PREFIX="${DISK}p" ;; # nvme devices need a 'p' before partition number
  *) PART_PREFIX="${DISK}" ;;
  esac

  printf "WARNING: All data on %s will be erased. Are you sure? [Y/n] " "${DISK}"
  read CONFIRMATION
  case "$CONFIRMATION" in
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
  send_status_message "PARTITIONING: Creating partitions and filesystems"

  if [ ! -d "/sys/firmware/efi" ]; then # Checking for BIOS system
    echo "BIOS systems are not supported."
  fi

  umount -A -R /mnt         # make sure everything is unmounted before we start
  sgdisk -Z ${DISK}         # zap all on disk
  sgdisk -a 2048 -o ${DISK} # new GPT disk 2048 alignment

  # Create partitions
  sgdisk -n 1::+1G --typecode=1:ef00 --change-name=1:"BOOT" ${DISK} # partition 1 (UEFI boot partition)
  sgdisk -n 2::+4G --typecode=2:8200 --change-name=2:"SWAP" ${DISK} # partition 2 (Swap partition)
  sgdisk -n 3::-0 --typecode=3:8300 --change-name=3:"ROOT" ${DISK}  # partition 3 (Root), default start, remaining
  partprobe ${DISK}                                                 # reread partition table to ensure it is correct

  # Create filesystems
  mkfs.fat -F32 -n "BOOT" ${PART_PREFIX}1
  mkswap -f ${PART_PREFIX}2
  mkfs.ext4 -F -L "ROOT" ${PART_PREFIX}3

  # Mount
  mount ${PART_PREFIX}3 /mnt
  if [ $? -ne 0 ]; then
    echo "Failed to mount the ROOT partition."
    exit 2 # Exit if mounting ROOT partition fails
  fi

  mount --mkdir ${PART_PREFIX}1 /mnt/boot
  if [ $? -ne 0 ]; then
    echo "Failed to mount the BOOT partition."
    exit 2 # Exit if mounting BOOT partition fails
  fi

  swapon ${PART_PREFIX}2
}

# Setup systemdboot as the bootloader
setup_bootloader() {
  send_status_message "BOOTLOADER: Installing and configuring systemd-boot"

  # Run bootctl inside chroot
  arch-chroot /mnt bootctl install
  if [ $? -ne 0 ]; then
    echo "Error: Failed to install systemd-boot."
    exit 3
  fi

  BOOTLOADER_ENTRY="/mnt/boot/loader/entries/arch.conf"
  ARCH_ENTRY_TEMPLATE="/mnt/usr/share/systemd/bootctl/arch.conf"

  # Get PARTUUID for the root partition
  PARTUUID=$(blkid | grep "${PART_PREFIX}3" | awk -F= '{print $NF}' | tr -d '\"')

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

# >------ Main execution flow ------<

# Install dependencies on the host
install_deps
echo ""

# Ask for hostname, username, user and root passwords
get_config_inputs
echo ""

# Ask for the drive to install on
get_drive
echo ""

# Partition, create filesystems and mount
setup_partitions

# Then install the kernel and some required packages
send_status_message "BASE INSTALLATION: Installing base system with pacstrap"
pacstrap -K /mnt base linux linux-firmware networkmanager lemurs sudo
if [ $? -ne 0 ]; then
  echo "Error: Failed to install base system."
  exit 4
fi

send_status_message "SYSTEM CONFIG: Generating fstab"
genfstab -U /mnt >>/mnt/etc/fstab

# Setup base locales
send_status_message "SYSTEM CONFIG: Setting timezone, locales, and hostname"
ln -sf /usr/share/zoneinfo/Europe/Paris /mnt/etc/localtime
echo 'en_US.UTF-8 UTF-8' >>/mnt/etc/locale.gen
arch-chroot /mnt locale-gen
echo LANG=en_US.UTF-8 >/mnt/etc/locale.conf
echo $HOSTNAME >/mnt/etc/hostname

send_status_message "USER SETUP: Creating user and setting passwords"
# Set root password
arch-chroot /mnt bash -c "echo 'root:$ROOT_PASSWORD' | chpasswd"

# Create user and set password
arch-chroot /mnt useradd -m $USERNAME
arch-chroot /mnt bash -c "echo '$USERNAME:$USER_PASSWORD' | chpasswd"

# Setup wheel group
arch-chroot /mnt usermod -aG wheel $USERNAME
arch-chroot /mnt bash -c "echo '%wheel ALL=(ALL) ALL' | EDITOR='tee -a' visudo"

send_status_message "SERVICES: Enabling NetworkManager and lemurs"
# Setup services and display manager
arch-chroot /mnt systemctl enable NetworkManager lemurs

setup_bootloader

send_status_message "CLEANUP: Unmounting all filesystems"
umount -A -R /mnt # Unmount everything for safety

send_status_message "Installation finished. Reboot now."
