#!/bin/bash
set -euo pipefail

# generate-config.sh - Generate OpenPERouter FRR configuration (ISIS + SRv6)
#
# This script:
# 1. Loads variables from setup-underlay.sh
# 2. Determines node role (EVPN route reflector vs client)
# 3. Selects the appropriate template (RR or client)
# 4. Renders configuration via envsubst
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

# Load environment configuration file
ENV_FILE="${ENV_FILE:-/etc/openperouter/vpn-setup.env}"
if [[ -f "$ENV_FILE" ]]; then
    source "$ENV_FILE"
fi

# Paths
VARS_FILE="${VARS_FILE:-/var/lib/openperouter/vpn-setup.vars}"
TEMPLATE_DIR="${TEMPLATE_DIR:-/etc/openperouter/templates}"
CONFIG_OUTPUT_DIR="${CONFIG_OUTPUT_DIR:-/var/lib/openperouter/configs}"
RENDERED_TEMPLATE_OUTPUT="${RENDERED_TEMPLATE_OUTPUT:-openpe_raw.yaml}"

# Start main execution
log "Starting configuration generation (ISIS + SRv6 mode)"

#
# STEP 1: Load variables from setup-underlay.sh
#
log_step "Loading variables from underlay setup"

if [[ ! -f "$VARS_FILE" ]]; then
    error "Variables file not found: $VARS_FILE"
    error "setup-underlay.service must run first"
    exit_error "Missing variables file"
fi

source "$VARS_FILE"

log "Loaded variables from $VARS_FILE"

#
# STEP 2: Determine role from hostname
#
log_step "Determining node role"

HOSTNAME="$(hostname)"
NODE_TYPE="worker"
if [[ "$HOSTNAME" == master* ]] || [[ "$HOSTNAME" == control-plane* ]]; then
    NODE_TYPE="master"
fi
log "This node is a ${NODE_TYPE} (hostname=${HOSTNAME})"

#
# STEP 3: Copy yaml files
#
log "Copying files $(ls ${TEMPLATE_DIR}/openpe_${NODE_TYPE}*.yaml) to ${CONFIG_OUTPUT_DIR}"
cp "${TEMPLATE_DIR}"/openpe_"${NODE_TYPE}"*.yaml "${CONFIG_OUTPUT_DIR}"

#
# STEP 4: Verify template exists
#
log_step "Checking configuration template"

CONFIG_TEMPLATE="${TEMPLATE_DIR}/openpe_${NODE_TYPE}_raw.yaml.template"
if [[ ! -f "$CONFIG_TEMPLATE" ]]; then
    error "Configuration template not found: $CONFIG_TEMPLATE"
    exit_error "Missing configuration template"
fi

log "Using template: $CONFIG_TEMPLATE"

#
# STEP 5: Render configuration from template using envsubst
#
log_step "Rendering configuration from template"
CONFIG_OUTPUT="${CONFIG_OUTPUT_DIR}/${RENDERED_TEMPLATE_OUTPUT}"

mkdir -p "${CONFIG_OUTPUT_DIR}"

# Export variables for envsubst (rawfrrconfigs only)
# export LOOPBACK_V6

envsubst < "$CONFIG_TEMPLATE" > "$CONFIG_OUTPUT" || {
    error "Failed to render configuration template"
    exit_error "Template rendering failed"
}

log "Configuration written to: $CONFIG_OUTPUT"

#
# STEP 6: Preview generated config
#
#

# Show preview
log "Configuration preview of rendered files (first 30 lines):"
head -30 "$CONFIG_OUTPUT" | while IFS= read -r line; do log "  $line"; done
log "  ..."

log "Configuration preview of rendered files (last 30 lines):"
log "  ..."
tail -30 "$CONFIG_OUTPUT" | while IFS= read -r line; do log "  $line"; done

exit_success "Configuration generation completed successfully"
