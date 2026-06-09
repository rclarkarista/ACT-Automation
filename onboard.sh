#!/usr/bin/env bash
###############################################################################
# onboard.sh
#
# Onboards every vEOS switch in one of your Running ACT labs to CVaaS via
# TerminAttr.
#
# Workflow:
#   1. Prompts (once, cached in .config) for:
#        ACT_TENANT, ACT_USER, ACT_API_KEY
#        CVAAS_TOKEN
#   2. Lists your Running labs via the ACT API.
#        - 0 running -> tells you to deploy/start one in the ACT UI.
#        - 1 running -> uses it.
#        - 2+ running -> prompts you to pick.
#   3. SSH-pastes the TerminAttr onboarding snippet to every vEOS device in
#      the chosen lab. They appear in CVaaS Inventory within ~1 minute.
#
# Because each switch's serial_number is pinned in the topology file (see
# generate.sh), devices keep the same CVaaS identity across redeploys.
###############################################################################

set -euo pipefail

# shellcheck source=_common.sh
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

DEFAULT_ACT_TENANT="ce"

# EOS CLI credentials.
# - EOS_USER is always cvpadmin (every topology in this toolkit uses it).
# - EOS_PASS is resolved per-lab from the topology's `veos:` block (see
#   resolve_eos_password() further down), with cvp123! as the final fallback.
#   This lets us onboard topologies that came from elsewhere and happen to
#   use a different password (e.g. arista123).
# Never use shell_logins[] from the ACT API — that's the Linux underlay
# account, which lands sshpass in bash instead of EOS CLI.
EOS_USER="cvpadmin"
EOS_PASS=""
EOS_PASS_DEFAULT="cvp123!"

CVAAS_HOST="apiserver.arista.io"
CVAAS_PORT="443"

# Per-phase concurrency. Conservative default — ACT's outbound NAT and
# per-vEOS readiness timing can cause transient failures when too many
# devices fire simultaneously. Override with `PARALLELISM=N ./onboard.sh`
# (e.g. 8 or 16) for larger labs. Each phase also retries any failures
# serially before declaring them real, so transient hiccups are caught
# even at higher parallelism.
MAX_PARALLEL="${PARALLELISM:-4}"

# These vars are read by the per-device worker functions running in xargs
# subshells, so they need to live in the environment. SNIPPET, LOG_DIR, and
# updated EOS_PASS are exported here too — bash carries the export attribute
# forward, so later assignments propagate automatically.
export EOS_USER EOS_PASS CVAAS_HOST CVAAS_PORT SNIPPET LOG_DIR

###############################################################################
# extract_veos_password — read a YAML topology on stdin, print the password
# field from inside the `veos:` block. Handles bare, single-quoted, and
# double-quoted values. Prints nothing if not found.
###############################################################################
extract_veos_password() {
    awk '/^veos:/                    { in_block=1; next }
         /^[a-zA-Z]/                 { in_block=0 }
         in_block && $1 == "password:" { print $2; exit }' \
    | sed "s/^[\"']//; s/[\"']\$//"
}

