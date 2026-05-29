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
bash
echo "${CVAAS_TOKEN}" > /tmp/cv-onboarding-token
exit
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
    "\(.hostname)\t\(.internal_ip)\t\(.shell_logins[0].username)\t\(.shell_logins[0].password)"' \
    <<< "${LAB_RESP}")
if [[ -z "${DEVICES}" ]]; then
    echo "ERROR: no vEOS devices found in lab ${LAB_NAME} (${LAB_ID})." >&2
    exit 1
fi

dev_count=$(grep -c . <<< "${DEVICES}")
echo
echo "Lab: ${LAB_NAME}"
echo "Will paste TerminAttr config to ${dev_count} vEOS device(s):"
while IFS=$'\t' read -r host ip _ _; do
    printf "  %-12s  %s\n" "${host}" "${ip}"
done <<< "${DEVICES}"
echo
read -r -p "Continue? [y/N] " ans
case "${ans}" in [Yy]*) ;; *) echo "Aborted."; exit 1 ;; esac

###############################################################################
# paste the snippet to each device
###############################################################################
echo
echo "Pasting TerminAttr snippet to each switch..."
echo "------------------------------------------------------------------------"
FAILED=()
while IFS=$'\t' read -r host ip user pw; do
    printf "  %-12s  %-16s  " "${host}" "${ip}"
    if sshpass -p "${pw}" ssh \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -o LogLevel=ERROR \
            -o ConnectTimeout=10 \
            "${user}@${ip}" <<< "${SNIPPET}" >/dev/null 2>&1; then
        echo "ok"
    else
        echo "FAILED"
        FAILED+=("${host}")
    fi
done <<< "${DEVICES}"
echo "------------------------------------------------------------------------"

if (( ${#FAILED[@]} > 0 )); then
    echo
    echo "Some switches failed: ${FAILED[*]}"
    echo "Paste this snippet into them manually:"
    echo "${SNIPPET}"
    exit 1
fi

echo
echo "Done. Devices should appear in CVaaS Inventory within ~1 minute."
