#!/bin/bash
# scripts/build.sh — Build IdM Image Mode bootc images
#
# Usage:
#   ./scripts/build.sh                    # build server image
#   ./scripts/build.sh --type=client      # build client image
#   ./scripts/build.sh --type=all         # build both
#   ./scripts/build.sh --tag=v1.0         # custom tag

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# ── Defaults ─────────────────────────────────────────────────────────
TYPE="server"
REGISTRY="$DEFAULT_REGISTRY"
TAG="$DEFAULT_TAG"

# ── Parse Args ───────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --type=*)    TYPE="${1#*=}" ;;
        --registry=*) REGISTRY="${1#*=}" ;;
        --tag=*)     TAG="${1#*=}" ;;
        --help|-h)
            echo "Usage: $0 [--type=server|client|all] [--registry=REGISTRY] [--tag=TAG]"
            exit 0
            ;;
        *) log_err "Unknown option: $1"; exit 1 ;;
    esac
    shift
done

# ── Build ────────────────────────────────────────────────────────────
require_podman

build_image() {
    local type=$1
    local containerfile="${REPO_DIR}/Containerfile.${type}"
    local name
    name=$(image_name "$type" "$REGISTRY" "$TAG")

    if [[ ! -f "$containerfile" ]]; then
        log_err "Containerfile not found: $containerfile"
        return 1
    fi

    log_section "Building ${type} image: ${name}"

    podman build \
        -t "$name" \
        -f "$containerfile" \
        "$REPO_DIR"

    local size
    size=$(podman image inspect "$name" --format '{{.Size}}' 2>/dev/null)
    local size_mb=$(( size / 1024 / 1024 ))

    log_ok "Built: ${name} (${size_mb} MB)"
}

case "$TYPE" in
    server)  build_image server ;;
    client)  build_image client ;;
    all)     build_image server; build_image client ;;
    *)       log_err "Unknown type: $TYPE (expected: server, client, all)"; exit 1 ;;
esac

log_ok "Build complete"
