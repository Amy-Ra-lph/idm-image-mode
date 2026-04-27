#!/bin/bash
# scripts/deploy-container.sh — Deploy IdM Image Mode as a Podman container
#
# This runs the bootc image as a privileged systemd container for fast
# iteration and testing. For production-like deployment, use deploy-vm.sh.
#
# Usage:
#   ./scripts/deploy-container.sh --role=primary
#   ./scripts/deploy-container.sh --role=primary --config=my-config.env
#   ./scripts/deploy-container.sh --role=replica --hostname=idm-replica.test.example.com
#   ./scripts/deploy-container.sh --role=client --hostname=idm-client.test.example.com
#   ./scripts/deploy-container.sh --role=primary --destroy  # remove existing first

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# ── Defaults ─────────────────────────────────────────────────────────
ROLE=""
CONFIG_FILE="${REPO_DIR}/config.env"
HOSTNAME_OVERRIDE=""
REGISTRY="$DEFAULT_REGISTRY"
TAG="$DEFAULT_TAG"
DESTROY=0
WAIT=1
WAIT_TIMEOUT=600

# ── Parse Args ───────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --role=*)      ROLE="${1#*=}" ;;
        --config=*)    CONFIG_FILE="${1#*=}" ;;
        --hostname=*)  HOSTNAME_OVERRIDE="${1#*=}" ;;
        --registry=*)  REGISTRY="${1#*=}" ;;
        --tag=*)       TAG="${1#*=}" ;;
        --destroy)     DESTROY=1 ;;
        --no-wait)     WAIT=0 ;;
        --timeout=*)   WAIT_TIMEOUT="${1#*=}" ;;
        --help|-h)
            cat <<'EOF'
Usage: deploy-container.sh --role=ROLE [OPTIONS]

Options:
  --role=ROLE        Required. primary, replica, or client
  --config=FILE      Config file (default: ./config.env)
  --hostname=FQDN    Override container hostname
  --registry=REG     Image registry (default: localhost)
  --tag=TAG          Image tag (default: latest)
  --destroy          Remove existing container before deploying
  --no-wait          Don't wait for firstboot to complete
  --timeout=SECS     Wait timeout (default: 600)
EOF
            exit 0
            ;;
        *) log_err "Unknown option: $1"; exit 1 ;;
    esac
    shift
done

if [[ -z "$ROLE" ]]; then
    log_err "Missing required --role=primary|replica|client"
    exit 1
fi

# ── Validate ─────────────────────────────────────────────────────────
require_podman

if [[ ! -f "$CONFIG_FILE" ]]; then
    log_err "Config file not found: $CONFIG_FILE"
    log_err "Copy the example: cp config/config.env.example config.env"
    exit 1
fi

# Determine image type (server image for primary/replica, client for client)
IMAGE_TYPE="server"
if [[ "$ROLE" == "client" ]]; then
    IMAGE_TYPE="client"
fi

IMAGE=$(image_name "$IMAGE_TYPE" "$REGISTRY" "$TAG")
if ! image_exists "$IMAGE"; then
    log_err "Image not found: $IMAGE"
    log_err "Build it first: ./scripts/build.sh --type=$IMAGE_TYPE"
    exit 1
fi

CNAME=$(container_name "$ROLE")

# ── Destroy Existing ─────────────────────────────────────────────────
if [[ $DESTROY -eq 1 ]] && container_exists "$ROLE"; then
    log_info "Removing existing container: $CNAME"
    podman rm -f "$CNAME" 2>/dev/null || true
fi

if container_exists "$ROLE"; then
    if container_running "$ROLE"; then
        log_warn "Container already running: $CNAME"
        log_warn "Use --destroy to replace, or manage.sh to control"
        exit 0
    else
        log_info "Starting stopped container: $CNAME"
        podman start "$CNAME"
        exit 0
    fi
fi

# ── Set Hostname ─────────────────────────────────────────────────────
if [[ -n "$HOSTNAME_OVERRIDE" ]]; then
    CONTAINER_HOSTNAME="$HOSTNAME_OVERRIDE"
else
    case "$ROLE" in
        primary) CONTAINER_HOSTNAME="idm-primary.test.example.com" ;;
        replica) CONTAINER_HOSTNAME="idm-replica.test.example.com" ;;
        client)  CONTAINER_HOSTNAME="idm-client.test.example.com" ;;
    esac
fi

# ── Ensure Network ──────────────────────────────────────────────────
ensure_network

NODE_IP="${NODE_IPS[$ROLE]}"

# ── Port Mappings ────────────────────────────────────────────────────
# DESIGN: Ports remapped above 1024 for rootless Podman. Primary gets
# 8xxx/9xxx, replica gets offset. Client needs no server ports.
# Within the Podman network containers communicate on standard ports.
declare -a PORTS=()
case "$ROLE" in
    primary)
        PORTS=(
            -p 8443:443 -p 8080:80
            -p 3389:389 -p 6636:636
            -p 8088:88 -p 8088:88/udp
            -p 8464:464 -p 8464:464/udp
            -p 5354:53 -p 5354:53/udp
        )
        ;;
    replica)
        PORTS=(
            -p 9443:443 -p 9080:80
            -p 4389:389 -p 7636:636
            -p 9088:88 -p 9088:88/udp
            -p 9464:464 -p 9464:464/udp
            -p 6353:53 -p 6353:53/udp
        )
        ;;
    client)
        PORTS=()
        ;;
esac

# ── Deploy ───────────────────────────────────────────────────────────
log_section "Deploying ${ROLE}: ${CNAME}"
log_info "Image: ${IMAGE}"
log_info "Hostname: ${CONTAINER_HOSTNAME}"
log_info "Network: ${NETWORK_NAME} (${NODE_IP})"
log_info "Config: ${CONFIG_FILE}"

# DESIGN: --privileged is required because ipa-server-install needs
# capabilities for KDC, certmonger, 389 DS, and named. --systemd=true
# tells podman to run the container's init system. The named volume for
# /var ensures data persistence across container restarts.
podman run -d \
    --name "$CNAME" \
    --hostname "$CONTAINER_HOSTNAME" \
    --privileged \
    --systemd=true \
    --network "$NETWORK_NAME" \
    --ip "$NODE_IP" \
    --dns=none \
    -v "${CONFIG_FILE}:/etc/idm-image-mode/config.env:ro,z" \
    -v "${CNAME}-var:/var:Z" \
    "${PORTS[@]}" \
    "$IMAGE"

log_ok "Container started: $CNAME"

# ── Wait for Firstboot ──────────────────────────────────────────────
if [[ $WAIT -eq 1 ]]; then
    log_info "Waiting for idm-firstboot.service to complete..."
    log_info "(This takes 3-10 minutes depending on role)"

    local_check=""
    case "$ROLE" in
        primary|replica)
            local_check="ipactl status"
            ;;
        client)
            local_check="id admin@${IDM_REALM:-TEST.EXAMPLE.COM} 2>/dev/null"
            ;;
    esac

    if wait_for_container "$CNAME" "$WAIT_TIMEOUT" "$local_check"; then
        log_ok "IdM ${ROLE} is ready"
    else
        log_err "Firstboot may still be running. Check logs:"
        log_err "  podman exec $CNAME journalctl -u idm-firstboot -f"
        exit 1
    fi
fi
