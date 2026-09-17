#!/bin/bash
set -euo pipefail

# generate-config.sh - Generate OpenPERouter configuration (ISIS + SRv6)
#
# This script:
# 1. Determines node role from hostname (master vs worker)
# 2. Copies the appropriate OpenPERouter YAML configs
#
# Usage: Executed by systemd service generate-config.service
#
# Exit codes:
#   0   - Success
#   1   - General error

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common utilities
if [[ ! -f "$SCRIPT_DIR/openperouter-common.sh" ]]; then
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: openperouter-common.sh not found" >&2
    exit 1
fi

source "$SCRIPT_DIR/openperouter-common.sh"

TEMPLATE_DIR="/etc/openperouter/templates"
CONFIG_OUTPUT_DIR="/var/lib/openperouter/configs"

# Start main execution
log "Starting configuration generation (ISIS + SRv6 mode)"

#
# STEP 1: Determine role from hostname
#
log_step "Determining node role"

HOSTNAME="$(hostname)"
NODE_TYPE="worker"
if [[ "$HOSTNAME" == master* ]] || [[ "$HOSTNAME" == control-plane* ]]; then
    NODE_TYPE="master"
fi
log "This node is a ${NODE_TYPE} (hostname=${HOSTNAME})"

#
# STEP 2: Copy yaml files
#
log_step "Copying configuration files"

mkdir -p "${CONFIG_OUTPUT_DIR}"
log "Copying files $(ls ${TEMPLATE_DIR}/openpe_${NODE_TYPE}*.yaml) to ${CONFIG_OUTPUT_DIR}"
cp "${TEMPLATE_DIR}"/openpe_"${NODE_TYPE}"*.yaml "${CONFIG_OUTPUT_DIR}"

exit_success "Configuration generation completed successfully"
