#!/bin/bash
set -euo pipefail
set -x

# bridge-refresher.sh - Mimic the OpenPERouter bridge refresher logic
#
# The full OpenPERouter controller has a bridge refresher that proactively
# resolves ARP for VIPs on the EVPN bridge. Without it, Keepalived GARPs
# on br-ex never create neighbor entries on br-pe-210 in the FRR namespace,
# so EVPN type-2 routes are never advertised and VIPs are unreachable from
# remote PEs. This script fills that gap for rawconfig deployments.

# This script also does something else: if no service on the host itself
# ever tries to reach the IP, it might never be advertised. So make sure
# that a first connection attempt happens, so that other hosts can reach it,
# e.g. master -> ingress vip (on worker).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! -f "$SCRIPT_DIR/openperouter-common.sh" ]]; then
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: openperouter-common.sh not found" >&2
    exit 1
fi

source "$SCRIPT_DIR/openperouter-common.sh"

REFRESH_INTERVAL="${REFRESH_INTERVAL:-10}"
L2_GATEWAY_IP="${L2_GATEWAY_IP:-192.168.110.1/24}"
L2_GATEWAY_IP_V6="${L2_GATEWAY_IP:-fd00:110::1/64}"
BRIDGE_NAME="br-pe-${L2_VNI:-210}"

# Strip CIDR prefix to get the subnet base for VIP discovery
GATEWAY_SUBNET="${L2_GATEWAY_IP%.*}"
GATEWAY_SUBNET_V6="${L2_GATEWAY_IP%:*}"

# VIPs to keep alive — API and Ingress
API_VIP="${API_VIP:-${GATEWAY_SUBNET}.10}"
INGRESS_VIP="${INGRESS_VIP:-${GATEWAY_SUBNET}.11}"
API_VIP_V6="${API_VIP_V6:-${GATEWAY_SUBNET_V6}:10}"
INGRESS_VIP_V6="${INGRESS_VIP_V6:-${GATEWAY_SUBNET_V6}:11}"

log "Bridge refresher started (interval=${REFRESH_INTERVAL}s, bridge=${BRIDGE_NAME})"
log "  VIPs: $API_VIP, $INGRESS_VIP, $API_VIP_V6, $INGRESS_VIP_V6"

while true; do
    for vip in "$API_VIP" "$INGRESS_VIP"; do
        inns ping -c1 -W1 -I "$BRIDGE_NAME" "$vip" >/dev/null 2>&1 || true
    done
    for vip in "$API_VIP_V6" "$INGRESS_VIP_V6"; do
        inns ping -6 -c1 -W1 -I "$BRIDGE_NAME" "$vip" >/dev/null 2>&1 || true
    done
    sleep "$REFRESH_INTERVAL"
done
