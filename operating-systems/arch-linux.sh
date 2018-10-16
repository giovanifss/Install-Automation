#!/bin/env bash

EXTRA_PACKAGES=""
PACKAGES="base base-devel git openssh"
USR=$(head /dev/urandom | tr -dc a-z | head -c 15; echo -n)
HST=$(head /dev/urandom | tr -dc A-Za-z | head -c 15; echo -n)
EXTRA_GROUPS=""
CNTY="us"
DISK="/dev/sda"
DISK_PARTITION=""
PREFIX=""
LCL="UTC"
ENCRYPT=true
SKIP_DISK=false
SERIAL=false

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
  echo "Usage: arch-install.sh [-u USR] [-h HST] [-c CNTY] [-d DISK] [-g GROUPS] [-l LCL] [-e PKGS]"
  echo
  echo "  -H, --hostname        Hostname of the machine. Default: random 15 chars."
  echo "  -u, --username        Username for the user created during installation. Default: random 15 chars."
  echo "  -c, --country         Country initials for greping in mirrors. Default: us."
  echo "  -d, --disk            Base disk for the installation. Default: sda (E.g. /dev/sda)."
  echo "  -l, --locale          Locale for time configuration. Default: UTC."
  echo "  -g, --groups          Extra groups that [user] will be part of."
  echo "  -p, --prefix          Disk partition prefix. Example: /dev/sdap1, prefix='p'. Default: ''"
  echo "      --skip-disk       Do not perform disk partitioning."
  echo "      --serial          Enable serial console interaction in grub."
  echo "      --no-encrypt      Do not encrypt root partition."
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

      -g|--groups)
        if [ -z $2 ] || [[ $2 == -* ]]; then
          error_with_message "Expected argument after groups option"
        fi
        EXTRA_GROUPS=$2
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

      -p|--prefix)
        if [ -z $2 ] || [[ $2 == -* ]]; then
          error_with_message "Expected argument after prefix option"
        fi
        PREFIX="$2"
        shift;;

      -s|--skip-disk)
        SKIP_DISK=true;;

      --serial)
        SERIAL=true;;

      --no-encrypt)
        ENCRYPT=false;;

      -h|--help)
        display_help
        exit 0;;

      *)
        error_with_message "Unknow option $1"
    esac
    shift

    DISK_PARTITION="${DISK}${PREFIX}"
    EXTRA_GROUPS="${EXTRA_GROUPS//,/ }"
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

function encrypt_disk () {
  echo "Setting up cryptography"
  try_until_ok "cryptsetup -y -v luksFormat ${DISK_PARTITION}2" "Could not setup disk encryption, try again."
  cryptsetup open "${DISK_PARTITION}2" cryptroot
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

  root_disk="${DISK_PARTITION}2"
  ${ENCRYPT} && encrypt_disk && root_disk="/dev/mapper/cryptroot"
  mkfs.ext4 "${root_disk}"
  mount "${root_disk}" /mnt

  echo "Setting up boot directory"
  mkfs.fat -F32 "${DISK_PARTITION}1"
  mkdir /mnt/boot
  mount "${DISK_PARTITION}1" /mnt/boot

  export DEVICE_UUID="$(blkid ${DISK_PARTITION}2 | awk ' { print $2 } ' | sed s/\"//g)"
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

function setup_groups () {
  echo "Setting up "${USR}" groups"
  for g in ${EXTRA_GROUPS}; do
    arch-chroot /mnt groupadd -f "$g"
    arch-chroot /mnt usermod -a -G "$g" "${USR}"
  done
}

function setup_users () {
  echo "Setting up $USR"
  arch-chroot /mnt useradd -m -s /bin/bash -g users $USR
  [ ! -z "${EXTRA_GROUPS}" ] && setup_groups
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

function setup_serial () {
  arch-chroot /mnt bash -c "grep -v GRUB_CMDLINE_LINUX_DEFAULT= /etc/default/grub > /etc/default/clean_grub"
  arch-chroot /mnt bash -c "echo GRUB_CMDLINE_LINUX_DEFAULT=\\\"quiet console=tty0 console=ttyS0,38400n8\\\" >> /etc/default/clean_grub"
  arch-chroot /mnt bash -c "echo GRUB_TERMINAL=serial >> /etc/default/clean_grub"
  arch-chroot /mnt bash -c "echo GRUB_SERIAL_COMMAND=\\\"serial --speed=38400 --unit=0 --word=8 --parity=no --stop=1\\\" >> /etc/default/clean_grub"
  arch-chroot /mnt mv /etc/default/clean_grub /etc/default/grub
}

function setup_efiboot_encrypt_options () {
  ${ENCRYPT} && options="cryptdevice=${DEVICE_UUID}:cryptroot root=/dev/mapper/cryptroot"
  options="options ${options} quiet rw"
  arch-chroot /mnt bash -c "echo -e \"\n${options}\" >> /boot/loader/entries/arch.conf"
}

function setup_biosboot_encrypt_options () {
  arch-chroot /mnt bash -c "grep -v 'GRUB_CMDLINE_LINUX=\"\"' /etc/default/grub > /etc/default/clean_grub"
  arch-chroot /mnt bash -c "echo GRUB_CMDLINE_LINUX=\\\"cryptdevice=${DEVICE_UUID}:cryptroot\\\" >> /etc/default/clean_grub"
  arch-chroot /mnt mv /etc/default/clean_grub /etc/default/grub
}

function setup_bootloader () {
  if [ -d /sys/firmware/efi ]; then
    echo "Configuring bootctl"
    arch-chroot /mnt bootctl install
    arch-chroot /mnt cp -f /usr/share/systemd/bootctl/loader.conf /boot/loader/loader.conf
    echo "editor 0" >> /mnt/boot/loader/loader.conf
    arch-chroot /mnt bash -c "echo -e \"title Arch Linux\nlinux /vmlinuz-linux\ninitrd /initramfs-linux.img\" > /boot/loader/entries/arch.conf"
    ${ENCRYPT} && setup_efiboot_encrypt_options
  else
    echo "Configuring grub"
    arch-chroot /mnt pacman -S grub --noconfirm
    ${ENCRYPT} && setup_biosboot_encrypt_options
    ${SERIAL} && setup_serial
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
