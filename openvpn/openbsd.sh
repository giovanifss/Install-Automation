#!/usr/bin/env sh

echo ":: Starting OpenVPN installation"

vpn_if="tun0"
ext_if="$(netstat -i | grep -E '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}'\
            | grep -v '127.0.0.1' | cut -d ' ' -f1)"

port="1194"
proto="udp"
mask="255.255.255.0"
network="10.0.1.0/24"
pf_cfg="/etc/pf.conf"
base_dir="/etc/openvpn"
log_dir="/var/log/openvpn"
sysctl_cfg="/etc/sysctl.conf"

printf '2\n' | pkg_add openvpn

install -m 700 -d "${base_dir}"/private/
install -m 755 -d "${base_dir}"/certs/
install -m 755 -d "${log_dir}"

{
  echo '# VPN NAT configuration'
  echo "ext_if = \"${ext_if}\""
  echo "tun_if = \"${vpn_if}\""
  echo "pass out on \$ext_if from ${network} to any nat-to (\$ext_if)"
  echo "pass in quick on \$tun_if keep state"
} >> "${pf_cfg}"

pfctl -f "${pf_cfg}"

{
  echo "port ${port}"
  echo "proto ${proto}"
  echo 'dev tun'
  echo 'topology subnet'
  echo "ca ${base_dir}/certs/ca.crt"
  echo "cert ${base_dir}/certs/server.crt"
  echo "key ${base_dir}/private/server.key"
  echo "dh ${base_dir}/dh.pem"
  echo "tls-crypt ${base_dir}/private/ta.key"
  echo 'auth SHA512'
  echo 'tls-version-min 1.2'
  echo 'tls-cipher TLS-DHE-RSA-WITH-AES-256-GCM-SHA384'
  echo 'cipher AES-256-GCM'
  echo 'reneg-sec 120'
  echo "server $(echo ${network} | cut -d '/' -f1) ${mask}"
  echo 'keepalive 20 120'
  echo 'max-clients 1'
  echo 'push "redirect-gateway def1 bypass-dhcp"'
  echo 'push "dhcp-option DNS 208.67.222.222"'
  echo 'push "dhcp-option DNS 208.67.220.220"'
  echo 'push "dhcp-option DNS 8.8.8.8"'
  echo 'persist-key'
  echo 'persist-tun'
  echo 'user _openvpn'
  echo 'group _openvpn'
  echo "status ${log_dir}/openvpn-status.log"
  echo "log-append ${log_dir}/openvpn.log"
  echo 'verb 3'
  echo 'explicit-exit-notify 1'
} >> "${base_dir}"/server.conf

echo 'net.inet.ip.forwarding=1' >> "${sysctl_cfg}"
sysctl net.inet.ip.forwarding=1

echo ":: Installation finished"
