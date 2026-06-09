#!/usr/bin/env bash
###############################################################################
# generate.sh
#
# Interactive generator for an ACT topology YAML file.
#
# Asks for a serial prefix + spine/leaf counts, then emits a full-mesh
# topology with pinned serial_number + system_mac_address on every node so
# CVaaS keeps device identity across redeploys.
#
# After running this, upload + deploy the file in the ACT UI, then run
# ./onboard.sh to push the CVaaS onboarding config.
###############################################################################

set -euo pipefail

# shellcheck source=_common.sh
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

DEFAULT_SPINES=2
DEFAULT_LEAVES=4
DEFAULT_EOS_VERSION="4.35.4M"
DEFAULT_MEMBER_LEAVES_PER_PAIR=2

MAX_SPINES=9                       # spines use IPs 192.168.0.11-.19
MAX_LEAVES=99                      # leaves use IPs 192.168.0.21-.119
MAX_MEMBER_LEAVES_PER_PAIR=9       # member leaves dual-home to a pair, use leaf
                                   # ports SPINE_COUNT+3 onwards
MAX_TOTAL_MEMBER_LEAVES=100        # member leaves use IPs 192.168.0.131-.230

###############################################################################
# load_params_from_topology_file <yaml-file>
#   Parse a generate.sh-produced topology YAML and populate:
#     HOSTNAME_PREFIX, SPINE_COUNT, LEAF_COUNT, MLAG_PAIRS, EOS_VERSION,
#     MEMBER_LEAF_PAIRS, MEMBER_LEAVES_PER_PAIR
#   Assumes the file follows this script's naming convention
#   (<prefix>-{spine,leaf,mleaf}<N>) and link patterns. Best-effort —
#   silently leaves a var empty if it can't be parsed, and the subsequent
#   prompt will then ask normally.
###############################################################################
load_params_from_topology_file() {
    local file=$1

    # Hostname prefix from the first "  - <prefix>-spine1:" node line
    local first_spine
    first_spine=$(grep -m1 -E "^  - [A-Za-z0-9-]+-spine1:$" "$file" || true)
    if [[ -n "$first_spine" ]]; then
        HOSTNAME_PREFIX=$(sed -E 's/^  - (.+)-spine1:$/\1/' <<< "$first_spine")
    fi

    if [[ -z "${HOSTNAME_PREFIX}" ]]; then
        echo "WARNING: could not detect hostname prefix in $(basename "$file"); falling back to '${SERIAL_PREFIX}'." >&2
        HOSTNAME_PREFIX="${SERIAL_PREFIX}"
    fi

    SPINE_COUNT=$(grep -cE "^  - ${HOSTNAME_PREFIX}-spine[0-9]+:$" "$file" 2>/dev/null || echo "")
    LEAF_COUNT=$(grep -cE "^  - ${HOSTNAME_PREFIX}-leaf[0-9]+:$" "$file" 2>/dev/null || echo "")
    local mleaf_total
    mleaf_total=$(grep -cE "^  - ${HOSTNAME_PREFIX}-mleaf[0-9]+:$" "$file" 2>/dev/null || echo 0)

    EOS_VERSION=$(awk '/^veos:/{f=1} f && /^[a-zA-Z]/ && !/^veos:/{f=0} f && /^[[:space:]]+version:/{print $2; exit}' "$file")

    # MLAG: presence of any direct leaf<->leaf link
    if grep -qE "^  - connection: \[${HOSTNAME_PREFIX}-leaf[0-9]+:.*, ${HOSTNAME_PREFIX}-leaf[0-9]+:" "$file"; then
        MLAG_PAIRS="y"
    else
        MLAG_PAIRS="n"
    fi

    # Member leaves: derive pairs and per-pair count from mleaf:Eth1 -> leaf:Eth uplinks
    if (( mleaf_total > 0 )); then
        local pairs_csv
        pairs_csv=$(grep -E "^  - connection: \[${HOSTNAME_PREFIX}-mleaf[0-9]+:Ethernet1, ${HOSTNAME_PREFIX}-leaf[0-9]+:" "$file" \
            | sed -E "s/.*${HOSTNAME_PREFIX}-leaf([0-9]+):.*/\1/" \
            | awk '{ print int(($1 + 1) / 2) }' \
            | sort -un \
            | paste -sd, -)
        MEMBER_LEAF_PAIRS="$pairs_csv"
        local num_pairs
        num_pairs=$(awk -F, '{print NF}' <<< "${pairs_csv}")
        (( num_pairs > 0 )) && MEMBER_LEAVES_PER_PAIR=$((mleaf_total / num_pairs))
    fi
}

