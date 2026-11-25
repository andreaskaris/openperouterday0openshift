#!/usr/bin/env bash
set -euo pipefail

# Usage: sudo ./site/vmlab/lab-up.sh /path/to/appliance.iso /path/to/agentconfig.noarch.iso
# The ISO pair must be built from srv6fullconfig with its current agent-config.yaml.

if (( EUID != 0 )) || (( $# != 2 )); then
    echo "Usage: sudo $0 <appliance.iso> <config-image.iso>" >&2
    exit 1
fi

for command in podman sudo nft dnsmasq chronyd virsh qemu-img ip sysctl envsubst; do
    command -v "$command" >/dev/null || { echo "Missing command: $command" >&2; exit 1; }
done
[[ -e /dev/kvm ]] || { echo 'KVM is required' >&2; exit 1; }

appliance=$(realpath "$1")
config_image=$(realpath "$2")
[[ -f $appliance && -f $config_image ]] || { echo 'Both ISO files must exist' >&2; exit 1; }

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export WORK_DIR=/var/lib/libvirt/images/openpe-lab
libvirt=(virsh -c qemu:///system)
names=(master-0 master-1 master-2 worker-0 worker-1)
underlay_macs=(
    00:fb:7c:be:b9:43
    00:fb:7c:be:b9:46
    00:fb:7c:be:b9:49
    00:fb:7c:be:b9:4c
    00:fb:7c:be:b9:4f
)
idle_macs=(
    00:fb:7c:be:b9:44
    00:fb:7c:be:b9:47
    00:fb:7c:be:b9:4a
    00:fb:7c:be:b9:4d
    00:fb:7c:be:b9:50
)
management_macs=(
    00:fb:7c:be:b9:45
    00:fb:7c:be:b9:48
    00:fb:7c:be:b9:4b
    00:fb:7c:be:b9:4e
    00:fb:7c:be:b9:51
)

MIN_DISK=100

MASTER_MEMORY=${MASTER_MEMORY:-16384}
MASTER_DISK=${MASTER_DISK:-${MIN_DISK}}
MASTER_VCPU=${MASTER_VCPU:-8}
WORKER_MEMORY=${WORKER_MEMORY:-8192}
WORKER_DISK=${WORKER_DISK:-${MIN_DISK}}
WORKER_VCPU=${WORKER_VCPU:-4}

for value in \
  "${MASTER_MEMORY}" \
  "${MASTER_DISK}" \
  "${MASTER_VCPU}" \
  "${WORKER_MEMORY}" \
  "${WORKER_DISK}" \
  "${WORKER_VCPU}"; do
    [[ $value =~ ^[1-9][0-9]*$ ]] || { echo 'VM sizing must be positive integers' >&2; exit 1; }
done
(( MASTER_DISK >= MIN_DISK )) || { echo "MASTER_DISK must be at least ${MIN_DISK}" >&2; exit 1; }
(( WORKER_DISK >= MIN_DISK )) || { echo "WORKER_DISK must be at least ${MIN_DISK}" >&2; exit 1; }

echo "============================================="
echo "Configuring nodes with the following characteristics:"
echo "============================================="
echo "  Masters:"
echo "    mem: ${MASTER_MEMORY}"
echo "    disk: ${MASTER_DISK}G"
echo "    vcpu: ${MASTER_VCPU}"
echo ""
echo "  Workers:"
echo "    mem: ${WORKER_MEMORY}"
echo "    disk: ${WORKER_DISK}G"
echo "    vcpu: ${WORKER_VCPU}"

"${libvirt[@]}" list --all >/dev/null || { echo 'Cannot connect to system libvirt' >&2; exit 1; }
podman info >/dev/null || { echo 'Cannot connect to Podman' >&2; exit 1; }

[[ ! -e $WORK_DIR ]] || { echo 'Lab files already exist; run lab-down.sh first' >&2; exit 1; }
for link in opelabu opelabm opelabtor red lo-und lored lo-extra; do
    if ip link show "$link" >/dev/null 2>&1; then
        echo "Network link already exists: $link" >&2
        exit 1
    fi
done
for network in openpe-underlay openpe-management; do
    if "${libvirt[@]}" net-info "$network" >/dev/null 2>&1; then
        echo "Libvirt network already exists: $network" >&2
        exit 1
    fi
done
for name in "${names[@]}"; do
    if "${libvirt[@]}" dominfo "openpe-$name" >/dev/null 2>&1; then
        echo "Libvirt domain already exists: openpe-$name" >&2
        exit 1
    fi
done
if podman container exists externalfrr; then
    echo 'Podman container already exists: externalfrr' >&2
    exit 1
fi
if nft list table inet srv6-vrf-notrack >/dev/null 2>&1; then
    echo 'nftables table already exists: srv6-vrf-notrack' >&2
    exit 1
fi

# A failed setup leaves its resources available for inspection and lab-down.sh.
mkdir -p "$WORK_DIR"
cp --reflink=auto "$appliance" "$WORK_DIR/appliance.iso"
cp --reflink=auto "$config_image" "$WORK_DIR/config-image.iso"
cp -a "$script_dir/externalfrr" "$WORK_DIR/externalfrr"
chmod 644 "$WORK_DIR/appliance.iso" "$WORK_DIR/config-image.iso"
if command -v restorecon >/dev/null; then restorecon -R "$WORK_DIR"; fi

# The upstream script changes host sysctls; save their original values for lab-down.sh.
for key in net.ipv4.ip_forward net.ipv6.conf.all.forwarding net.ipv6.seg6_flowlabel \
    net.ipv6.conf.all.seg6_enabled net.ipv6.conf.default.seg6_enabled \
    net.ipv6.conf.lo.seg6_enabled net.ipv4.conf.all.rp_filter \
    net.ipv4.conf.default.rp_filter net.vrf.strict_mode; do
    if value=$(sysctl -n "$key" 2>/dev/null); then
        printf '%s=%s\n' "$key" "$value" >> "$WORK_DIR/sysctls"
    fi
done

envsubst < "$script_dir/xml/underlay-net.xml" > "$WORK_DIR/underlay.xml"
envsubst < "$script_dir/xml/management-net.xml" > "$WORK_DIR/management.xml"
for network in underlay management; do
    "${libvirt[@]}" net-define "$WORK_DIR/$network.xml"
    "${libvirt[@]}" net-start "openpe-$network"
done

# The unmodified upstream script runs FRR, DNS, and NTP on the host network.
ISIS_IFACE=opelabu "$WORK_DIR/externalfrr/run_frr.sh"

# PCI buses 1/2/3 give the guests enp1s0/enp2s0/enp3s0.
# enp2s0 MACs match srv6fullconfig/configimage/agent-config.yaml.
for i in "${!names[@]}"; do
    name=${names[$i]}

    export VM_NAME="openpe-$name"
    export NODE_NAME="$name"
    export IDLE_MAC="${idle_macs[$i]}"
    export UNDERLAY_MAC="${underlay_macs[$i]}"
    export MANAGEMENT_MAC="${management_macs[$i]}"

    export VM_MEMORY_MIB="${MASTER_MEMORY}"
    export VM_VCPUS="${MASTER_VCPU}"
    export VM_DISK="${MASTER_DISK}"
    if [[ "${name}" =~ "worker-" ]]; then
      export VM_MEMORY_MIB="${WORKER_MEMORY}"
      export VM_VCPUS="${WORKER_VCPU}"
      export VM_DISK="${WORKER_DISK}"
    fi

    export VM_DISK_IMAGE="$WORK_DIR/$name.qcow2"
    qemu-img create -f qcow2 "${VM_DISK_IMAGE}" "${VM_DISK}G"
    
    envsubst < "$script_dir/xml/pf-emulation-net.xml" > "$WORK_DIR/$name-pf.xml"
    "${libvirt[@]}" net-define "$WORK_DIR/$name-pf.xml"
    "${libvirt[@]}" net-start "pf-$name"
    
    envsubst < "$script_dir/xml/domain.xml" > "$WORK_DIR/$name.xml"
    "${libvirt[@]}" define "$WORK_DIR/$name.xml"
    "${libvirt[@]}" start "openpe-$name"

    ip link set "pf-$name" type bridge vlan_filtering 1
done

echo 'OpenPERouter lab started. Use virsh console, podman logs externalfrr, and the generated kubeconfig for manual checks.'
