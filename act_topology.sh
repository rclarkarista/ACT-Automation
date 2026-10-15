#!/usr/bin/env bash
###############################################################################
# act_topology.sh
#
# Upload a topology YAML produced by generate.sh to ACT, and optionally
# create + deploy a lab from it.
#
# Workflow:
#   1. Accepts a topology YAML as an argument (or prompts to pick one).
#   2. Prompts for ACT tenant + API key (cached in .config, shared with
#      onboard.sh).
#   3. Converts the YAML to JSON (via yq) and uploads it to ACT using
#      the REST API.
#   4. If a matching PNG exists, attempts to attach it as the topology
#      diagram.
#   5. Optionally creates and deploys a lab from the new topology.
#
# Dependencies: curl, jq, yq (all single-binary, no Python needed).
###############################################################################

set -euo pipefail
trap 'echo "FAILED at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

# shellcheck source=_common.sh
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

DEFAULT_ACT_TENANT="ce"
POLL_INTERVAL=10

###############################################################################
# usage
###############################################################################
usage() {
    cat <<EOF
Usage: $(basename "$0") [topology-file.yml]

Upload a topology YAML to ACT. If no file is given, prompts you to pick
from the topology files in this directory.

After uploading, the script can optionally create and deploy a lab.
EOF
}

