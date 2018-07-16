#!/usr/bin/env bash

[[ "$EUID" -ne 0 ]] && echo "Run as root" 1>&2 && exit 1
pgrep sshd &> /dev/null || echo "git-install.sh: SSH must be installed and running for git server" 1>&2

set -e
if [[ -e /etc/debian_version ]]; then
  apt-get install git -y
elif [[ -e /etc/arch-release ]]; then
  pacman -S git --noconfirm
else
  echo "Could not identify operating system" 1>&2
  exit 2
fi

if ! grep -q 'git-shell' /etc/shells; then
  command -v git-shell >> /etc/shells
fi

if ! grep -q '^git:' /etc/passwd; then
  useradd git -m -s "$(command -v git-shell)"
fi

until passwd git; do
  echo "Could not set git password" 1>&2
done

mkdir -p /home/git/.ssh
mkdir -p /srv/git
chown -R git:git /srv/git
chown -R git:git /home/git

echo "Done! Installation finished!"
echo
echo "Put public keys authorized to interact with repositories in /home/git/.ssh/authorized_keys"
set +e
