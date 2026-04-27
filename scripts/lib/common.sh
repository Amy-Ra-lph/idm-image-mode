#!/bin/bash
# scripts/lib/common.sh — Shared functions for idm-image-mode scripts
#
# Source at the top of every script:
#   SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
#   source "${SCRIPT_DIR}/lib/common.sh"

set -euo pipefail

# ── Path Resolution ──────────────────────────────────────────────────
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ── Image Defaults ───────────────────────────────────────────────────
DEFAULT_REGISTRY="localhost"
DEFAULT_TAG="latest"
DEFAULT_BASE_IMAGE="quay.io/fedora/fedora-bootc:44"
IMAGE_PREFIX="idm-image-mode"

# ── Container Defaults ───────────────────────────────────────────────
CONTAINER_PREFIX="idm"
NETWORK_NAME="idm-image-mode-net"
NETWORK_SUBNET="10.99.0.0/24"
NETWORK_GATEWAY="10.99.0.1"

# Static IPs for multi-container topology
declare -A NODE_IPS=(
    [primary]="10.99.0.10"
    [replica]="10.99.0.11"
    [client]="10.99.0.12"
)

# ── Logging ──────────────────────────────────────────────────────────
_RED='\033[0;31m'
_GREEN='\033[0;32m'
_YELLOW='\033[0;33m'
_BLUE='\033[0;34m'
_BOLD='\033[1m'
_NC='\033[0m'

log_info()    { echo -e "${_BLUE}[INFO]${_NC} $*"; }
log_ok()      { echo -e "${_GREEN}[ OK ]${_NC} $*"; }
log_err()     { echo -e "${_RED}[ERR ]${_NC} $*" >&2; }
log_warn()    { echo -e "${_YELLOW}[WARN]${_NC} $*"; }

log_step() {
    local num=$1 total=$2
    shift 2
    echo ""
    echo -e "${_BOLD}[${num}/${total}]${_NC} $*"
}

log_section() {
    echo ""
    echo -e "${_BOLD}════════════════════════════════════════════════════════════${_NC}"
    echo -e "${_BOLD}  $*${_NC}"
    echo -e "${_BOLD}════════════════════════════════════════════════════════════${_NC}"
}

# ── Config Loading ───────────────────────────────────────────────────
load_config() {
    local config_file="${1:-${REPO_DIR}/config.env}"

    if [[ ! -f "$config_file" ]]; then
        log_err "Config file not found: $config_file"
        log_err "Copy the example and edit it:"
        log_err "  cp config/config.env.example config.env"
        exit 1
    fi

    # shellcheck disable=SC1090
    source "$config_file"

    local required=(IDM_ROLE IDM_DOMAIN IDM_REALM IDM_ADMIN_PASSWORD IDM_DS_PASSWORD)
    for var in "${required[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            log_err "Required config variable not set: $var"
            exit 1
        fi
    done

    if [[ "$IDM_ROLE" != "primary" && "$IDM_ROLE" != "replica" && "$IDM_ROLE" != "client" ]]; then
        log_err "IDM_ROLE must be primary, replica, or client (got: $IDM_ROLE)"
        exit 1
    fi

    if [[ "$IDM_ROLE" != "primary" ]]; then
        if [[ -z "${IDM_SERVER_FQDN:-}" || -z "${IDM_SERVER_IP:-}" ]]; then
            log_err "IDM_SERVER_FQDN and IDM_SERVER_IP required for role=$IDM_ROLE"
            exit 1
        fi
    fi

    log_info "Config loaded: role=${IDM_ROLE} domain=${IDM_DOMAIN} realm=${IDM_REALM}"
}

# ── Image Helpers ────────────────────────────────────────────────────
image_name() {
    local type=$1
    local registry=${2:-$DEFAULT_REGISTRY}
    local tag=${3:-$DEFAULT_TAG}
    echo "${registry}/${IMAGE_PREFIX}-${type}:${tag}"
}

image_exists() {
    podman image exists "$1" 2>/dev/null
}

# ── Container Helpers ────────────────────────────────────────────────
container_name() {
    local role=$1
    echo "${CONTAINER_PREFIX}-${role}"
}

container_running() {
    podman ps --format '{{.Names}}' 2>/dev/null | grep -q "^$(container_name "$1")$"
}

container_exists() {
    podman container exists "$(container_name "$1")" 2>/dev/null
}

wait_for_container() {
    local name=$1
    local max_wait=${2:-300}
    local check_cmd=${3:-"echo ready"}
    local interval=10
    local elapsed=0

    log_info "Waiting for ${name} to be ready (max ${max_wait}s)..."
    while (( elapsed < max_wait )); do
        if podman exec "$name" bash -c "$check_cmd" &>/dev/null; then
            log_ok "${name} is ready (${elapsed}s)"
            return 0
        fi
        sleep "$interval"
        elapsed=$(( elapsed + interval ))
    done

    log_err "Timeout waiting for ${name} after ${max_wait}s"
    return 1
}

# ── Network Helpers ──────────────────────────────────────────────────
network_exists() {
    podman network exists "$NETWORK_NAME" 2>/dev/null
}

ensure_network() {
    if network_exists; then
        log_ok "Network exists: $NETWORK_NAME"
        return
    fi
    podman network create "$NETWORK_NAME" \
        --subnet "$NETWORK_SUBNET" \
        --gateway "$NETWORK_GATEWAY" \
        2>/dev/null
    log_ok "Created network: $NETWORK_NAME ($NETWORK_SUBNET)"
}

# ── Prerequisite Checks ─────────────────────────────────────────────
require_command() {
    local cmd=$1
    if ! command -v "$cmd" &>/dev/null; then
        log_err "Required command not found: $cmd"
        exit 1
    fi
}

require_podman() {
    require_command podman
    local version
    version=$(podman --version | awk '{print $3}')
    log_info "Podman version: $version"
}
