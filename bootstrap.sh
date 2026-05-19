#!/usr/bin/env bash
###############################################################################
# bootstrap.sh
#
# Operator-side wrapper. After you've deployed your ACT topology (UI for now,
# API later), run this from your laptop to:
#   1. Prompt once for CVaaS URL, CVaaS enrollment token, ztp-server IP, and
#      a unique serial-number prefix. Values are cached in .config so reruns
#      are non-interactive.
#   2. Render bootstrap.py.template -> bootstrap/bootstrap.py with your token.
#   3. SCP it to the ztp-server, then SSH in and run setup-ztp-server.sh,
#      which installs dnsmasq + python http server.
#
# After this runs, power-cycle (or just wait — vEOS boots into ZTP) the
# switches; they DHCP, fetch bootstrap.py, register themselves with CVaaS
# using the pinned serial numbers from topology.yml.
###############################################################################

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${PROJECT_DIR}/.config"
TEMPLATE="${PROJECT_DIR}/bootstrap/bootstrap.py.template"
RENDERED="${PROJECT_DIR}/bootstrap/bootstrap.py"
SETUP_SCRIPT="${PROJECT_DIR}/bootstrap/setup-ztp-server.sh"

ZTP_USER="root"
ZTP_PASS="arista"   # default ACT generic-node creds
REMOTE_DIR="/var/www/ztp"

###############################################################################
# helpers
###############################################################################
require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "ERROR: '$1' not installed. Please install it and rerun." >&2
        exit 1
    }
}

prompt() {
    # prompt <var-name> <human-label> [secret]
    local __var=$1 label=$2 secret=${3:-}
    local existing="${!__var:-}"
    if [[ -n "${existing}" ]]; then
        echo "  ${label}: using cached value"
        return
    fi
    local val
    if [[ "${secret}" == "secret" ]]; then
        read -r -s -p "  ${label}: " val; echo
    else
        read -r -p "  ${label}: " val
    fi
    printf -v "${__var}" '%s' "${val}"
}

save_config() {
    cat > "${CONFIG_FILE}" <<EOF
# Cached by bootstrap.sh. Delete this file to be re-prompted.
CVAAS_URL="${CVAAS_URL}"
CVAAS_TOKEN="${CVAAS_TOKEN}"
ZTP_SERVER_IP="${ZTP_SERVER_IP}"
SERIAL_PREFIX="${SERIAL_PREFIX}"
EOF
    chmod 600 "${CONFIG_FILE}"
}

###############################################################################
# pre-flight
###############################################################################
require_cmd ssh
require_cmd scp
require_cmd sshpass   # used so we don't have to type the lab password 3x

###############################################################################
# load cached config (if any)
###############################################################################
CVAAS_URL=""
CVAAS_TOKEN=""
ZTP_SERVER_IP=""
SERIAL_PREFIX=""

if [[ -f "${CONFIG_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${CONFIG_FILE}"
    echo "Loaded cached config from .config (delete it to re-prompt)."
fi

###############################################################################
# prompt for anything missing
###############################################################################
echo
echo "Configuration:"
prompt CVAAS_URL      "CVaaS URL (e.g. www.arista.io)"
prompt CVAAS_TOKEN    "CVaaS enrollment token"               secret
prompt ZTP_SERVER_IP  "ztp-server IP (from ACT lab, mgmt iface)"
prompt SERIAL_PREFIX  "Serial-number prefix (your topology.yml uses this)"

save_config
echo

###############################################################################
# sanity-check that topology.yml uses the same prefix
###############################################################################
if ! grep -q "serial_number: ${SERIAL_PREFIX}-" "${PROJECT_DIR}/topology.yml" 2>/dev/null; then
    echo "WARNING: topology.yml does not contain 'serial_number: ${SERIAL_PREFIX}-...'."
    echo "         Edit topology.yml so switch serials are prefixed with '${SERIAL_PREFIX}-',"
    echo "         otherwise devices will register under different IDs than you expect."
    read -r -p "Continue anyway? [y/N] " ans
    [[ "${ans,,}" == "y" ]] || exit 1
fi

###############################################################################
# render bootstrap.py from template
###############################################################################
echo "Rendering bootstrap.py from template..."
# Use a sed delimiter unlikely to appear in tokens/urls.
sed \
    -e "s|__CVAAS_URL__|${CVAAS_URL}|g" \
    -e "s|__CVAAS_TOKEN__|${CVAAS_TOKEN}|g" \
    "${TEMPLATE}" > "${RENDERED}"
chmod 600 "${RENDERED}"

###############################################################################
# check ztp-server reachability — also serves as "is your lab running?" probe
###############################################################################
echo "Checking ztp-server (${ZTP_SERVER_IP}) reachability..."
if ! sshpass -p "${ZTP_PASS}" ssh \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=5 \
        "${ZTP_USER}@${ZTP_SERVER_IP}" "true" 2>/dev/null; then
    echo "ERROR: cannot SSH to ${ZTP_USER}@${ZTP_SERVER_IP}." >&2
    echo "       Is the ACT lab deployed and the ztp-server reachable?" >&2
    exit 1
fi

###############################################################################
# upload + run
###############################################################################
echo "Uploading bootstrap.py and setup-ztp-server.sh..."
sshpass -p "${ZTP_PASS}" ssh \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "${ZTP_USER}@${ZTP_SERVER_IP}" "mkdir -p ${REMOTE_DIR}"

sshpass -p "${ZTP_PASS}" scp \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "${RENDERED}"       "${ZTP_USER}@${ZTP_SERVER_IP}:${REMOTE_DIR}/bootstrap.py"
sshpass -p "${ZTP_PASS}" scp \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "${SETUP_SCRIPT}"   "${ZTP_USER}@${ZTP_SERVER_IP}:/root/setup-ztp-server.sh"

echo "Running setup-ztp-server.sh on the ztp-server..."
sshpass -p "${ZTP_PASS}" ssh \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "${ZTP_USER}@${ZTP_SERVER_IP}" \
    "chmod +x /root/setup-ztp-server.sh && /root/setup-ztp-server.sh"

cat <<EOF

Done.

Next:
  - Switches in ZTP mode will DHCP from the ztp-server, fetch bootstrap.py,
    and register with CVaaS at ${CVAAS_URL}.
  - In CVaaS, you should see devices appear under Inventory with the
    serial numbers from topology.yml (prefix: ${SERIAL_PREFIX}-).
  - If you redeploy the topology, just rerun this script — same serials,
    same CVaaS identity.
EOF
