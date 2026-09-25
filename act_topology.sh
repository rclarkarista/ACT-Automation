#!/usr/bin/env bash
###############################################################################
# act_topology.sh
#
# Upload a topology produced by generate.sh to the authenticated user's ACT
# account using the actrac Python client. The ACT API key is collected with a
# hidden prompt and stored in .env as ACT_API_KEY.
###############################################################################

set -euo pipefail

# shellcheck source=_common.sh
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

DEFAULT_ACT_TENANT="CE"
ENV_FILE="${PROJECT_DIR}/.env"

usage() {
    cat <<EOF
Usage: $(basename "$0") [topology-file]

Upload a topology YAML file produced by generate.sh to ACT. If no file is
provided, the script prompts you to select one from this repository.
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

require_tools python3
if ! python3 -c 'from actrac.client import ACTClient; import yaml' >/dev/null 2>&1; then
    echo "ERROR: Python packages actrac and PyYAML are required." >&2
    echo "       Open this repository in its dev container or run:" >&2
    echo "       python3 -m pip install actrac PyYAML" >&2
    exit 1
fi

echo
echo "Validating ${TOPOLOGY_FILENAME}..."
python3 - "${TOPOLOGY_FILE}" <<'PY'
from pathlib import Path
import sys

import yaml


def validation_error(message: str) -> None:
    raise ValueError(f"invalid ACT topology: {message}")


topology_file = Path(sys.argv[1])
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
except (OSError, yaml.YAMLError, ValueError) as exc:
    print(f"ERROR: {exc}", file=sys.stderr)
    raise SystemExit(1) from exc

print(f"Topology validation passed: {len(node_names)} nodes, {len(links)} links.")
PY

TOPOLOGY_NAME=""
ACT_TENANT=""
ACT_API_KEY=""

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
export ACT_API_KEY

echo
echo "Uploading ${TOPOLOGY_FILENAME} as '${TOPOLOGY_NAME}' to ${ACT_TENANT}.act.arista.com..."

python3 - "${ENV_FILE}" "${TOPOLOGY_FILE}" "${TOPOLOGY_NAME}" "${ACT_TENANT}" <<'PY'
import json
import os
from pathlib import Path
import re
import sys
import tempfile

from actrac.client import ACTClient


def save_api_key(env_path: Path, api_key: str) -> None:
    """Atomically add or replace ACT_API_KEY while preserving other entries."""
    existing = env_path.read_text(encoding="utf-8").splitlines() if env_path.exists() else []
    replacement = f"ACT_API_KEY={json.dumps(api_key)}"
    updated = []
    replaced = False

    for line in existing:
        if re.match(r"^\s*(?:export\s+)?ACT_API_KEY=", line):
            if not replaced:
                updated.append(replacement)
                replaced = True
            continue
        updated.append(line)

    if not replaced:
        updated.append(replacement)

    env_path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_name = tempfile.mkstemp(prefix=".env.", dir=env_path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.write("\n".join(updated) + "\n")
        os.chmod(temp_name, 0o600)
        os.replace(temp_name, env_path)
        os.chmod(env_path, 0o600)
    except Exception:
        try:
            os.unlink(temp_name)
        except FileNotFoundError:
            pass
        raise


env_file = Path(sys.argv[1])
topology_file = Path(sys.argv[2])
topology_name = sys.argv[3]
tenant = sys.argv[4]
api_key = os.environ["ACT_API_KEY"]

client = None
try:
    save_api_key(env_file, api_key)
    print(f"Saved ACT_API_KEY to {env_file} with permissions 0600.")

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
    )
    if not operation or operation.get("schema_type") != "operation_resource":
        raise RuntimeError(
            f"ACT did not return a create operation: {json.dumps(operation, default=str)}"
        )

    operation_id = operation.get("id")
    print(f"ACT accepted create operation {operation_id or '(ID unavailable)'}. Waiting for completion...")
    operation_result = client.api.poll_operation(
        operation,
        poll_iterations=30,
        poll_sleep=10,
    )
    if not operation_result:
        raise RuntimeError("ACT returned no result while polling the create operation")

    operation_status = str(operation_result.get("status", "unknown"))
    if operation_status.lower() != "completed":
        details = operation_result.get("result") or operation_result.get("message")
        raise RuntimeError(
            f"ACT topology validation/creation ended with status "
            f"'{operation_status}': {json.dumps(details, default=str)}"
        )

    result = operation_result.get("result")
    if not result:
        raise RuntimeError("ACT completed the create operation without a topology result")

    created_id = result.get("id") if isinstance(result, dict) else None
    created_name = result.get("name", topology_name) if isinstance(result, dict) else topology_name
    print(f"Created ACT topology '{created_name}'.")
    if created_id:
        print(f"Topology ID: {created_id}")
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
