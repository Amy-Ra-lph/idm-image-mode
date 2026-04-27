#!/bin/bash
# scripts/setup-network.sh — Create Podman network for IdM Image Mode containers
#
# Creates the idm-image-mode-net network with static IP assignments.
# Run this before deploying multiple containers that need to communicate.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

require_podman
ensure_network

log_info "Network configuration:"
log_info "  Name:    ${NETWORK_NAME}"
log_info "  Subnet:  ${NETWORK_SUBNET}"
log_info "  Gateway: ${NETWORK_GATEWAY}"
log_info "  Primary: ${NODE_IPS[primary]}"
log_info "  Replica: ${NODE_IPS[replica]}"
log_info "  Client:  ${NODE_IPS[client]}"
