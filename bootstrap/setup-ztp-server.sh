#!/usr/bin/env bash
###############################################################################
# setup-ztp-server.sh
#
# Runs ON the ztp-server (Ubuntu generic node inside the ACT lab).
# Installs and configures:
#   - dnsmasq: DHCP for the 192.168.0.0/24 mgmt network, hands out
#              bootfile-name (DHCP option 67) pointing at our bootstrap.py
#   - python3 http.server: serves /var/www/ztp/bootstrap.py over HTTP:8080
#
# Expects /var/www/ztp/bootstrap.py to already be in place (uploaded by the
# bootstrap.sh wrapper running on the operator's machine).
###############################################################################

set -euo pipefail

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

if [[ ! -f "${ZTP_DIR}/${ZTP_FILE}" ]]; then
    echo "[ztp-server] ERROR: ${ZTP_DIR}/${ZTP_FILE} not found. Upload it first." >&2
    exit 1
fi

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