###############################################################################
# extract_veos_hostnames — read a YAML topology on stdin, print one hostname
# per line for every node with `node_type: veos`. Skips commented-out nodes
# and ignores any block that isn't under `nodes:`. Used to filter the ACT
# API's device list down to actual EOS devices (so we don't try to SSH and
# paste a token into a CVP / Linux / third-party node that happens to be
# returned by the API under .devices.veos[]).
###############################################################################
extract_veos_hostnames() {
    awk '
        BEGIN { in_nodes=0; current=""; type="" }
        /^nodes:/                  { in_nodes=1; next }
        in_nodes && /^[a-zA-Z]/ {
            if (type == "veos" && current != "") print current
            in_nodes=0; current=""; type=""
        }
        in_nodes && /^  - [a-zA-Z]/ {
            if (type == "veos" && current != "") print current
            sub(/^  - /, ""); sub(/:.*$/, "")
            current=$0; type=""
        }
        in_nodes && /^[[:space:]]+node_type:[[:space:]]+/ {
            sub(/^[[:space:]]+node_type:[[:space:]]+/, "")
            sub(/[[:space:]]*#.*$/, "")
            gsub(/[[:space:]]/, "")
            type=$0
        }
        END { if (type == "veos" && current != "") print current }
    '
}

###############################################################################
# ssh_eos <ip> — open an EOS CLI session on the device. Reads CLI commands
# from stdin; caller redirects stdout/stderr.
###############################################################################
ssh_eos() {
    local ip=$1
    sshpass -p "${EOS_PASS}" ssh \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -o ConnectTimeout=10 \
        "${EOS_USER}@${ip}"
}

###############################################################################
# Per-device worker functions — one per phase. Each takes (host, ip), writes
# its full SSH output to ${LOG_DIR}/<host>.<phase>.log, and prints a single
# completion line to stdout. Invoked in parallel via `xargs -0 -P` later;
# output appears in completion order, not device order. Per-phase failure
# detection happens after the fan-out finishes (see derive-* loops below).
###############################################################################
preflight_worker() {
    local host=$1 ip=$2
    local log="${LOG_DIR}/${host}.preflight.log"
    ssh_eos "${ip}" <<EOSCHECK > "${log}" 2>&1
enable
bash curl --connect-timeout 5 -sS -o /dev/null https://${CVAAS_HOST}:${CVAAS_PORT}/ && echo CVAAS_OK
EOSCHECK
    if grep -q "CVAAS_OK" "${log}"; then
        printf "  %-30s  %-16s  reachable\n" "${host}" "${ip}"
    else
        printf "  %-30s  %-16s  UNREACHABLE\n" "${host}" "${ip}"
    fi
}

paste_worker() {
    local host=$1 ip=$2
    local log="${LOG_DIR}/${host}.paste.log"
    if ssh_eos "${ip}" <<< "${SNIPPET}" > "${log}" 2>&1; then
        # Marker file so the post-loop derivation knows this device succeeded
        # (ssh's exit code is otherwise lost across the xargs subshell boundary).
        touch "${log}.ok"
        printf "  %-30s  %-16s  ok\n" "${host}" "${ip}"
    else
        printf "  %-30s  %-16s  FAILED (see %s)\n" "${host}" "${ip}" "${log}"
    fi
}

postcheck_worker() {
    local host=$1 ip=$2
    local log="${LOG_DIR}/${host}.terminattr.log"
    ssh_eos "${ip}" <<< "enable
show agent TerminAttr logs" > "${log}" 2>&1 || true
    local pattern='TCP dial failed|server misbehaving|no such host|connection refused|no route to host|context deadline exceeded'
    if grep -qE "${pattern}" "${log}"; then
        printf "  %-30s  %-16s  errors found (see %s)\n" "${host}" "${ip}" "${log}"
    else
        printf "  %-30s  %-16s  clean\n" "${host}" "${ip}"
    fi
}

export -f ssh_eos preflight_worker paste_worker postcheck_worker

###############################################################################
# fanout <worker-name> — read DEVICES on stdin (tab-separated host\tip lines)
# and dispatch <worker-name> across them with bounded concurrency. Output
# arrives in completion order.
###############################################################################
fanout() {
    local worker=$1
    while IFS=$'\t' read -r host ip; do
        [[ -z "$host" ]] && continue
        printf '%s\0%s\0' "$host" "$ip"
    done | xargs -0 -n 2 -P "${MAX_PARALLEL}" bash -c "${worker} \"\$1\" \"\$2\"" _
}

###############################################################################
# load cached config + prompt for anything missing
###############################################################################
ACT_TENANT=""
ACT_USER=""
ACT_API_KEY=""
CVAAS_TOKEN=""

load_config

echo
echo "ACT API access:"
prompt ACT_TENANT  "ACT tenant"                              "${DEFAULT_ACT_TENANT}"
prompt ACT_USER    "ACT username (e.g. firstname.lastname)"
prompt ACT_API_KEY "ACT API key"                              secret

echo
echo "CVaaS onboarding:"
prompt CVAAS_TOKEN "CVaaS enrollment token"                   secret

for v in ACT_TENANT ACT_USER ACT_API_KEY CVAAS_TOKEN; do
    if [[ -z "${!v}" ]]; then
        echo "ERROR: ${v} is required and cannot be blank." >&2
        exit 1
    fi
done

save_config
echo

###############################################################################
# build the EOS snippet (used by the auto-paste loop, and printed verbatim
# for any device that fails so you can finish by hand)
###############################################################################
SNIPPET=$(cat <<EOSPASTE
enable
bash echo "${CVAAS_TOKEN}" > /tmp/cv-onboarding-token
configure
daemon TerminAttr
   exec /usr/bin/TerminAttr -smashexcludes=ale,flexCounter,hardware,kni,pulse,strata -cvaddr=apiserver.arista.io:443 -cvauth=token-secure,/tmp/cv-onboarding-token -taillogs
   shutdown
   no shutdown
end
write
EOSPASTE
)

###############################################################################
# look up Running labs and pick one
###############################################################################
require_tools curl jq sshpass

API_BASE="https://${ACT_TENANT}.act.arista.com/rest/v1"

echo "Logging into ACT (${API_BASE})..."
LOGIN_RESP=$(curl -sk "${API_BASE}/auth/login" \
    -H 'Content-Type: application/json' \
    -d "{\"api_key\":\"${ACT_API_KEY}\"}")
TOKEN=$(jq -r '.token // empty' <<< "${LOGIN_RESP}")
if [[ -z "${TOKEN}" ]]; then
    echo "ERROR: ACT login failed. Response:" >&2
    echo "${LOGIN_RESP}" >&2
    exit 1
fi

echo "Listing Running labs for user=${ACT_USER}..."
LABS_RESP=$(curl -sk "${API_BASE}/labs?user=${ACT_USER}&pageSize=200" \
    -H "Authorization: Bearer ${TOKEN}")

RUNNING_IDS=()
RUNNING_NAMES=()
RUNNING_TOPOS=()
while IFS=$'\t' read -r id name topo; do
    [[ -z "${id}" ]] && continue
    RUNNING_IDS+=("${id}")
    RUNNING_NAMES+=("${name}")
    RUNNING_TOPOS+=("${topo}")
done < <(jq -r '.result[] | select(.state == 2) | "\(.id)\t\(.name)\t\(.topology_definition)"' \
    <<< "${LABS_RESP}")

count=${#RUNNING_IDS[@]}
if (( count == 0 )); then
    echo
    echo "No Running labs found for user=${ACT_USER}."
    echo "Deploy or start a lab in the ACT UI, then re-run this script."
    exit 1
fi

if (( count == 1 )); then
    LAB_ID="${RUNNING_IDS[0]}"
    LAB_NAME="${RUNNING_NAMES[0]}"
    echo "Found 1 Running lab: ${LAB_NAME}  (${LAB_ID})"
else
    echo
    echo "Your Running labs:"
    for i in "${!RUNNING_IDS[@]}"; do
        printf "  %2d. %-50s  topology=%s\n" \
            $((i+1)) "${RUNNING_NAMES[i]}" "${RUNNING_TOPOS[i]}"
    done
    echo
    while true; do
        read -r -p "Pick a lab [1-${count}]: " choice
        if [[ "${choice}" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= count )); then
            break
        fi
        echo "  Invalid choice."
    done
    LAB_ID="${RUNNING_IDS[choice-1]}"
    LAB_NAME="${RUNNING_NAMES[choice-1]}"
fi

###############################################################################
# fetch the lab's devices and confirm before pasting
###############################################################################
LAB_RESP=$(curl -sk "${API_BASE}/labs/${LAB_ID}" \
    -H "Authorization: Bearer ${TOKEN}")

DEVICES=$(jq -r '.devices.veos[]? |
    "\(.hostname)\t\(.internal_ip)"' \
    <<< "${LAB_RESP}")
if [[ -z "${DEVICES}" ]]; then
    echo "ERROR: no vEOS devices found in lab ${LAB_NAME} (${LAB_ID})." >&2
    exit 1
fi

###############################################################################
# pull the topology YAML once and use it for two things:
#   1. resolve the EOS password from the `veos:` block
#   2. filter ${DEVICES} down to only nodes with `node_type: veos`
#      (so CVP / Linux / third-party nodes never get a token paste attempt)
#
# YAML sources tried in order:
#   - local file at ${PROJECT_DIR}/<topology_definition>  (fastest, no API)
#   - ACT API /topologies/<topology_definition>           (works for shared labs)
###############################################################################
TOPO_NAME=$(jq -r '.topology_definition // empty' <<< "${LAB_RESP}")
[[ -z "${TOPO_NAME}" ]] && TOPO_NAME="${RUNNING_TOPOS[choice-1]:-}"

TOPO_YAML=""
TOPO_SOURCE=""
if [[ -n "${TOPO_NAME}" && -f "${PROJECT_DIR}/${TOPO_NAME}" ]]; then
    TOPO_YAML=$(cat "${PROJECT_DIR}/${TOPO_NAME}")
    TOPO_SOURCE="local ${TOPO_NAME}"
elif [[ -n "${TOPO_NAME}" ]]; then
    # ACT API endpoint is a best-guess; some tenants wrap YAML in JSON.
    TOPO_RESP=$(curl -sk "${API_BASE}/topologies/${TOPO_NAME}" \
        -H "Authorization: Bearer ${TOKEN}" 2>/dev/null || true)
    if [[ -n "${TOPO_RESP}" ]]; then
        content=$(jq -r '.content // .data // empty' <<< "${TOPO_RESP}" 2>/dev/null || true)
        [[ -z "${content}" || "${content}" == "null" ]] && content="${TOPO_RESP}"
        if [[ -n "${content}" ]]; then
            TOPO_YAML="${content}"
            TOPO_SOURCE="ACT API (${TOPO_NAME})"
        fi
    fi
fi

# EOS password
if [[ -n "${TOPO_YAML}" ]]; then
    EOS_PASS=$(extract_veos_password <<< "${TOPO_YAML}")
fi
if [[ -n "${EOS_PASS}" ]]; then
    echo "EOS password: from ${TOPO_SOURCE}"
else
    EOS_PASS="${EOS_PASS_DEFAULT}"
    echo "EOS password: could not auto-detect from topology; defaulting to ${EOS_PASS_DEFAULT}"
fi

# Filter ${DEVICES} to only nodes the topology declares as `node_type: veos`.
# We only apply this filter when we actually have the YAML — otherwise we trust
# the API's `.devices.veos[]` filter as-is rather than dropping everything.
if [[ -n "${TOPO_YAML}" ]]; then
    VEOS_NAMES=$(extract_veos_hostnames <<< "${TOPO_YAML}")
    if [[ -n "${VEOS_NAMES}" ]]; then
        SKIPPED=()
        NEW_DEVICES=""
        while IFS=$'\t' read -r host ip; do
            [[ -z "${host}" ]] && continue
            if grep -Fxq "${host}" <<< "${VEOS_NAMES}"; then
                NEW_DEVICES+="${host}"$'\t'"${ip}"$'\n'
            else
                SKIPPED+=("${host}")
            fi
        done <<< "${DEVICES}"
        if (( ${#SKIPPED[@]} > 0 )); then
            echo "Skipping ${#SKIPPED[@]} non-EOS device(s) per topology: ${SKIPPED[*]}"
        fi
        DEVICES="${NEW_DEVICES%$'\n'}"
        if [[ -z "${DEVICES}" ]]; then
            echo "ERROR: no EOS devices remain after topology filter." >&2
            exit 1
        fi
    fi
fi

dev_count=$(grep -c . <<< "${DEVICES}")
echo
echo "Lab: ${LAB_NAME}"
echo "Will paste TerminAttr config to ${dev_count} vEOS device(s):"
while IFS=$'\t' read -r host ip; do
    printf "  %-12s  %s\n" "${host}" "${ip}"
done <<< "${DEVICES}"
echo
read -r -p "Continue? [y/N] " ans
case "${ans}" in [Yy]*) ;; *) echo "Aborted."; exit 1 ;; esac

# All three phases write per-device logs here. Created once, reused across
# the run so the user can grep into any single device's history.
LOG_DIR="$(mktemp -d -t onboard-XXXXXX)"

###############################################################################
# pre-flight: every device must be able to reach apiserver.arista.io:443.
# TerminAttr won't register with CVaaS without it, and the failure mode is
# silent from the script's point of view (config pastes "ok" but the daemon
# can never connect). Abort here so the user fixes the network first.
###############################################################################
echo
echo "Pre-flight: checking CVaaS reachability from each device (parallel ${MAX_PARALLEL}-wide)..."
echo "------------------------------------------------------------------------"
fanout preflight_worker <<< "${DEVICES}"
echo "------------------------------------------------------------------------"

# Derive UNREACHABLE list in API/device order (xargs returned in completion order).
UNREACHABLE=()
while IFS=$'\t' read -r host ip; do
    [[ -z "$host" ]] && continue
    if ! grep -q "CVAAS_OK" "${LOG_DIR}/${host}.preflight.log" 2>/dev/null; then
        UNREACHABLE+=("${host}")
    fi
done <<< "${DEVICES}"

# Retry pass: try unreachable devices one more time serially. Catches
# transient parallel-contention failures (NAT, DNS races, vEOS curl timing)
# without giving up the speedup for the common case.
if (( ${#UNREACHABLE[@]} > 0 )); then
    echo
    echo "Retrying ${#UNREACHABLE[@]} unreachable device(s) serially..."
    echo "------------------------------------------------------------------------"
    STILL_UNREACHABLE=()
    for host in "${UNREACHABLE[@]}"; do
        ip=$(awk -F'\t' -v h="$host" '$1 == h { print $2 }' <<< "${DEVICES}")
        preflight_worker "$host" "$ip"
        if ! grep -q "CVAAS_OK" "${LOG_DIR}/${host}.preflight.log" 2>/dev/null; then
            STILL_UNREACHABLE+=("${host}")
        fi
    done
    echo "------------------------------------------------------------------------"
    UNREACHABLE=("${STILL_UNREACHABLE[@]+"${STILL_UNREACHABLE[@]}"}")
fi

if (( ${#UNREACHABLE[@]} > 0 )); then
    echo
    echo "ERROR: ${#UNREACHABLE[@]} device(s) cannot reach ${CVAAS_HOST}:${CVAAS_PORT}:"
    printf "    %s\n" "${UNREACHABLE[@]}"
    echo
    echo "TerminAttr needs outbound HTTPS to ${CVAAS_HOST}:${CVAAS_PORT} to register"
    echo "with CVaaS. Fix internet / DNS on the lab's management network first,"
    echo "then re-run this script. No config has been pushed."
    exit 1
fi

###############################################################################
# paste the snippet to each device
###############################################################################
echo
echo "Pasting TerminAttr snippet to each switch (parallel ${MAX_PARALLEL}-wide)..."
echo "------------------------------------------------------------------------"
fanout paste_worker <<< "${DEVICES}"
echo "------------------------------------------------------------------------"

# Derive FAILED list — paste_worker touches <log>.ok on success.
FAILED=()
while IFS=$'\t' read -r host ip; do
    [[ -z "$host" ]] && continue
    [[ -f "${LOG_DIR}/${host}.paste.log.ok" ]] || FAILED+=("${host}")
done <<< "${DEVICES}"

# Retry pass — same rationale as the pre-flight retry. The snippet is
# idempotent (configure / daemon / write to the same final state) so a
# retry against a partially-configured device finishes the job cleanly.
if (( ${#FAILED[@]} > 0 )); then
    echo
    echo "Retrying ${#FAILED[@]} failed device(s) serially..."
    echo "------------------------------------------------------------------------"
    STILL_FAILED=()
    for host in "${FAILED[@]}"; do
        ip=$(awk -F'\t' -v h="$host" '$1 == h { print $2 }' <<< "${DEVICES}")
        rm -f "${LOG_DIR}/${host}.paste.log.ok"
        paste_worker "$host" "$ip"
        [[ -f "${LOG_DIR}/${host}.paste.log.ok" ]] || STILL_FAILED+=("${host}")
    done
    echo "------------------------------------------------------------------------"
    FAILED=("${STILL_FAILED[@]+"${STILL_FAILED[@]}"}")
fi

if (( ${#FAILED[@]} > 0 )); then
    echo
    echo "Some switches failed: ${FAILED[*]}"
    echo "Paste this snippet into them manually:"
    echo "${SNIPPET}"
    exit 1
fi

###############################################################################
# post-check: give TerminAttr a few seconds to attempt registration, then
# scan `show agent TerminAttr logs` on each device for connection errors.
# This catches cases where the curl pre-flight worked but TerminAttr is
# still failing — e.g., daemon uses a different VRF / route, intermittent
# DNS, or a firewall that allows the short pre-flight probe but blocks
# the long-lived gRPC connection.
###############################################################################
echo
echo "Waiting 15s for TerminAttr to attempt registration..."
sleep 15
echo
echo "Checking TerminAttr logs on each device (parallel ${MAX_PARALLEL}-wide)..."
echo "------------------------------------------------------------------------"
fanout postcheck_worker <<< "${DEVICES}"
echo "------------------------------------------------------------------------"

# Derive LOG_ERRORS list — same error pattern the worker uses, applied to the
# per-device log it wrote. (Kept in sync with postcheck_worker's pattern.)
ERROR_PATTERN='TCP dial failed|server misbehaving|no such host|connection refused|no route to host|context deadline exceeded'
LOG_ERRORS=()
while IFS=$'\t' read -r host ip; do
    [[ -z "$host" ]] && continue
    if grep -qE "${ERROR_PATTERN}" "${LOG_DIR}/${host}.terminattr.log" 2>/dev/null; then
        LOG_ERRORS+=("${host}")
    fi
done <<< "${DEVICES}"

# Retry pass — re-pull logs serially. TerminAttr may have had a transient
# error during startup but recovered by now, and the fresh log will show
# only the steady-state status.
if (( ${#LOG_ERRORS[@]} > 0 )); then
    echo
    echo "Retrying ${#LOG_ERRORS[@]} device(s) with logged errors serially..."
    echo "------------------------------------------------------------------------"
    STILL_ERRORS=()
    for host in "${LOG_ERRORS[@]}"; do
        ip=$(awk -F'\t' -v h="$host" '$1 == h { print $2 }' <<< "${DEVICES}")
        postcheck_worker "$host" "$ip"
        if grep -qE "${ERROR_PATTERN}" "${LOG_DIR}/${host}.terminattr.log" 2>/dev/null; then
            STILL_ERRORS+=("${host}")
        fi
    done
    echo "------------------------------------------------------------------------"
    LOG_ERRORS=("${STILL_ERRORS[@]+"${STILL_ERRORS[@]}"}")
fi

if (( ${#LOG_ERRORS[@]} > 0 )); then
    echo
    echo "WARNING: ${#LOG_ERRORS[@]} device(s) show TerminAttr connection errors:"
    printf "    %s\n" "${LOG_ERRORS[@]}"
    echo
    echo "Pre-flight to ${CVAAS_HOST}:${CVAAS_PORT} worked, but TerminAttr itself"
    echo "is failing to register. Likely causes:"
    echo "  - TerminAttr uses a different VRF / source interface than the curl"
    echo "    probe, and that path can't reach CVaaS"
    echo "  - DNS is intermittent or misconfigured (look for 'server misbehaving')"
    echo "  - Firewall allows the short HTTPS probe but blocks the long-lived"
    echo "    gRPC connection TerminAttr holds open"
    echo
    echo "Inspect a device directly:"
    echo "  ssh ${EOS_USER}@<device-ip>  →  show agent TerminAttr logs"
    exit 1
fi

echo
echo "Done. Devices should appear in CVaaS Inventory within ~1 minute."
