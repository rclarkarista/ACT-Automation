#!/usr/bin/env bash
###############################################################################
# act_topology.sh
#
# Upload a topology produced by generate.sh to the authenticated user's ACT
# account using the actrac Python client. The matching PNG is validated locally
# but is not uploaded. The ACT API key is collected with a hidden prompt and
# used only for the current execution.
###############################################################################

set -euo pipefail

# shellcheck source=_common.sh
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

DEFAULT_ACT_TENANT="CE"

usage() {
    cat <<EOF
Usage: $(basename "$0") [topology-file]

Upload a topology YAML file produced by generate.sh to ACT. Its matching PNG
is validated locally but is not uploaded. If no YAML file is provided, the
script prompts you to select one from this repository. After creating the
topology, the script can optionally create and deploy a lab from it.
EOF
}

select_topology_file() {
    local topology_files=()
    local choice

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

if (( $# > 1 )); then
    usage >&2
    exit 2
fi

if (( $# == 1 )); then
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
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
case "${TOPOLOGY_FILENAME}" in
    topology-*.yml) ;;
    *)
        echo "ERROR: expected a generate.sh file named topology-<prefix>-<date>.yml." >&2
        echo "       Got: ${TOPOLOGY_FILENAME}" >&2
        exit 1
        ;;
esac
DEFAULT_TOPOLOGY_NAME="${TOPOLOGY_FILENAME}"
DIAGRAM_FILE="${TOPOLOGY_FILE%.yml}.png"
DIAGRAM_FILENAME="$(basename "${DIAGRAM_FILE}")"

if [[ ! -f "${DIAGRAM_FILE}" ]]; then
    echo "ERROR: matching topology diagram not found: ${DIAGRAM_FILE}" >&2
    echo "       Re-run ./generate.sh with Graphviz installed to create it." >&2
    exit 1
fi

require_tools python3
if ! python3 -c 'from actrac.client import ACTClient; import yaml' >/dev/null 2>&1; then
    echo "ERROR: Python packages actrac and PyYAML are required." >&2
    echo "       Open this repository in its dev container or run:" >&2
    echo "       python3 -m pip install actrac PyYAML" >&2
    exit 1
fi

echo
echo "Validating ${TOPOLOGY_FILENAME} and ${DIAGRAM_FILENAME}..."
python3 - "${TOPOLOGY_FILE}" "${DIAGRAM_FILE}" <<'PY'
from pathlib import Path
import struct
import sys

import yaml


def validation_error(message: str) -> None:
    raise ValueError(f"invalid ACT topology: {message}")


topology_file = Path(sys.argv[1])
diagram_file = Path(sys.argv[2])
try:
    topology = yaml.safe_load(topology_file.read_text(encoding="utf-8"))
    if not isinstance(topology, dict):
        validation_error("the YAML root must be a mapping")

    for section in ("veos", "settings"):
        if not isinstance(topology.get(section), dict):
            validation_error(f"'{section}' must be a mapping")

    nodes = topology.get("nodes")
    if not isinstance(nodes, list) or not nodes:
        validation_error("'nodes' must be a non-empty list")

    node_names = set()
    for index, node_entry in enumerate(nodes, start=1):
        if not isinstance(node_entry, dict) or len(node_entry) != 1:
            validation_error(f"node {index} must contain exactly one named node")
        node_name, node_config = next(iter(node_entry.items()))
        if not isinstance(node_name, str) or not node_name.strip():
            validation_error(f"node {index} has an empty name")
        if node_name in node_names:
            validation_error(f"duplicate node name '{node_name}'")
        if not isinstance(node_config, dict):
            validation_error(f"node '{node_name}' configuration must be a mapping")
        if not node_config.get("node_type"):
            validation_error(f"node '{node_name}' is missing 'node_type'")
        node_names.add(node_name)

    links = topology.get("links")
    if not isinstance(links, list) or not links:
        validation_error("'links' must be a non-empty list")

    for index, link_entry in enumerate(links, start=1):
        if not isinstance(link_entry, dict):
            validation_error(f"link {index} must be a mapping")
        connection = link_entry.get("connection")
        if not isinstance(connection, list) or len(connection) != 2:
            validation_error(f"link {index} must have exactly two connection endpoints")
        for endpoint in connection:
            if not isinstance(endpoint, str) or ":" not in endpoint:
                validation_error(f"link {index} has invalid endpoint '{endpoint}'")
            linked_node = endpoint.split(":", 1)[0]
            if linked_node not in node_names:
                validation_error(
                    f"link {index} references unknown node '{linked_node}'"
                )

    with diagram_file.open("rb") as stream:
        png_header = stream.read(24)
    if len(png_header) < 24 or png_header[:8] != b"\x89PNG\r\n\x1a\n":
        validation_error(f"'{diagram_file.name}' is not a valid PNG file")
    if png_header[12:16] != b"IHDR":
        validation_error(f"'{diagram_file.name}' has no PNG IHDR header")
    diagram_width, diagram_height = struct.unpack(">II", png_header[16:24])
    if diagram_width == 0 or diagram_height == 0:
        validation_error(f"'{diagram_file.name}' has invalid dimensions")
except (OSError, yaml.YAMLError, ValueError) as exc:
    print(f"ERROR: {exc}", file=sys.stderr)
    raise SystemExit(1) from exc

print(
    f"Validation passed: {len(node_names)} nodes, {len(links)} links, "
    f"diagram {diagram_width}x{diagram_height}."
)
PY

TOPOLOGY_NAME=""
ACT_TENANT=""
ACT_API_KEY=""
DEPLOY_LAB="no"
LAB_NAME=""

echo
echo "ACT topology upload:"
prompt TOPOLOGY_NAME "Topology name" "${DEFAULT_TOPOLOGY_NAME}"
prompt ACT_TENANT "ACT tenant" "${DEFAULT_ACT_TENANT}"
ACT_TENANT=$(printf '%s' "${ACT_TENANT}" | tr '[:upper:]' '[:lower:]')
if ! [[ "${ACT_TENANT}" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    echo "ERROR: ACT tenant must contain only letters, numbers, and hyphens." >&2
    exit 1
fi

while [[ -z "${ACT_API_KEY}" ]]; do
    prompt ACT_API_KEY "ACT API key" secret
    [[ -z "${ACT_API_KEY}" ]] && echo "  ACT API key cannot be blank."
done

# Remove the prompted token from the shell as soon as this execution ends.
trap 'unset ACT_API_KEY' EXIT

read -r -p "  Create and deploy a lab from this topology? [y/N] " deploy_answer
case "${deploy_answer}" in
    [yY]|[yY][eE][sS])
        DEPLOY_LAB="yes"
        DEFAULT_LAB_NAME="${TOPOLOGY_NAME}"
        DEFAULT_LAB_NAME="${DEFAULT_LAB_NAME%.yml}"
        DEFAULT_LAB_NAME="${DEFAULT_LAB_NAME%.yaml}-lab"
        prompt LAB_NAME "Lab name" "${DEFAULT_LAB_NAME}"
        ;;
esac

echo
echo "Uploading ${TOPOLOGY_FILENAME} as '${TOPOLOGY_NAME}' to ${ACT_TENANT}.act.arista.com..."
echo "NOTE: ${DIAGRAM_FILENAME} was validated locally but will not be uploaded."

printf '%s\n' "${ACT_API_KEY}" | python3 /dev/fd/3 \
    "${TOPOLOGY_FILE}" "${TOPOLOGY_NAME}" "${ACT_TENANT}" \
    "${DEPLOY_LAB}" "${LAB_NAME}" 3<<'PY'
import json
from pathlib import Path
import sys

from actrac.client import ACTClient


def wait_for_operation(client: ACTClient, operation: dict, action: str, iterations: int) -> dict:
    """Validate and poll an ACT asynchronous operation."""
    if not operation or operation.get("schema_type") != "operation_resource":
        raise RuntimeError(
            f"ACT did not return an operation for {action}: "
            f"{json.dumps(operation, default=str)}"
        )

    operation_id = operation.get("id")
    print(
        f"ACT accepted {action} operation "
        f"{operation_id or '(ID unavailable)'}. Waiting for completion..."
    )
    operation_result = client.api.poll_operation(
        operation,
        poll_iterations=iterations,
        poll_sleep=10,
    )
    if not operation_result:
        raise RuntimeError(f"ACT returned no result while polling {action}")

    operation_status = str(operation_result.get("status", "unknown"))
    if operation_status.lower() != "completed":
        details = operation_result.get("result") or operation_result.get("message")
        raise RuntimeError(
            f"ACT {action} ended with status '{operation_status}': "
            f"{json.dumps(details, default=str)}"
        )

    result = operation_result.get("result")
    if not isinstance(result, dict) or not result:
        raise RuntimeError(f"ACT completed {action} without a result")
    return result


topology_file = Path(sys.argv[1])
topology_name = sys.argv[2]
tenant = sys.argv[3]
deploy_lab = sys.argv[4] == "yes"
lab_name = sys.argv[5]
api_key = sys.stdin.readline().rstrip("\n")
if not api_key:
    raise SystemExit("ERROR: ACT API key was not provided")

client = None
try:
    client = ACTClient(
        api_key=api_key,
        base_url=f"https://{tenant}.act.arista.com",
        cert=True,
    )
    client.connect()
    operation = client.api.create_topology(
        name=topology_name,
        description=f"Uploaded from {topology_file.name} by act_topology.sh",
        topo_def_file_path=str(topology_file),
        # TODO: Validate the supported diagram upload workflow with the ACT team.
        # actrac 1.2.0 passes this value to ACT as a server-side path, so a local
        # PNG path causes topology creation to fail with an HTTP 500 operation.
    )
    result = wait_for_operation(client, operation, "topology creation", 30)

    created_id = result.get("id")
    created_name = result.get("name", topology_name)
    print(f"Created ACT topology '{created_name}'.")
    if created_id:
        print(f"Topology ID: {created_id}")

    if deploy_lab:
        topology_pathname = result.get("topology_pathname")
        if not topology_pathname and created_id:
            topology_resource = client.api.read_topology(created_id)
            if isinstance(topology_resource, dict):
                topology_pathname = topology_resource.get("topology_pathname")
        if not topology_pathname:
            raise RuntimeError(
                "ACT did not return the topology pathname required to create a lab"
            )

        lab_operation = client.api.create_lab(
            name=lab_name,
            description=f"Created from topology '{created_name}' by act_topology.sh",
            topo_def=topology_pathname,
        )
        lab_result = wait_for_operation(client, lab_operation, "lab creation", 30)
        lab_id = lab_result.get("id")
        if not lab_id:
            raise RuntimeError("ACT created the lab without returning its ID")
        print(f"Created ACT lab '{lab_result.get('name', lab_name)}'.")
        print(f"Lab ID: {lab_id}")

        deploy_operation = client.api.deploy_lab(lab_id)
        deployed_lab = wait_for_operation(client, deploy_operation, "lab deployment", 120)
        print(f"Deployed ACT lab '{deployed_lab.get('name', lab_name)}'.")
except Exception as exc:
    print(f"ERROR: {exc}", file=sys.stderr)
    raise SystemExit(1) from exc
finally:
    if client is not None and client.client is not None:
        try:
            client.disconnect()
        except Exception:
            pass
        client.client.close()
PY

unset ACT_API_KEY
trap - EXIT
