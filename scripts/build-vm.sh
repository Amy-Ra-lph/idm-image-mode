#!/bin/bash
# scripts/build-vm.sh — Produce a qcow2 disk image from a bootc container image
#
# Uses bootc-image-builder to convert a container image to a VM-bootable
# qcow2 disk image for deployment on libvirt, OCP Virt, or any KVM hypervisor.
#
# Usage:
#   ./scripts/build-vm.sh [--image IMAGE] [--output DIR]
#
# Examples:
#   ./scripts/build-vm.sh
#   ./scripts/build-vm.sh --image localhost/idm-image-mode-server-idm2:latest
#   ./scripts/build-vm.sh --output /tmp/vm-images

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${REPO_DIR}/scripts/lib/common.sh"

IMAGE="localhost/idm-image-mode-server-idm2:latest"
OUTPUT_DIR="${REPO_DIR}/output"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --image)  IMAGE="$2"; shift 2 ;;
        --output) OUTPUT_DIR="$2"; shift 2 ;;
        *)        log_err "Unknown option: $1"; exit 1 ;;
    esac
done

log_section "Building VM disk image (qcow2)"
log_info "Source image: ${IMAGE}"
log_info "Output directory: ${OUTPUT_DIR}"

mkdir -p "${OUTPUT_DIR}"

if ! podman image exists "${IMAGE}"; then
    log_err "Image not found: ${IMAGE}"
    log_err "Build it first: podman build -t ${IMAGE} -f Containerfile.server-vm ."
    exit 1
fi

log_info "Running bootc-image-builder (this may take several minutes)..."
sudo podman run --rm -it --privileged --pull=newer \
    --security-opt label=type:unconfined_t \
    -v "${OUTPUT_DIR}":/output \
    -v /var/lib/containers/storage:/var/lib/containers/storage \
    quay.io/centos-bootc/bootc-image-builder:latest \
    --type qcow2 \
    --rootfs ext4 \
    "${IMAGE}"

QCOW2_PATH="${OUTPUT_DIR}/qcow2/disk.qcow2"
if [[ -f "${QCOW2_PATH}" ]]; then
    SIZE=$(du -h "${QCOW2_PATH}" | cut -f1)
    log_ok "qcow2 image built: ${QCOW2_PATH} (${SIZE})"
else
    log_err "Expected output not found: ${QCOW2_PATH}"
    exit 1
fi
