#!/usr/bin/env bash

[[ "$EUID" -ne 0 ]] && echo "debian-git.sh: Run as root" 1>&2 && exit 1
pgrep sshd &> /dev/null || echo "debian-git.sh: SSH must be installed and running for git server" 1>&2

set -e
apt-get install git -y

if ! grep -q 'git-shell' /etc/shells; then
  command -v git-shell >> /etc/shells
fi

if ! grep -q '^git:' /etc/passwd; then
  useradd git -m -s "$(command -v git-shell)"
fi

until passwd git; do
  echo "debian-git.sh: Could not set git password" 1>&2
done

mkdir -p /home/git/.ssh
mkdir -p /srv/git
chown -R git:git /srv/git
chown -R git:git /home/git

echo "Done! Installation finished!"
echo
echo "Put public keys authorized to interact with repositories in /home/git/.ssh/authorized_keys"
set +e
