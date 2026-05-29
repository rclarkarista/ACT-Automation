#!/usr/bin/env bash
###############################################################################
# _common.sh
#
# Shared helpers sourced by generate.sh and onboard.sh.
# Not meant to be executed directly.
#
# Provides:
#   - PROJECT_DIR, CONFIG_FILE
#   - prompt()       interactive prompt with cache / default / secret / example
#   - load_config()  source .config if present
#   - save_config()  write all known vars back to .config
#   - require_tools() exit with install hints if any tool is missing
###############################################################################

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
CONFIG_FILE="${PROJECT_DIR}/.config"

###############################################################################
# prompt <var-name> <human-label> [secret | example:<text> | default-value]
#   (no third arg)   -> required input, no default; re-asks on cached blank
#   secret           -> hidden input, echoes "*" per char, shows char count
#   example:<text>   -> always re-prompts (never cached), shows "(e.g. <text>)"
#   default-value    -> shown as "[default]"; <Enter> accepts the default
###############################################################################
prompt() {
    local __var=$1 label=$2 third=${3:-}
    local existing="${!__var:-}"

    # example: mode always prompts, ignores any cached value
    if [[ "${third}" == example:* ]]; then
        local ex="${third#example:}"
        local val=""
        while [[ -z "${val}" ]]; do
            read -r -p "  ${label} (e.g. ${ex}): " val
        done
        printf -v "${__var}" '%s' "${val}"
        return
    fi

    if [[ -n "${existing}" ]]; then
        echo "  ${label}: using cached value"
        return
    fi

    local val=""
    if [[ "${third}" == "secret" ]]; then
        printf "  %s: " "${label}"
        local char
        while IFS= read -r -s -n1 char; do
            [[ -z "${char}" ]] && break
            if [[ "${char}" == $'\x7f' || "${char}" == $'\b' ]]; then
                if [[ -n "${val}" ]]; then
                    val="${val%?}"
                    printf '\b \b'
                fi
                continue
            fi
            val+="${char}"
            printf '*'
        done
        printf '  (%d chars)\n' "${#val}"
    else
        local default="${third}"
        local hint=""
        [[ -n "${default}" ]] && hint=" [${default}]"
        read -r -p "  ${label}${hint}: " val
        [[ -z "${val}" && -n "${default}" ]] && val="${default}"
    fi
    printf -v "${__var}" '%s' "${val}"
}

###############################################################################
# load_config — source .config if it exists, set CONFIG_LOADED=1
###############################################################################
load_config() {
    CONFIG_LOADED=0
    if [[ -f "${CONFIG_FILE}" ]]; then
        # shellcheck disable=SC1090
        source "${CONFIG_FILE}"
        CONFIG_LOADED=1
        echo "Loaded cached config from .config (delete it to re-prompt)."
    fi
}

###############################################################################
# save_config — write the union of fields used by any script in this repo.
# Vars not set in the current shell are written empty. Both generate.sh and
# onboard.sh share this single .config so neither clobbers the other's cache.
###############################################################################
save_config() {
    cat > "${CONFIG_FILE}" <<EOF
# Cached by ACT Automation. Delete this file to be re-prompted.
ACT_TENANT="${ACT_TENANT:-}"
ACT_USER="${ACT_USER:-}"
ACT_API_KEY="${ACT_API_KEY:-}"
CVAAS_TOKEN="${CVAAS_TOKEN:-}"
SPINE_COUNT="${SPINE_COUNT:-}"
LEAF_COUNT="${LEAF_COUNT:-}"
EOS_VERSION="${EOS_VERSION:-}"
EOF
    chmod 600 "${CONFIG_FILE}"
}

###############################################################################
# require_tools <tool1> <tool2> ... — exit 1 if any is missing
###############################################################################
require_tools() {
    local missing=()
    for tool in "$@"; do
        command -v "${tool}" >/dev/null 2>&1 || missing+=("${tool}")
    done
    if (( ${#missing[@]} > 0 )); then
        echo "ERROR: missing required tools: ${missing[*]}" >&2
        echo "       Install hints:" >&2
        for t in "${missing[@]}"; do
            case "$t" in
                sshpass) echo "         brew install hudochenkov/sshpass/sshpass" >&2 ;;
                *)       echo "         brew install ${t}" >&2 ;;
            esac
        done
        exit 1
    fi
}