###############################################################################
# load cached config + prompt
###############################################################################
SPINE_COUNT=""
LEAF_COUNT=""
MLAG_PAIRS=""
EOS_VERSION=""
MEMBER_LEAF_PAIRS=""
MEMBER_LEAVES_PER_PAIR=""

load_config

# Discard cached topology params: they're only restored if the user picks an
# existing topology file below (which we then parse). A fresh serial prefix
# always gets fresh prompts.
SPINE_COUNT=""
LEAF_COUNT=""
MLAG_PAIRS=""
EOS_VERSION=""
MEMBER_LEAF_PAIRS=""
MEMBER_LEAVES_PER_PAIR=""

echo
echo "Topology parameters:"
# SERIAL_PREFIX is intentionally never cached — coworkers MUST set their own
# so serial namespaces don't collide on the shared ACT tenant.
prompt SERIAL_PREFIX "Serial prefix"                       "example:bsmith"

# Look for existing topology files for this serial prefix. If any exist, offer
# to modify one (parameters pre-loaded from the file) or create a new one.
EXISTING_FILE=""
HOSTNAME_PREFIX=""
existing_files=()
for f in "${PROJECT_DIR}"/topology-"${SERIAL_PREFIX}"-*.yml; do
    [[ -e "$f" ]] && existing_files+=("$f")
done