###############################################################################
# select_topology_file — list topology-*.yml files, prompt user to pick one.
# Sets TOPOLOGY_FILE to the chosen path.
###############################################################################
select_topology_file() {
    local topology_files=()

    shopt -s nullglob
    topology_files=("${PROJECT_DIR}"/topology-*.yml)
    shopt -u nullglob

    if (( ${#topology_files[@]} == 0 )); then
        echo "ERROR: no generated topology files found in ${PROJECT_DIR}." >&2
        echo "       Run ./generate.sh first or pass a topology file path." >&2
        exit 1
    fi

    echo "Generated topology files:"
    for i in "${!topology_files[@]}"; do
        printf "  %2d. %s\n" $((i + 1)) "$(basename "${topology_files[i]}")"
    done

    local choice
    while true; do
        read -r -p "Pick a topology [1-${#topology_files[@]}]: " choice
        if [[ "${choice}" =~ ^[0-9]+$ ]] \
            && (( choice >= 1 && choice <= ${#topology_files[@]} )); then
            TOPOLOGY_FILE="${topology_files[choice-1]}"
            return
        fi
        echo "  Invalid choice."
    done
}

###############################################################################
# act_login — authenticate with the ACT API and print the bearer token.
#   Reads ACT_API_KEY and API_BASE from the environment.
###############################################################################
act_login() {
    local resp token
    resp=$(curl -sk "${API_BASE}/auth/login" \
        -H 'Content-Type: application/json' \
        -d "{\"api_key\":\"${ACT_API_KEY}\"}")
    token=$(jq -r '.token // empty' <<< "${resp}")
    if [[ -z "${token}" ]]; then
        echo "ERROR: ACT login failed. Response:" >&2
        echo "${resp}" >&2
        exit 1
    fi
    printf '%s' "${token}"
}

###############################################################################
# act_poll <operation-json> <label> <max-iterations>
#   Poll GET /operations/{id} until is_completed is true.
#   Prints status updates and returns the final operation JSON on stdout.
###############################################################################
act_poll() {
    local op_json=$1 label=$2 max=${3:-30}
    local op_id
    op_id=$(jq -r '.id // empty' <<< "${op_json}")
    if [[ -z "${op_id}" ]]; then
        echo "ERROR: ACT did not return an operation ID for ${label}." >&2
        echo "${op_json}" >&2
        exit 1
    fi

    echo "  Waiting for ${label} (operation ${op_id})..." >&2
    local i result is_done status
    for (( i = 1; i <= max; i++ )); do
        sleep "${POLL_INTERVAL}"
        result=$(curl -sk "${API_BASE}/operations/${op_id}" \
            -H "Authorization: Bearer ${TOKEN}")
        is_done=$(jq -r '.is_completed // false' <<< "${result}")
        if [[ "${is_done}" == "true" ]]; then
            status=$(jq -r '(.status // "unknown") | ascii_downcase' <<< "${result}")
            if [[ "${status}" == "completed" ]]; then
                echo "  ${label}: completed." >&2
                printf '%s' "${result}"
                return 0
            else
                printf '%s' "${result}"
                return 1
            fi
        fi
        printf "  ${label}: still running (%d/%d)...\r" "${i}" "${max}" >&2
    done

    echo >&2
    echo "ERROR: ${label} did not complete after $((max * POLL_INTERVAL))s." >&2
    exit 1
}

###############################################################################
# upload_diagram <topo-id> <png-file>
#   Best-effort attempt to attach the diagram to the topology via PATCH.
#   The ACT API's diagram_path field expects a server-side filename — this
#   tries the PNG basename. If it fails, prints a note and continues.
###############################################################################
upload_diagram() {
    local topo_id=$1 png_file=$2
    local png_name
    png_name=$(basename "${png_file}")

    echo "Attempting to attach diagram ${png_name}..."

    local payload resp
    payload=$(jq -n --arg dp "${png_name}" '{diagram_path: $dp}')
    resp=$(curl -sk -X PATCH "${API_BASE}/topologies/${topo_id}" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        -d "${payload}" \
        -w "\n%{http_code}" 2>&1)

    local http_code body
    http_code=$(tail -1 <<< "${resp}")
    body=$(sed '$d' <<< "${resp}")

    if [[ "${http_code}" =~ ^2 ]]; then
        echo "  Diagram attached."
        return 0
    fi

    echo "  NOTE: Diagram upload returned HTTP ${http_code}." >&2
    echo "  The ACT REST API may not support diagram attachment via this" >&2
    echo "  method. Upload the PNG manually in the ACT web UI:" >&2
    echo "    Topologies → Edit → Diagram File → Upload" >&2
    echo "  (The topology YAML was uploaded successfully.)" >&2
    return 0
}

###############################################################################
# main
###############################################################################

if (( $# > 1 )); then
    usage >&2
    exit 2
fi

if (( $# == 1 )); then
    case "$1" in
        -h|--help) usage; exit 0 ;;
    esac
    TOPOLOGY_FILE=$1
    if [[ "${TOPOLOGY_FILE}" != /* && ! -f "${TOPOLOGY_FILE}" ]]; then
        TOPOLOGY_FILE="${PROJECT_DIR}/${TOPOLOGY_FILE}"
    fi
else
    select_topology_file
fi

if [[ ! -f "${TOPOLOGY_FILE}" ]]; then
    echo "ERROR: topology file not found: ${TOPOLOGY_FILE}" >&2
    exit 1
fi

TOPOLOGY_FILE="$(cd "$(dirname "${TOPOLOGY_FILE}")" && pwd)/$(basename "${TOPOLOGY_FILE}")"
TOPOLOGY_FILENAME="$(basename "${TOPOLOGY_FILE}")"

DIAGRAM_FILE="${TOPOLOGY_FILE%.yml}.png"
HAS_DIAGRAM=0
if [[ -f "${DIAGRAM_FILE}" ]]; then
    HAS_DIAGRAM=1
else
    echo "NOTE: no matching diagram found (${TOPOLOGY_FILENAME%.yml}.png)."
    echo "      The topology will be uploaded without a diagram image."
    echo "      Install graphviz and re-run generate.sh to create one."
    echo
fi

require_tools curl jq yq

load_config

echo
echo "ACT topology upload:"
ACT_TENANT="${ACT_TENANT:-}"
ACT_API_KEY="${ACT_API_KEY:-}"
TOPOLOGY_NAME=""

prompt ACT_TENANT  "ACT tenant"    "${DEFAULT_ACT_TENANT}"
prompt ACT_API_KEY "ACT API key"   secret

for v in ACT_TENANT ACT_API_KEY; do
    if [[ -z "${!v}" ]]; then
        echo "ERROR: ${v} is required and cannot be blank." >&2
        exit 1
    fi
done

DEFAULT_TOPO_NAME="${TOPOLOGY_FILENAME%.yml}"
prompt TOPOLOGY_NAME "Topology name" "${DEFAULT_TOPO_NAME}"

save_config

API_BASE="https://${ACT_TENANT}.act.arista.com/rest/v1"

echo
echo "Logging into ACT (${API_BASE})..."
TOKEN=$(act_login)

TMPDIR_UPLOAD=$(mktemp -d -t act-upload-XXXXXX)
trap 'rm -rf "${TMPDIR_UPLOAD}"' EXIT

echo "Converting ${TOPOLOGY_FILENAME} to JSON..."
yq -o json '.' "${TOPOLOGY_FILE}" > "${TMPDIR_UPLOAD}/topo.json"

jq -n \
    --arg name "${TOPOLOGY_NAME}" \
    --arg desc "Uploaded from ${TOPOLOGY_FILENAME} by act_topology.sh" \
    --slurpfile file "${TMPDIR_UPLOAD}/topo.json" \
    '{name: $name, description: $desc, file: $file[0]}' \
    > "${TMPDIR_UPLOAD}/payload.json"

echo "Uploading topology '${TOPOLOGY_NAME}' to ${ACT_TENANT}.act.arista.com..."
HTTP_CODE=$(curl -sk -X POST "${API_BASE}/topologies" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "@${TMPDIR_UPLOAD}/payload.json" \
    -o "${TMPDIR_UPLOAD}/response.json" \
    -w "%{http_code}")

if ! jq -e '.' "${TMPDIR_UPLOAD}/response.json" >/dev/null 2>&1; then
    echo "ERROR: ACT returned HTTP ${HTTP_CODE} with a non-JSON response:" >&2
    head -c 500 "${TMPDIR_UPLOAD}/response.json" >&2
    echo >&2
    exit 1
fi

SCHEMA_TYPE=$(jq -r '.schema_type // empty' "${TMPDIR_UPLOAD}/response.json")
if [[ "${SCHEMA_TYPE}" != "operation_resource" ]]; then
    echo "ERROR: ACT returned HTTP ${HTTP_CODE}:" >&2
    jq '.' "${TMPDIR_UPLOAD}/response.json" >&2
    exit 1
fi

CREATE_RESP=$(cat "${TMPDIR_UPLOAD}/response.json")

TOPO_EXISTED=0
if OP_RESULT=$(act_poll "${CREATE_RESP}" "topology creation" 30); then
    TOPO_ID=$(jq -r '.result.id // empty' <<< "${OP_RESULT}")
    TOPO_PATHNAME=$(jq -r '.result.topology_pathname // empty' <<< "${OP_RESULT}")
    CREATED_NAME=$(jq -r '.result.name // empty' <<< "${OP_RESULT}")
    echo "Created ACT topology '${CREATED_NAME:-${TOPOLOGY_NAME}}'."
    [[ -n "${TOPO_ID}" ]] && echo "  Topology ID: ${TOPO_ID}"

    if (( HAS_DIAGRAM )) && [[ -n "${TOPO_ID}" ]]; then
        echo
        upload_diagram "${TOPO_ID}" "${DIAGRAM_FILE}"
    fi
else
    ERR_MSG=$(jq -r '.result.error // .error // empty' <<< "${OP_RESULT}")
    if [[ "${ERR_MSG}" == *"already exists"* ]]; then
        echo "Topology '${TOPOLOGY_NAME}' already exists in ACT."

        EXISTING=$(curl -sk "${API_BASE}/topologies?topology_pathname=${TOPOLOGY_NAME}&pageSize=1" \
            -H "Authorization: Bearer ${TOKEN}")
        TOPO_ID=$(jq -r '.result[0].id // empty' <<< "${EXISTING}")
        TOPO_PATHNAME=$(jq -r '.result[0].topology_pathname // empty' <<< "${EXISTING}")

        if [[ -n "${TOPO_ID}" ]]; then
            echo "  Topology ID: ${TOPO_ID}"
            TOPO_EXISTED=1
        else
            echo "  Could not look up the existing topology. Create a lab manually in the ACT UI." >&2
            exit 1
        fi
    else
        echo "ERROR: topology creation failed." >&2
        echo "${ERR_MSG:-$(jq '.' <<< "${OP_RESULT}")}" >&2
        exit 1
    fi
fi

echo
read -r -p "Create and deploy a lab from this topology? [y/N] " deploy_answer
case "${deploy_answer}" in
    [yY]|[yY][eE][sS])
        DEFAULT_LAB_NAME="${TOPOLOGY_NAME%.yml}"
        DEFAULT_LAB_NAME="${DEFAULT_LAB_NAME%.yaml}-lab"
        LAB_NAME=""
        prompt LAB_NAME "Lab name" "${DEFAULT_LAB_NAME}"

        if [[ -z "${TOPO_PATHNAME}" && -n "${TOPO_ID}" ]]; then
            TOPO_RESOURCE=$(curl -sk "${API_BASE}/topologies/${TOPO_ID}" \
                -H "Authorization: Bearer ${TOKEN}")
            TOPO_PATHNAME=$(jq -r '.topology_pathname // empty' <<< "${TOPO_RESOURCE}")
        fi
        if [[ -z "${TOPO_PATHNAME}" ]]; then
            echo "ERROR: could not determine topology_pathname from ACT." >&2
            echo "       Create the lab manually in the ACT UI using topology '${TOPOLOGY_NAME}'." >&2
            exit 1
        fi

        echo
        echo "Creating lab '${LAB_NAME}'..."
        LAB_RESP=$(curl -sk -X POST "${API_BASE}/labs" \
            -H "Authorization: Bearer ${TOKEN}" \
            -H "Content-Type: application/json" \
            -d "$(jq -n \
                --arg name "${LAB_NAME}" \
                --arg desc "Created from ${TOPOLOGY_NAME} by act_topology.sh" \
                --arg topo "${TOPO_PATHNAME}" \
                '{name: $name, description: $desc, topology_definition: $topo}')")

        SCHEMA_TYPE=$(jq -r '.schema_type // empty' <<< "${LAB_RESP}")
        if [[ "${SCHEMA_TYPE}" != "operation_resource" ]]; then
            echo "ERROR: unexpected response creating lab:" >&2
            jq '.' <<< "${LAB_RESP}" >&2
            exit 1
        fi

        LAB_OP_RESULT=$(act_poll "${LAB_RESP}" "lab creation" 30)
        LAB_ID=$(jq -r '.result.id // empty' <<< "${LAB_OP_RESULT}")
        if [[ -z "${LAB_ID}" ]]; then
            echo "ERROR: ACT created the lab but didn't return its ID." >&2
            exit 1
        fi
        echo "Created lab '${LAB_NAME}' (ID: ${LAB_ID})."

        echo
        echo "Deploying lab '${LAB_NAME}'..."
        DEPLOY_RESP=$(curl -sk -X POST "${API_BASE}/labs/${LAB_ID}/deploy" \
            -H "Authorization: Bearer ${TOKEN}" \
            -H "Content-Type: application/json")

        SCHEMA_TYPE=$(jq -r '.schema_type // empty' <<< "${DEPLOY_RESP}")
        if [[ "${SCHEMA_TYPE}" != "operation_resource" ]]; then
            echo "ERROR: unexpected response deploying lab:" >&2
            jq '.' <<< "${DEPLOY_RESP}" >&2
            exit 1
        fi

        act_poll "${DEPLOY_RESP}" "lab deployment" 120 > /dev/null
        echo "Deployed lab '${LAB_NAME}'."
        echo
        echo "Done. Wait for the lab to reach Running state, then run:"
        echo "  ./onboard.sh"
        ;;
    *)
        echo
        echo "Done. Deploy the topology in the ACT UI when ready, then run:"
        echo "  ./onboard.sh"
        ;;
esac
