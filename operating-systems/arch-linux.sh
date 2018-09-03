#!/bin/env bash

EXTRA_PACKAGES=""
PACKAGES="base base-devel git docker openssh openvpn"
USR=$(head /dev/urandom | tr -dc a-z | head -c 15; echo -n)
HST=$(head /dev/urandom | tr -dc A-Za-z | head -c 15; echo -n)
CNTY="us"
DISK="/dev/sda"
LCL="UTC"
SKIP_DISK=false

function echoerr {
  cat <<< "$@" 1>&2
}

function try_until_ok () {
  cmd="$1"
  msg="$2"
  until ${cmd}; do
    echo "arch-install.sh: ${msg}"
  done
}

function error_with_message {
  echoerr "arch-install: $1"
  echoerr "Use -h|--help for help"
  exit 1
}

function display_help(){
  echo "Usage: arch-install.sh [OPTIONS]"
  echo
  echo "  -H, --hostname        Defines the hostname of the machine. Default: random 15 chars."
  echo "  -u, --username        Defines the username for the user created during installation. Default: random 15 chars."
  echo "  -c, --country         Defines the country initials for greping in mirrors. Default: us."
  echo "  -d, --disk            Defines the base disk for the installation. Default: sda (E.g. /dev/sda)."
  echo "  -l, --locale          Defines the locale for time configuration. Default: UTC."
  echo "      --skip-disk       Do not perform disk partitioning."
  echo "  -e, --extra-packages  The extra packages for installation. Must be specified inside quotes. E.g. -e \"vim git\"."
  echo "  -h, --help            Display help message."
}

function parse_args(){
  [ $# -eq 0 ] && display_help && exit 1
  while (( "$#" )); do
    case $1 in
      -H|--hostname)
        if [ -z $2 ] || [[ $2 == -* ]]; then
          error_with_message "Expected argument after hostname option"
        fi
        HST=$2
        shift;;

      -u|--username)
        if [ -z $2 ] || [[ $2 == -* ]]; then
          error_with_message "Expected argument after username option"
        fi
        USR=$2
        shift;;

      -c|--country)
        if [ -z $2 ] || [[ $2 == -* ]]; then
          error_with_message "Expected argument after country option"
        fi
        CNTY=$2
        shift;;

      -l|--locale)
        if [ -z $2 ] || [[ $2 == -* ]]; then
          error_with_message "Expected argument after locale option"
        fi
        LCL=$2
        shift;;

      -d|--disk)
        if [ -z $2 ] || [[ $2 == -* ]]; then
          error_with_message "Expected argument after disk option"
        fi
        DISK="/dev/$2"
        shift;;

      -e|--extra-packages)
        if [ -z $2 ] || [[ $2 == -* ]]; then
          error_with_message "Expected argument after extra-packages option"
        fi
        EXTRA_PACKAGES="$2"
        shift;;

      -s|--skip-disk)
        SKIP_DISK=true;;

      -h|--help)
        display_help
        exit 0;;

      *)
        error_with_message "Unknow option $1"
    esac
    shift
  done
}

function rank_mirrors () {
  tmp_ml="/tmp/mirrorlist"
  bkp_ml="/tmp/mirrorlist.bkp"
  cp /etc/pacman.d/mirrorlist ${bkp_ml}
  echo "Ranking mirrors"
  grepped="$(grep -i ${CNTY} /etc/pacman.d/mirrorlist | grep -v '^#')"
  if [ -z "${grepped}" ]; then
    echoerr "arch-install: Could not get any repository with country ${CNTY}"
    mv /etc/pacman.d/mirrorlist ${tmp_ml}
  else
    echo "${grepped}" > ${tmp_ml}
  fi
  rankmirrors -n 15 ${tmp_ml} > /etc/pacman.d/mirrorlist
}