if (( ${#existing_files[@]} > 0 )); then
    echo
    echo "Found existing topology file(s) for prefix '${SERIAL_PREFIX}':"
    for i in "${!existing_files[@]}"; do
        printf "  %2d. %s\n" $((i+1)) "$(basename "${existing_files[i]}")"
    done
    new_choice=$((${#existing_files[@]}+1))
    printf "  %2d. (create a new one)\n" "${new_choice}"
    echo
    while true; do
        read -r -p "Pick [1-${new_choice}]: " choice
        if [[ "${choice}" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= new_choice )); then
            break
        fi
        echo "  Invalid choice."
    done
    if (( choice <= ${#existing_files[@]} )); then
        EXISTING_FILE="${existing_files[choice-1]}"
        echo "Loading parameters from $(basename "${EXISTING_FILE}")..."
        load_params_from_topology_file "${EXISTING_FILE}"
    fi
    echo
fi

if [[ -n "${EXISTING_FILE}" ]]; then
    echo "Current values shown in brackets — press Enter to keep, or type to change."
fi

# Hostname prefix — when modifying, the value loaded from the existing file
# is the default; when creating new, the serial prefix is. Always re-prompt
# so the user can change it either way.
prompt_with_current HOSTNAME_PREFIX "Hostname prefix" "${SERIAL_PREFIX}"

TODAY="$(date +%Y-%m-%d)"
if [[ -n "${EXISTING_FILE}" ]]; then
    OUT_FILE="${EXISTING_FILE}"
else
    OUT_FILE="${PROJECT_DIR}/topology-${SERIAL_PREFIX}-${TODAY}.yml"
fi
OUT_NAME="${OUT_FILE##*/}"

prompt_with_current SPINE_COUNT "Number of spines"                  "${DEFAULT_SPINES}"
prompt_with_current LEAF_COUNT  "Number of leaves"                  "${DEFAULT_LEAVES}"
prompt_with_current MLAG_PAIRS  "Pair leaves into MLAG pairs (y/n)" "n"

# validate counts + prefixes
if ! [[ "${SPINE_COUNT}" =~ ^[1-9][0-9]*$ ]] || (( SPINE_COUNT > MAX_SPINES )); then
    echo "ERROR: spine count must be 1-${MAX_SPINES}, got '${SPINE_COUNT}'." >&2
    exit 1
fi
if ! [[ "${LEAF_COUNT}" =~ ^[1-9][0-9]*$ ]] || (( LEAF_COUNT > MAX_LEAVES )); then
    echo "ERROR: leaf count must be 1-${MAX_LEAVES}, got '${LEAF_COUNT}'." >&2
    exit 1
fi
if ! [[ "${SERIAL_PREFIX}" =~ ^[A-Za-z0-9]+$ ]]; then
    echo "ERROR: serial prefix must be alphanumeric (no dashes/spaces), got '${SERIAL_PREFIX}'." >&2
    exit 1
fi
if ! [[ "${HOSTNAME_PREFIX}" =~ ^[A-Za-z0-9]+(-[A-Za-z0-9]+)*$ ]]; then
    echo "ERROR: hostname prefix must be alphanumeric, with optional internal dashes (no leading, trailing, or consecutive dashes), got '${HOSTNAME_PREFIX}'." >&2
    exit 1
fi

# Normalize MLAG_PAIRS to canonical "y" / "n" (case-insensitive, accepts yes/no).
case "${MLAG_PAIRS}" in
    [Yy]|[Yy][Ee][Ss])  MLAG_PAIRS="y" ;;
    [Nn]|[Nn][Oo]|"")   MLAG_PAIRS="n" ;;
    *) echo "ERROR: MLAG choice must be y or n, got '${MLAG_PAIRS}'." >&2; exit 1 ;;
esac
if [[ "${MLAG_PAIRS}" == "y" ]] && (( LEAF_COUNT % 2 != 0 )); then
    echo "ERROR: MLAG pairing requires an even number of leaves (got ${LEAF_COUNT})." >&2
    exit 1
fi

# Member leaves: L2 access switches dual-homed to a leaf pair. Only an option
# when MLAG is on, since they need a pair to attach to. The y/n prompt defaults
# to "y" if the loaded topology already had member leaves, "n" otherwise.
ADD_MEMBER_LEAVES=""
if [[ "${MLAG_PAIRS}" == "y" ]]; then
    add_member_default="n"
    [[ -n "${MEMBER_LEAF_PAIRS}" ]] && add_member_default="y"
    prompt_with_current ADD_MEMBER_LEAVES "Add member leaves under any leaf pair? (y/n)" "${add_member_default}"
    case "${ADD_MEMBER_LEAVES}" in
        [Yy]|[Yy][Ee][Ss])
            pair_max=$((LEAF_COUNT / 2))
            prompt_with_current MEMBER_LEAF_PAIRS      "Which leaf pair(s) get member leaves? (1-${pair_max}, comma-separated)" ""
            prompt_with_current MEMBER_LEAVES_PER_PAIR "Member leaves per selected pair"   "${DEFAULT_MEMBER_LEAVES_PER_PAIR}"
            ;;
        *)
            # User opted out — make sure we don't carry stale loaded values forward.
            MEMBER_LEAF_PAIRS=""
            MEMBER_LEAVES_PER_PAIR=""
            ;;
    esac
else
    MEMBER_LEAF_PAIRS=""
    MEMBER_LEAVES_PER_PAIR=""
fi

prompt_with_current EOS_VERSION "EOS version" "${DEFAULT_EOS_VERSION}"

# Validate member-leaf inputs (if the user opted in)
MEMBER_LEAF_PAIRS_ARRAY=()
if [[ -n "${MEMBER_LEAF_PAIRS}" ]]; then
    pair_max=$((LEAF_COUNT / 2))
    IFS=',' read -ra _raw_pairs <<< "${MEMBER_LEAF_PAIRS}"
    # Bash 3.2 has no associative arrays, so dedup via a delimited string.
    _seen_csv=""
    for p in "${_raw_pairs[@]}"; do
        p="${p// /}"
        [[ -z "$p" ]] && continue
        if ! [[ "$p" =~ ^[1-9][0-9]*$ ]] || (( p < 1 || p > pair_max )); then
            echo "ERROR: invalid pair number '$p' in member-leaf pairs. Must be 1-${pair_max}." >&2
            exit 1
        fi
        if [[ ",${_seen_csv}," != *",${p},"* ]]; then
            _seen_csv="${_seen_csv}${_seen_csv:+,}${p}"
            MEMBER_LEAF_PAIRS_ARRAY+=("$p")
        fi
    done
    # Re-store the cleaned list (dedup'd, whitespace-stripped) so the cache is normalized.
    MEMBER_LEAF_PAIRS=$(IFS=','; printf '%s' "${MEMBER_LEAF_PAIRS_ARRAY[*]}")

    if ! [[ "${MEMBER_LEAVES_PER_PAIR}" =~ ^[1-9][0-9]*$ ]] || (( MEMBER_LEAVES_PER_PAIR > MAX_MEMBER_LEAVES_PER_PAIR )); then
        echo "ERROR: member leaves per pair must be 1-${MAX_MEMBER_LEAVES_PER_PAIR}, got '${MEMBER_LEAVES_PER_PAIR}'." >&2
        exit 1
    fi

    total_member=$(( MEMBER_LEAVES_PER_PAIR * ${#MEMBER_LEAF_PAIRS_ARRAY[@]} ))
    if (( total_member > MAX_TOTAL_MEMBER_LEAVES )); then
        echo "ERROR: total member leaves (${total_member}) exceeds cap of ${MAX_TOTAL_MEMBER_LEAVES} (IP range 192.168.0.131-.230)." >&2
        exit 1
    fi
fi

save_config
echo

###############################################################################
# confirm before writing
###############################################################################
mlag_note=""
[[ "${MLAG_PAIRS}" == "y" ]] && mlag_note=", MLAG-paired leaves"

member_note=""
if [[ -n "${MEMBER_LEAF_PAIRS}" ]]; then
    total_member=$(( MEMBER_LEAVES_PER_PAIR * ${#MEMBER_LEAF_PAIRS_ARRAY[@]} ))
    member_note=", ${total_member} member leaf/leaves (${MEMBER_LEAVES_PER_PAIR}/pair × pairs [${MEMBER_LEAF_PAIRS}])"
fi

if [[ -n "${EXISTING_FILE}" ]]; then
    echo "Will overwrite ${OUT_NAME} (modifying existing topology)"
else
    echo "Will write ${OUT_NAME}"
fi
echo "  ${SPINE_COUNT} spine(s), ${LEAF_COUNT} leaf/leaves${member_note}, EOS ${EOS_VERSION}, full mesh${mlag_note}"
# If we're creating new but the target name happens to already exist
# (re-running on the same day without picking it from the menu), warn.
if [[ -z "${EXISTING_FILE}" && -e "${OUT_FILE}" ]]; then
    echo "  (file already exists — will be overwritten)"
fi
echo
read -r -p "Continue? [y/N] " ans
case "${ans}" in [Yy]*) ;; *) echo "Aborted."; exit 1 ;; esac

###############################################################################
# emit the YAML
###############################################################################
{
    cat <<HEADER
###############################################################################
# Generated by generate.sh on ${TODAY}.
#
# Filename convention: topology-<prefix>-<YYYY-MM-DD>.yml — ACT requires
# unique filenames across the tenant. Re-run generate.sh on another day to
# get a fresh filename.
#
# Switch identity is pinned via serial_number + system_mac_address so devices
# keep the same identity in CVaaS across redeploys.
###############################################################################

veos:
  username: cvpadmin
  password: cvp123!
  version: ${EOS_VERSION}
  # Required for CVaaS: every vEOS needs outbound internet to reach
  # apiserver.arista.io. This toolkit targets CVaaS (not on-prem CVP, which
  # ACT can stand up locally), so we always enable it.
  internet_access: true

nodes:

  ###########################################################################
  # Spines
  ###########################################################################
HEADER

    for (( i=1; i<=SPINE_COUNT; i++ )); do
        cat <<NODE

  - ${HOSTNAME_PREFIX}-spine${i}:
      node_type: veos
      ip_addr: 192.168.0.$((10 + i))/24
      serial_number: ${SERIAL_PREFIX}-spine${i}
      system_mac_address: 00:1c:73:00:01:$(printf '%02x' "${i}")
      ztp: false
NODE
    done

    cat <<'LEAFHEADER'

  ###########################################################################
  # Leaves
  ###########################################################################
LEAFHEADER

    for (( i=1; i<=LEAF_COUNT; i++ )); do
        cat <<NODE

  - ${HOSTNAME_PREFIX}-leaf${i}:
      node_type: veos
      ip_addr: 192.168.0.$((20 + i))/24
      serial_number: ${SERIAL_PREFIX}-leaf${i}
      system_mac_address: 00:1c:73:00:02:$(printf '%02x' "${i}")
      ztp: false
NODE
    done

    # Member leaves (L2 access, dual-homed into a leaf MLAG pair)
    if [[ -n "${MEMBER_LEAF_PAIRS}" ]]; then
        cat <<'MHEADER'

  ###########################################################################
  # Member leaves (L2 access, dual-homed to a leaf pair)
  ###########################################################################
MHEADER
        mleaf_idx=0
        for pair in "${MEMBER_LEAF_PAIRS_ARRAY[@]}"; do
            for (( m=1; m<=MEMBER_LEAVES_PER_PAIR; m++ )); do
                mleaf_idx=$((mleaf_idx + 1))
                cat <<NODE

  - ${HOSTNAME_PREFIX}-mleaf${mleaf_idx}:
      node_type: veos
      ip_addr: 192.168.0.$((130 + mleaf_idx))/24
      serial_number: ${SERIAL_PREFIX}-mleaf${mleaf_idx}
      system_mac_address: 00:1c:73:00:03:$(printf '%02x' "${mleaf_idx}")
      ztp: false
NODE
            done
        done
    fi

    if [[ "${MLAG_PAIRS}" == "y" ]]; then
        cat <<'LINKHEADER'

###############################################################################
# Data-plane links
#   spine <-> leaf full mesh: spine[i] Ethernet[j] <-> leaf[j] Ethernet[i]
#   MLAG peer links:          leaf<odd> <-> leaf<even> on the next two ports
#                             after the spine uplinks
#   Member-leaf uplinks:      mleaf:Eth1/2 <-> leaf<odd>/leaf<even> on the
#                             ports after the MLAG peer links
###############################################################################
links:
LINKHEADER
    else
        cat <<'LINKHEADER'

###############################################################################
# Data-plane links (spine <-> leaf full mesh)
#   spine[i] Ethernet[j] <-> leaf[j] Ethernet[i]
###############################################################################
links:
LINKHEADER
    fi

    # Spine <-> leaf full mesh
    for (( s=1; s<=SPINE_COUNT; s++ )); do
        for (( l=1; l<=LEAF_COUNT; l++ )); do
            echo "  - connection: [${HOSTNAME_PREFIX}-spine${s}:Ethernet${l}, ${HOSTNAME_PREFIX}-leaf${l}:Ethernet${s}]"
        done
        if (( s < SPINE_COUNT )); then
            echo ""
        fi
    done

    # MLAG peer links: two cables between each (leaf<odd>, leaf<even>) pair,
    # using the next two free ports after the spine uplinks.
    if [[ "${MLAG_PAIRS}" == "y" ]]; then
        mlag_port_a=$((SPINE_COUNT + 1))
        mlag_port_b=$((SPINE_COUNT + 2))
        echo ""
        echo "  # MLAG peer links"
        for (( i=1; i<=LEAF_COUNT; i+=2 )); do
            j=$((i + 1))
            echo "  - connection: [${HOSTNAME_PREFIX}-leaf${i}:Ethernet${mlag_port_a}, ${HOSTNAME_PREFIX}-leaf${j}:Ethernet${mlag_port_a}]"
            echo "  - connection: [${HOSTNAME_PREFIX}-leaf${i}:Ethernet${mlag_port_b}, ${HOSTNAME_PREFIX}-leaf${j}:Ethernet${mlag_port_b}]"
        done
    fi

    # Member-leaf uplinks: each member leaf's Eth1/Eth2 dual-home to the
    # odd/even leaves of its pair. Leaf ports start at SPINE_COUNT+3 (after
    # spine uplinks and MLAG peer links) and step up by one per member leaf.
    if [[ -n "${MEMBER_LEAF_PAIRS}" ]]; then
        echo ""
        echo "  # Member-leaf uplinks"
        mleaf_idx=0
        for pair in "${MEMBER_LEAF_PAIRS_ARRAY[@]}"; do
            odd=$((2 * pair - 1))
            even=$((2 * pair))
            for (( m=1; m<=MEMBER_LEAVES_PER_PAIR; m++ )); do
                mleaf_idx=$((mleaf_idx + 1))
                up_port=$((SPINE_COUNT + 2 + m))
                echo "  - connection: [${HOSTNAME_PREFIX}-mleaf${mleaf_idx}:Ethernet1, ${HOSTNAME_PREFIX}-leaf${odd}:Ethernet${up_port}]"
                echo "  - connection: [${HOSTNAME_PREFIX}-mleaf${mleaf_idx}:Ethernet2, ${HOSTNAME_PREFIX}-leaf${even}:Ethernet${up_port}]"
            done
        done
    fi
} > "${OUT_FILE}"

echo
echo "Wrote ${OUT_NAME}"

###############################################################################
# render a PNG of the topology if graphviz is installed
###############################################################################
PNG_FILE="${OUT_FILE%.yml}.png"
PNG_NAME="${PNG_FILE##*/}"

if command -v dot >/dev/null 2>&1; then
    diagram_title="${SERIAL_PREFIX}: ${SPINE_COUNT} spine × ${LEAF_COUNT} leaf"
    [[ "${MLAG_PAIRS}" == "y" ]] && diagram_title+=" (MLAG)"
    if [[ -n "${MEMBER_LEAF_PAIRS}" ]]; then
        total_member=$(( MEMBER_LEAVES_PER_PAIR * ${#MEMBER_LEAF_PAIRS_ARRAY[@]} ))
        diagram_title+=" + ${total_member} member"
    fi

    if {
        echo 'digraph topology {'
        echo "  label=\"${diagram_title}\";"
        echo '  labelloc="t";'
        echo '  fontname="Helvetica";'
        echo '  fontsize=16;'
        echo '  rankdir=TB;'
        echo '  splines=line;'
        echo '  nodesep=0.4;'
        echo '  ranksep=1.0;'
        echo '  node [shape=box, style="rounded,filled", fontname="Helvetica", fontsize=11];'
        echo '  edge [dir=none, penwidth=1.2];'
        echo ''

        # Spines on the top rank
        printf '  { rank=same;'
        for (( s=1; s<=SPINE_COUNT; s++ )); do
            printf ' spine%d [label="%s-spine%d\\n192.168.0.%d", fillcolor="#dbeafe"];' \
                "${s}" "${HOSTNAME_PREFIX}" "${s}" "$((10+s))"
        done
        echo ' }'

        # Leaves on the middle rank
        printf '  { rank=same;'
        for (( l=1; l<=LEAF_COUNT; l++ )); do
            printf ' leaf%d [label="%s-leaf%d\\n192.168.0.%d", fillcolor="#fef3c7"];' \
                "${l}" "${HOSTNAME_PREFIX}" "${l}" "$((20+l))"
        done
        echo ' }'

        # Member leaves on the bottom rank
        if [[ -n "${MEMBER_LEAF_PAIRS}" ]]; then
            printf '  { rank=same;'
            mleaf_idx=0
            for pair in "${MEMBER_LEAF_PAIRS_ARRAY[@]}"; do
                for (( m=1; m<=MEMBER_LEAVES_PER_PAIR; m++ )); do
                    mleaf_idx=$((mleaf_idx + 1))
                    printf ' mleaf%d [label="%s-mleaf%d\\n192.168.0.%d", fillcolor="#fce7f3"];' \
                        "${mleaf_idx}" "${HOSTNAME_PREFIX}" "${mleaf_idx}" "$((130 + mleaf_idx))"
                done
            done
            echo ' }'
        fi
        echo ''

        # Spine <-> leaf full mesh
        for (( s=1; s<=SPINE_COUNT; s++ )); do
            for (( l=1; l<=LEAF_COUNT; l++ )); do
                echo "  spine${s} -> leaf${l};"
            done
        done

        # MLAG peer links (dashed red, constraint=false so they don't pull
        # the leaves out of rank).
        if [[ "${MLAG_PAIRS}" == "y" ]]; then
            echo ''
            for (( i=1; i<=LEAF_COUNT; i+=2 )); do
                j=$((i + 1))
                echo "  leaf${i} -> leaf${j} [style=dashed, color=\"#dc2626\", penwidth=2, constraint=false];"
            done
        fi

        # Member-leaf uplinks (each mleaf -> the two leaves of its pair)
        if [[ -n "${MEMBER_LEAF_PAIRS}" ]]; then
            echo ''
            mleaf_idx=0
            for pair in "${MEMBER_LEAF_PAIRS_ARRAY[@]}"; do
                odd=$((2 * pair - 1))
                even=$((2 * pair))
                for (( m=1; m<=MEMBER_LEAVES_PER_PAIR; m++ )); do
                    mleaf_idx=$((mleaf_idx + 1))
                    echo "  leaf${odd} -> mleaf${mleaf_idx};"
                    echo "  leaf${even} -> mleaf${mleaf_idx};"
                done
            done
        fi

        echo '}'
    } | dot -Tpng -o "${PNG_FILE}" 2>/dev/null; then
        echo "Wrote ${PNG_NAME}"
    else
        echo "WARNING: graphviz failed to render ${PNG_NAME}; YAML is unaffected." >&2
        rm -f "${PNG_FILE}"
    fi
else
    echo "(install graphviz to get a topology PNG: brew install graphviz)"
fi

echo "Next:  upload + deploy in the ACT UI, then run ./onboard.sh"
