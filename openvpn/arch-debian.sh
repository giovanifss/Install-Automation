#!/bin/env bash

SYSCTL='/etc/sysctl.d/openvpn.conf'
NIC="$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -n1)"
OS=""

NETRANGE="10.0.0.0/24"
NETMASK="255.255.255.0"
PROTO="udp"
PORT="443"

function echoerr {
  cat <<< "$@" 1>&2
}

function error_with_message {
  echoerr "openvpn-install.sh: $1"
  echoerr "Use -h|--help for help"
  exit 1
}

function display_help(){
  echo "Usage: openvpn-install.sh [OPTIONS]"
  echo
  echo "  -p, --port            Defines the port for the service. Default: 443"
  echo "  -P, --protocol        Defines the protocol that the service will listen for. Default: udp"
  echo "  -m, --netmask         Defines the network mask. Default: 255.255.255.0"
  echo "  -r, --netrange        Defines the network IP range. Default: 10.13.37.0/24"
  echo "  -n, --nic             Defines the network interface controller. Default: default interface collected from 'ip route ls'"
  echo "  -h, --help            Display help message."
  echo
  echo "  Must be run as root and have TUN (/dev/net/tun) available"
}

function parse_args(){
  [ $# -eq 0 ] && display_help && exit 1
  while (( "$#" )); do
    case $1 in
      -p|--port)
        if [ -z $2 ] || [[ $2 == -* ]]; then
          error_with_message "Expected argument after port option"
        fi
        PORT=$2
        shift;;

      -m|--netmask)
        if [ -z $2 ] || [[ $2 == -* ]]; then
          error_with_message "Expected argument after network mask option"
        fi
        NETMASK=$2
        shift;;

      -r|--netrange)
        if [ -z $2 ] || [[ $2 == -* ]]; then
          error_with_message "Expected argument after network range option"
        fi
        NETRANGE=$2
        shift;;

      -n|--nic)
        if [ -z $2 ] || [[ $2 == -* ]]; then
          error_with_message "Expected argument after network interface controller option"
        fi
        NIC=$2
        shift;;

      -P|--protocol)
        if [ -z $2 ] || [[ $2 == -* ]]; then
          error_with_message "Expected argument after protocol option"
        fi
        PROTO=$2
        shift;;

      -h|--help)
        display_help
        exit 0;;

      *)
        error_with_message "Unknow argument $1"
    esac
    shift
  done
}

function identify_os () {
  if [[ -e /etc/debian_version ]]; then
    OS="debian"
  elif [[ -e /etc/arch-release ]]; then
    OS="arch"
  fi
}

function install_dependencies () {
  if [ "$OS" == "debian" ]; then
    apt-get install ca-certificates gnupg openssl curl -y
    echo "deb http://build.openvpn.net/debian/openvpn/stable jessie main" > /etc/apt/sources.list.d/openvpn.list
    curl -o - https://swupdate.openvpn.net/repos/repo-public.gpg | apt-key add -
    apt update
    apt-get install openvpn iptables iptables-persistent -y
  elif [ "$OS" == "arch" ]; then
    pacman -Syu openvpn iptables openssl --noconfirm
  fi
  mkdir -p /etc/iptables
}

function enable_forwarding () {
  [[ ! -e "$SYSCTL" ]] && touch "$SYSCTL"

  sed -i '/\<net.ipv4.ip_forward\>/c\net.ipv4.ip_forward=1' "$SYSCTL"
  if ! grep -q "\<net.ipv4.ip_forward\>" "$SYSCTL"; then
    echo 'net.ipv4.ip_forward=1' >> "$SYSCTL"
  fi

  echo 1 > /proc/sys/net/ipv4/ip_forward
}

function setup_server_conf () {
  cat <<- EOF > /etc/openvpn/server/server.conf
	port ${PORT}
	proto ${PROTO}
	dev tun
	topology subnet
	ca /etc/openvpn/server/ca.cert
	cert /etc/openvpn/server/server.cert
	key /etc/openvpn/server/server.key
	dh /etc/openvpn/server/dh.pem
	tls-crypt /etc/openvpn/server/ta.key
	auth SHA256
	tls-version-min 1.2
	tls-cipher TLS-DHE-RSA-WITH-CHACHA20-POLY1305-SHA256
	reneg-sec 360
	server $(echo ${NETRANGE} | cut -d '/' -f1) ${NETMASK}
	keepalive 20 120
	max-clients 1
	push "redirect-gateway def1 bypass-dhcp"
	push "dhcp-option DNS 208.67.222.222"
	push "dhcp-option DNS 208.67.220.220"
	push "dhcp-option DNS 8.8.8.8"
	persist-key
	persist-tun
	user nobody
	group nobody
	status openvpn-status.log
	log-append  openvpn.log
	verb 3
	explicit-exit-notify 1
	EOF
}


function enable_services () {
  if pgrep systemd-journal; then
    systemctl enable openvpn-server@server.service
    systemctl start openvpn-server@server.service
  else
    service opevpn restart
    update-rc.d openvpn enable
  fi
  iptables -t nat -A POSTROUTING -o "$NIC" -s "${NETRANGE}" -j MASQUERADE
}

function main () {
  identify_os
  install_dependencies
  enable_forwarding
  setup_server_conf
  enable_services
}

[[ "$EUID" -ne 0 ]] && error_with_message "Run as root"
[[ ! -e /dev/net/tun ]] && error_with_message "Tun not available"
parse_args $@
main
