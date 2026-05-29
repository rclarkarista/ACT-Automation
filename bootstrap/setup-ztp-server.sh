#!/usr/bin/env bash
###############################################################################
# setup-ztp-server.sh
#
# Runs ON the ztp-server (Ubuntu generic node inside the ACT lab), invoked
# via `sudo` by bootstrap.sh. Installs and configures:
#   - dnsmasq: DHCP for the 192.168.0.0/24 mgmt network, hands out
#              bootfile-name (DHCP option 67) pointing at our bootstrap.py
#   - python3 http.server: serves /var/www/ztp/bootstrap.py over HTTP:8080
#
# Usage: sudo setup-ztp-server.sh <path-to-bootstrap.py>
#   The bootstrap.py is uploaded to a staging dir by bootstrap.sh (since the
#   'arista' user can't write directly to /var/www/), and this script moves
#   it into place.
###############################################################################

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "[ztp-server] ERROR: must be run as root (use sudo)." >&2
    exit 1
fi

BOOTSTRAP_SRC="${1:-}"
if [[ -z "${BOOTSTRAP_SRC}" || ! -f "${BOOTSTRAP_SRC}" ]]; then
    echo "[ztp-server] ERROR: pass the path to bootstrap.py as the first arg." >&2
    echo "             usage: sudo $0 /home/arista/ztp-staging/bootstrap.py" >&2
    exit 1
fi

ZTP_DIR="/var/www/ztp"
ZTP_FILE="bootstrap.py"
ZTP_PORT="8080"
ZTP_IF="eth1"                  # mgmt interface inside the lab
ZTP_SERVER_IP="192.168.0.5"
DHCP_RANGE_START="192.168.0.100"
DHCP_RANGE_END="192.168.0.200"
DHCP_NETMASK="255.255.255.0"
DHCP_LEASE="12h"

echo "[ztp-server] installing packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq dnsmasq python3

echo "[ztp-server] staging bootstrap.py into ${ZTP_DIR}..."
mkdir -p "${ZTP_DIR}"
install -m 0644 "${BOOTSTRAP_SRC}" "${ZTP_DIR}/${ZTP_FILE}"

echo "[ztp-server] writing /etc/dnsmasq.conf..."
cat > /etc/dnsmasq.conf <<EOF
# Managed by setup-ztp-server.sh — do not hand-edit.
interface=${ZTP_IF}
bind-interfaces
domain-needed
bogus-priv
no-resolv
no-poll

# DHCP scope for the mgmt network
dhcp-range=${DHCP_RANGE_START},${DHCP_RANGE_END},${DHCP_NETMASK},${DHCP_LEASE}
dhcp-option=3,${ZTP_SERVER_IP}                 # default gateway (this box)
dhcp-option=6,8.8.8.8,1.1.1.1                  # DNS
dhcp-option=66,${ZTP_SERVER_IP}                # TFTP / next-server
dhcp-option=67,"http://${ZTP_SERVER_IP}:${ZTP_PORT}/${ZTP_FILE}"

log-dhcp
EOF

echo "[ztp-server] restarting dnsmasq..."
systemctl enable dnsmasq
systemctl restart dnsmasq

echo "[ztp-server] starting bootstrap http server on :${ZTP_PORT}..."
# Kill any prior instance, then relaunch detached.
pkill -f "http.server ${ZTP_PORT}" 2>/dev/null || true
cd "${ZTP_DIR}"
nohup python3 -m http.server "${ZTP_PORT}" --bind "${ZTP_SERVER_IP}" \
    > /var/log/ztp-http.log 2>&1 &

sleep 1
if pgrep -f "http.server ${ZTP_PORT}" >/dev/null; then
    echo "[ztp-server] ready. switches will fetch:"
    echo "             http://${ZTP_SERVER_IP}:${ZTP_PORT}/${ZTP_FILE}"
else
    echo "[ztp-server] ERROR: http server failed to start. see /var/log/ztp-http.log" >&2
    exit 1
fi
