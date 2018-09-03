#!/usr/bin/env bash

[[ "$EUID" -ne 0 ]] && echo "Run as root" 1>&2 && exit 1

PORT="443"
ALLOWED_USERS="$(grep ':1000:' /etc/passwd | cut -d ':' -f1)"

function echoerr {
  cat <<< "$@" 1>&2
}

function error_with_message {
  echoerr "arch-install: $1"
  echoerr "Use -h|--help for help"
  exit 1
}

function display_help(){
  echo "Usage: ssh-install.sh [OPTIONS]"
  echo
  echo "  -p, --port    Defines the port that sshd will listen for connections"
  echo "  -u, --users   Defines the users allowed to login through sshd. Example: -u \"myuser,foo,bar\""
  echo "  -h, --help    Display help message"
}

function parse_args(){
  while (( "$#" )); do
    case $1 in
      -p|--port)
        if [ -z "$2" ] || [[ $2 == -* ]]; then
          error_with_message "Expected argument after port option"
        fi
        PORT=$2
        shift;;

      -u|--users)
        if [ -z "$2" ] || [[ $2 == -* ]]; then
          error_with_message "Expected argument after users option"
        fi
        ALLOWED_USERS=$2
        shift;;

      -h|--help)
        display_help
        exit 0;;

      *)
        error_with_message "Unknow option $1"
    esac
    shift
  done
}

function install_dependencies () {
  if [[ -e /etc/debian_version ]]; then
    apt-get install openssh-server
  elif [[ -e /etc/arch-release ]]; then
    pacman -S openssh --noconfirm
  else
    echo "Could not identify operating system" 1>&2
    exit 1
  fi
}

function setup_sshconfig () {
  cat << EOF > /etc/ssh/sshd_config
Port ${PORT}
AllowUsers ${ALLOWED_USERS}
AuthorizedKeysFile .ssh/authorized_keys
KexAlgorithms curve25519-sha256@libssh.org
HostKey /etc/ssh/ssh_host_ed25519_key
PasswordAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,hmac-sha2-512,hmac-sha2-256
EOF
}

function enable_service () {
  if pgrep systemd-journal; then
    systemctl enable sshd
    systemctl start sshd
  else
    service ssh restart
    update-rc.d ssh enable
  fi
}

function main () {
  install_dependencies
  setup_sshconfig
  echo "SSH will listen in port ${PORT} allowing the users '${ALLOWED_USERS}' to login"
  echo "Installation finished!"
}

set -e
parse_args $@
main
set +e
