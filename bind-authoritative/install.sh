#!/usr/bin/env bash

IP=""
REV=""
LAST_OCTET=""
BASE_IP=""
SLAVE=""
DOMAIN=""
HOSTNAME="$(cat /etc/hostname)"

[[ "$EUID" -ne 0 ]] && error_with_message "Run as root"

function echoerr {
  cat <<< "$@" 1>&2
}

function error_with_message {
  echoerr "bind-install: $1"
  echoerr "Use -h|--help for help"
  exit 1
}

function display_help(){
  echo "Usage: bind-install.sh [OPTIONS]"
  echo
  echo "  -i, --ip              Public IP of master dns server."
  echo "  -s, --slave           Public IP of slave dns server."
  echo "  -d, --domain          The domain to be controlled."
  echo "  -h, --help            Display help message."
}

function parse_args () {
  [ $# -eq 0 ] && display_help && exit 1
  while (( "$#" )); do
    case $1 in
      -i|--ip)
        if [ -z $2 ] || [[ $2 == -* ]]; then
          error_with_message "Expected argument after public IP option"
        fi
        IP=$2
        shift;;

      -s|--slave)
        if [ -z $2 ] || [[ $2 == -* ]]; then
          error_with_message "Expected argument after slave IP option"
        fi
        SLAVE=$2
        shift;;

      -d|--domain)
        if [ -z $2 ] || [[ $2 == -* ]]; then
          error_with_message "Expected argument after domain option"
        fi
        DOMAIN=$2
        shift;;

      -h|--help)
        display_help
        exit 0;;

      *)
        error_with_message "Unknow option $1"
    esac
    shift
  done

  [ -z "${HOSTNAME}" ] && error_with_message "/etc/hostname is empty"
  [ -z "${IP}" ] && error_with_message "Public IP address must be provided"
  [ -z "${SLAVE}" ] && error_with_message "Slave IP address must be provided"
  [ -z "${DOMAIN}" ] && error_with_message "Domain must be provided"
  BASE_IP="$(echo $IP | cut -d '.' -f1-3)"
  LAST_OCTET="$(echo $IP | cut -d '.' -f4)"
  REV="$(echo $IP | awk -F. '{print $3"."$2"."$1".in-addr.arpa"}')"
}

function install_packages () {
  apt-get update -y
  apt-get install bind9 bind9utils -y
}

function setup_hosts () {
  echo -e "$IP\tns1.${DOMAIN} ${HOSTNAME}" >> /etc/hosts
}

function setup_named_local () {
  cat << EOF > /etc/bind/named.conf.local
zone "${DOMAIN}" {
    type master;
    file "/etc/bind/zones/db.${DOMAIN}";
    allow-transfer { ${SLAVE}; };
};

zone "${REV}" {
    type master;
    file "/etc/bind/zones/db.${BASE_IP}";
};
EOF
}

function setup_log_named_conf () {
  echo 'include "/etc/bind/named.conf.log";' >> /etc/bind/named.conf
}

function setup_named_log () {
  cat << EOF > /etc/bind/named.conf.log
logging {
    channel simple_log {
        file "/var/log/named/bind.log" versions 3 size 5m;
        severity warning;
        print-time yes;
        print-severity yes;
        print-category yes;
    };
    category default {
        simple_log;
    };
    channel query_log {
        file "/var/log/named/bind-queries.log";
        print-category yes;
        print-time yes;
    };
    category queries {
        query_log;
    };
};
EOF
}

function setup_named_options () {
  cat << EOF > /etc/bind/named.conf.options
options {
    directory "/var/cache/bind";
    recursion no;
    allow-transfer { none; };
    querylog yes;
    zone-statistics yes;
    statistics-file "/var/log/named/mydomain_stats.log";
    dnssec-validation auto;
    auth-nxdomain no;
    listen-on-v6 { any; };
};
EOF
}

function setup_domain_zone () {
  cat << EOF > /etc/bind/zones/db."${DOMAIN}"
\$TTL  604800
@ IN  SOA ns1.${DOMAIN}. admin.${DOMAIN}. (
            10
          604800
          86400
          2419200
          604800 )

${DOMAIN}.  IN  NS  ns1.${DOMAIN}.
${DOMAIN}.  IN  NS  ns2.${DOMAIN}.

ns1    IN  A ${IP}
ns2    IN  A ${SLAVE}
EOF
}

function setup_rev_zone () {
  cat << EOF > /etc/bind/zones/db."${BASE_IP}"
\$TTL  604800
@ IN  SOA ${DOMAIN}. admin.${DOMAIN}. (
            10
          604800
          86400
          2419200
          604800 )
  IN  NS  ns1.${DOMAIN}.
  IN  NS  ns2.${DOMAIN}.

${LAST_OCTET} IN  PTR ns1.${DOMAIN}.
EOF
}

function setup_lograte () {
  cat << EOF > /etc/logrotate.d/bind
/var/log/named/bind-queries.log {
    weekly
    missingok
    rotate 7
    postrotate
    /etc/init.d/bind reload > /dev/null
    endscript
    compress
    notifempty
}
EOF
}

function setup_zones () {
  mkdir -p /etc/bind/zones
  setup_domain_zone
  setup_rev_zone
}

function prepare_logging () {
  mkdir -p /var/log/named
  touch /var/log/named/bind-queries.log
  touch /var/log/named/bind.log
  setup_lograte
  chown -R bind:bind /var/log/named
}

function setup_system () {
  install_packages
  setup_hosts
  prepare_logging
}

function setup_configs () {
  setup_named_local
  setup_log_named_conf
  setup_named_log
  setup_named_options
  setup_zones
}

function main () {
  echo "Setting up system"
  setup_system
  echo "Setting up configurations"
  setup_configs
  echo "Restarting bind9 service"
  service bind9 restart
}

set -e
parse_args $@
main
set +e