function setup_disk () {
  echo "Formatting disks"
  if [ -d /sys/firmware/efi ]; then
    echo -e "\t-> EFI Setup"
    echo -e "g\nn\n\n\n+512M\nt\n1\nn\n\n\n\nw\n" | fdisk ${DISK}
  else
    echo -e "\t-> BIOS Setup"
    echo -e "o\nn\n\n\n\n+512M\nn\n\n\n\n\nw\n" | fdisk ${DISK}
  fi

  echo "Setting up cryptography"
  try_until_ok "cryptsetup -y -v luksFormat ${DISK}2" "Could not setup disk encryption, try again."
  cryptsetup open "${DISK}2" cryptroot
  mkfs.ext4 /dev/mapper/cryptroot
  mount /dev/mapper/cryptroot /mnt

  echo "Setting up boot directory"
  mkfs.fat -F32 "${DISK}1"
  mkdir /mnt/boot
  mount "${DISK}1" /mnt/boot

  export DEVICE_UUID="$(blkid ${DISK}2 | awk ' { print $2 } ' | sed s/\"//g)"
  echo $DEVICE_UUID > ./device-uuid
  echo "Device UUID Your device UUID is stored at ./device-uuid"
}

function install_packages () {
  if [ ! -z "${EXTRA_PACKAGES}" ]; then
    PACKAGES="${PACKAGES} ${EXTRA_PACKAGES}"
  fi
  echo "Bootstrapping packages"
  pacstrap /mnt $PACKAGES
  cp /etc/pacman.d/mirrorlist /mnt/etc/pacman.d/mirrorlist
}

function setup_users () {
  echo "Setting up $USR"
  arch-chroot /mnt groupadd -f docker
  arch-chroot /mnt useradd -m -s /bin/bash -g users -G wheel,docker $USR
  echo "Set root password"
  try_until_ok "arch-chroot /mnt passwd" "Could not set root password, try again."
  echo "Set $USR password"
  try_until_ok "arch-chroot /mnt passwd $USR" "Could not set $USR password, try again."
}

function setup_system_configs () {
  echo "Gen fstab"
  genfstab -U /mnt >> /mnt/etc/fstab

  echo "Clock stuff"
  arch-chroot /mnt rm -f /etc/localtime
  arch-chroot /mnt ln -s "/usr/share/zoneinfo/${LCL}" /etc/localtime
  arch-chroot /mnt hwclock --systohc --utc

  echo "Locale stuff"
  sed -i 's/#en_US.UTF-8/en_US.UTF-8/' /mnt/etc/locale.gen
  echo LANG=en_US.UTF-8 > /mnt/etc/locale.conf
  echo $HST > /mnt/etc/hostname

  echo "Making vmlinuz"
  sed -i "/^HOOKS/s/filesystems/encrypt filesystems/" /mnt/etc/mkinitcpio.conf
  arch-chroot /mnt mkinitcpio -p linux
}

function setup_bootloader () {
  if [ -d /sys/firmware/efi ]; then
    echo "Configuring bootctl"
    arch-chroot /mnt bootctl install
    arch-chroot /mnt cp -f /usr/share/systemd/bootctl/loader.conf /boot/loader/loader.conf
    echo "editor 0" >> /mnt/boot/loader/loader.conf
    arch-chroot /mnt bash -c "echo -e \"title Arch Linux\nlinux /vmlinuz-linux\ninitrd /initramfs-linux.img\noptions cryptdevice=${DEVICE_UUID}:cryptroot root=/dev/mapper/cryptroot quiet rw\" > /boot/loader/entries/arch.conf"
  else
    echo "Configuring grub"
    arch-chroot /mnt pacman -S grub --noconfirm
    arch-chroot /mnt bash -c "grep -v 'GRUB_CMDLINE_LINUX=\"\"' /etc/default/grub > /etc/default/clean_grub"
    arch-chroot /mnt bash -c "echo GRUB_CMDLINE_LINUX=\\\"cryptdevice=${DEVICE_UUID}:cryptroot\\\" >> /etc/default/clean_grub"
    arch-chroot /mnt mv /etc/default/clean_grub /etc/default/grub
    arch-chroot /mnt grub-install "${DISK}"
    arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
  fi
}

function test_connectivity () {
  if ! ping -q -c1 -W2 google.com > /dev/null; then
    echo "error: Make sure you got an internet connection"
    exit 1
  fi
}

function main () {
  test_connectivity
  command -v rankmirrors > /dev/null && rank_mirrors
  ${SKIP_DISK} || setup_disk
  install_packages
  setup_users
  setup_system_configs
  setup_bootloader
  echo -e "Done! Instalation finished!"
}

parse_args $@
set -e
main
set +e
