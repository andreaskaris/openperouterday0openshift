# OpenPERouter — SRv6 Full Config Deployment

An OpenPERouter deployment on an OpenShift cluster using upstream
OpenPERouter CRDs for L3VPN and EVPN configuration. The controller
derives per-node addressing (router ID, loopback, SRv6 locator) from
configured CIDR ranges. Systemd services at boot derive the node index
and copy the appropriate FRR configuration for the node role.

## Architecture

```
              ┌─────────┐
              │   TOR   │
              └────┬────┘
                   │  ISIS L1 (IPv6-only) + SRv6 (L3VPN)
        ┌──────────┼──────────┐
        │          │          │
   ┌────┴───┐ ┌───┴────┐ ┌───┴────┐
   │master-0│ │master-1│ │master-2│
   │  (RR)  │ │  (RR)  │ │  (RR)  │
   └────────┘ └────────┘ └────────┘
        ◄── EVPN / VXLAN (L2VPN) ──►
          reflected by all 3 masters

   ┌────────┐ ┌────────┐
   │worker-0│ │worker-1│  ...
   │(client)│ │(client)│
   └────────┘ └────────┘
```

- **North-south** (nodes ↔ TOR): L3VPN over SRv6 (IPv6-only ISIS underlay)
- **East-west** (node ↔ node): EVPN with VXLAN, all 3 masters as route reflectors
- The TOR does **not** participate in EVPN

See [TOPOLOGY.md](TOPOLOGY.md) for full addressing and peering details.

## Host Configuration

The systemd services in [`extras/common/`](extras/common/) run at boot
to configure each node:

| Script | What it does |
|--------|-------------|
| `generate-config.sh` | Determines node role (master/worker) from hostname, copies the matching YAML configs |

## FRR Configuration

FRR config files live in `extras/config/`:

- **`openpe_master.yaml`** - OpenPERouter configuration for the masters
- **`openpe_worker.yaml`** - OpenPERouter configuration for the workers

`generate-config.sh` selects master or worker configs based on the hostname
and copies the matching YAML files.

## Building

- **Appliance ISO**: [`appliance/generate_appliance.sh`](appliance/generate_appliance.sh) `<pull_secret_file>`
- **Config-image ISO**: [`configimage/generate_config_image.sh`](configimage/generate_config_image.sh) `<pull_secret_file>`

## Linux Bridge br0

br0 is the Linux bridge connected to OpenPERouter, acting as the node exit point. br0 is the node's default gateway and must have a dummy port connected.

```yaml
- name: br0
  type: linux-bridge
  state: up
  ipv4:
    enabled: true
    address:
    - ip: 192.168.110.2
      prefix-length: 24
    dhcp: false
  bridge:
    port:
    - name: dummy0
```

```yaml
routes:
  config:
  - destination: 0.0.0.0/0
    next-hop-address: 192.168.110.1
    next-hop-interface: br0
    table-id: 254
```

> **NOTE:** br0's IP must be the first IP on the list in order to have DNS work due to an nmstate behavior. The default gateway is the same for each node. br0's IP is used to determine if a node is master or worker (see [Determining the node type](#determining-the-node-type)).

### Dummy Node Index Interface

Due to nmstate behavior, it is very important to have br0 as the first IP in the list. By doing this, DNS will be associated with its gateway.

- br0 has a dummy bridge slave, interface `dummy0`
- br0 must account for the overhead of VXLAN over IPv6, i.e. 70 bytes. Configure the MTU accordingly.
- The node role (master vs. worker) is determined from the hostname. See [Determining the node type](#determining-the-node-type) for more information.
- A dummy interface is present with e.g. name `nodeidx` and e.g. subnet `192.0.2.0/24`. Both the interface name and subnet can be chosen arbitrarily. The OpenPERouter is later configured to inspect the single IPv4 subnet on interface `nodeidx` and to choose the node's ID based on the n-th address that it has in that subnet, therefore the IP address inside the subnet must be unique per node.
- The actual interface for connectivity to the rest of the network is also set up in `agent-config.yaml`. Here, it is `eno12399np0`. This interface will later be moved, alongside all its configured IP addresses, into the `perouter` namespace and will be used to establish underlay connectivity.

```yaml
- name: br0
  type: linux-bridge
  state: up
  mtu: 1430
  ipv4:
    enabled: true
    auto-dns: false
    address:
    - ip: 192.168.110.2
      prefix-length: 24
    dhcp: false
  ipv6:
    enabled: true
    auto-dns: false
    address:
    - ip: fd00:110::2
      prefix-length: 64
    dhcp: false
  bridge:
    port:
    - name: dummy0
- name: dummy0
  type: dummy
  state: up
  ipv4:
    enabled: false
  ipv6:
    enabled: false
```

```yaml
- name: nodeidx
  type: dummy
  state: up
  ipv4:
    enabled: true
    auto-dns: false
    address:
    - ip: 192.0.2.2
      prefix-length: 24
    dhcp: false
  ipv6:
    enabled: false
```

```yaml
- name: eno12399np0
  type: ethernet
  state: up
  ipv4:
    enabled: true
    address:
    - ip: 192.168.135.21
      prefix-length: 25
    dhcp: false
  ipv6:
    enabled: true
    address:
    - ip: 2600:52:7:135::21
      prefix-length: 64
    dhcp: false
```

```yaml
routes:
  config:
  - destination: 0.0.0.0/0
    next-hop-address: 192.168.110.1
    next-hop-interface: br0
    table-id: 254
  - destination: ::/0
    next-hop-address: fd00:110::1
    next-hop-interface: br0
    table-id: 254
```

This configuration is applied via the `agent-config.yaml`, and the br0 address of each node as well as the `nodeidx` interface must be assigned unique IPs in their respective subnets.

## Selecting the Node Index Interface and Choosing the Log Level

The node index is chosen from the node index interface. If the node has the n-th IP address inside the subnet, its node index will be n. E.g., if the subnet is `192.0.2.0/24`, and the node's IP is `192.0.2.5`, then the node's index is 5. Each node must have a unique IP address on the node index. The node index interface can be chosen by modifying file `extras/common/openperouter-node-index.sh`. You can also modify the OpenPERouter log level in the same file:

```bash
#!/usr/bin/env bash
# Set nodeidx as the nodeIndex.interfaceName in /var/lib/openperouter/node-config.yaml.

set -euo pipefail

NODE_IDX_INTF="${1:-nodeidx}"
CONFIG_PATH="/var/lib/openperouter/node-config.yaml"

echo "Deriving nodeIndex from ${NODE_IDX_INTF}"

mkdir -p "$(dirname "${CONFIG_PATH}")"
cat > "${CONFIG_PATH}" <<EOF
nodeIndex:
  interfaceName: ${NODE_IDX_INTF}
logLevel: debug
EOF
```

In this specific case, we have a systemd service that runs script `openperouter-node-index.sh` that writes file `/var/lib/openperouter/node-config.yaml`. What's important here is that this last file exists with the `nodeIndex` and `logLevel` configuration stanzas.

## Configuring the MTU

The MTU must be configured in various locations. The following examples are for a 1500 byte MTU on the wire.

**1. agent-config.yaml** — set the MTU to `<max MTU> - 70` bytes overhead. This setting will set br0 MTU for the initial boot stage that installs OpenShift on the nodes' disks:

```yaml
- name: br0
  type: linux-bridge
  state: up
  mtu: 1430
```

**2. MachineConfigurations** — after the nodes' OS is installed, they reboot, contact the bootstrap API server and reconfigure their networking. Therefore, we must add MachineConfigurations to configure the correct MTU (`<max MTU> - 70` bytes) from this stage on and beyond. File `configimage/generate_machineconfigs.sh` generates MachineConfigurations via butane from `configimage/if-mtu.bu` (masters) and `configimage/if-mtu-worker.bu` (workers). The MachineConfigurations will create file `/etc/NetworkManager/conf.d/99-br0-mtu.conf` on each node with the following content. This content can be found and modified in the source file `extras/config/br0-mtu.conf`:

```ini
[connection-br0-mtu]
match-device=interface-name:br0
ethernet.mtu=1430
```

**3. Cluster network MTU** — OVN-Kubernetes by default accounts for 100 bytes overhead for Geneve. However, because we now have double encapsulation (Geneve overlay inside IPv6/VXLAN overlay), we must account for 170 bytes of overhead and configure the `network.operator` with the new MTU setting. Modify file `configimage/generate_machineconfigs.sh`:

```yaml
# For a network with IPv4 VXLAN tunnel endpoints and SRv6 + encap.red, the VXLAN
# overhead is 50 bytes which is larger than the 40 bytes for SRv6 encap.red.
# However, for a network with IPv6 VXLAN tunnel endpoints, the overhead increases
# to 70 bytes for the VXLAN header. Adjust the cluster MTU from the default 1400
# for pods (1500 - 100 accounting for Geneve) to 1330 to account for IPv6 VXLAN
# tunnel overhead.
apiVersion: operator.openshift.io/v1
kind: Network
metadata:
  name: cluster
spec:
  defaultNetwork:
    ovnKubernetesConfig:
      mtu: 1330
```

## Determining the Node Type

The node type is used to establish if we need to push master or worker configuration to the nodes. The node type is determined from the hostname: if it starts with `master` or `control-plane`, the node is assigned the master role. Otherwise, it is a worker node. See file `extras/common/generate-config.sh` for more details.

## Configuring the OpenPERouter

In order to configure the OpenPERouter, you need to modify files `extras/config/openpe_master.yaml` and `extras/config/openpe_worker.yaml`.

This configuration is static, meaning that these two files are not templates but exact configuration files which will be copied as they are to the nodes (depending on the node type).

### Master Configuration (`extras/config/openpe_master.yaml`)

```yaml
underlays:
  - asn: 65500
    tunnelEndpoint:
      cidrs:
        - fd00::/64
    interfaces:
    - type: NetworkDevice
      networkDevice:
        interfaceName: eno12399np0
    routerIDCIDR: 10.0.0.0/24
    isis:
      baseNet: "49.0001.0000.0000.0000.00"
      level: 1
    srv6:
      encapBehavior: "H.Encaps.Red"
      locator:
        basePrefix: "fd00:2::/48"
        format: "usid-f3216"
    nodeSelector:
      matchExpressions:
        - key: node-role.kubernetes.io/control-plane
          operator: Exists
    routeReflector:
      clusterID: 10.255.255.255
    neighbors:
      - type: Internal
        address: fc00:0:20::1
        addressFamilies:
          - type: ipv4vpn
          - type: ipv6vpn
      - type: Internal
        listenRange: 2600:52:7::/48
        addressFamilies:
          - type: evpn
            properties:
              - type: routeReflectorClient
      - type: Internal
        address: 2600:52:7:135::21
        addressFamilies:
          - type: evpn
      - type: Internal
        address: 2600:52:7:136::22
        addressFamilies:
          - type: evpn
      - type: Internal
        address: 2600:52:7:137::23
        addressFamilies:
          - type: evpn

l2vnis:
  - vni: 210
    routingDomain:
      type: L3VPN
      l3vpn:
        name: red
    vxlanport: 4789
    gatewayIPs:
      - "192.168.110.1/24"
      - "fd00:110::1/64"
    hostMaster:
      type: LinuxBridge
      linuxBridge:
        lifecycle: External
        name: br0
l3vpns:
  - name: red
    vrf: red
    rdAssignedNumber: 2
    exportRTs:
    - "65500:2"
    importRTs:
    - "65500:2"
```

### Worker Configuration (`extras/config/openpe_worker.yaml`)

```yaml
underlays:
  - asn: 65500
    tunnelEndpoint:
      cidrs:
        - fd00::/64
    interfaces:
    - type: NetworkDevice
      networkDevice:
        interfaceName: eno12399np0
    routerIDCIDR: 10.0.0.0/24
    isis:
      baseNet: "49.0001.0000.0000.0000.00"
      level: 1
    srv6:
      encapBehavior: "H.Encaps.Red"
      locator:
        basePrefix: "fd00:2::/48"
        format: "usid-f3216"
    nodeSelector:
      matchExpressions:
        - key: node-role.kubernetes.io/control-plane
          operator: DoesNotExist
    neighbors:
      - type: Internal
        address: fc00:0:20::1
        addressFamilies:
          - type: ipv4vpn
          - type: ipv6vpn
      - type: Internal
        address: 2600:52:7:135::21
        addressFamilies:
          - type: evpn
      - type: Internal
        address: 2600:52:7:136::22
        addressFamilies:
          - type: evpn
      - type: Internal
        address: 2600:52:7:137::23
        addressFamilies:
          - type: evpn
l2vnis:
  - vni: 210
    routingDomain:
      type: L3VPN
      l3vpn:
        name: red
    vxlanport: 4789
    gatewayIPs:
      - "192.168.110.1/24"
      - "fd00:110::1/64"
    hostMaster:
      type: LinuxBridge
      linuxBridge:
        lifecycle: External
        name: br0
l3vpns:
  - name: red
    vrf: red
    rdAssignedNumber: 2
    exportRTs:
    - "65500:2"
    importRTs:
    - "65500:2"
```

### Configuration Reference

While you can find more details in the [API reference](https://openperouter.github.io/docs/api-reference/) and the upstream OpenPERouter documentation, the following is a brief explanation of the above settings.

#### Underlay Configuration

- **`asn`**: `65500` sets the BGP Autonomous System Number of the OpenPERouter instances.
- **`tunnelEndpoint.cidrs`**: Sets the subnet for the tunnel endpoints. Here, we chose `fd00::/64`. Each node will select the IP address inside this CIDR corresponding to its node ID. E.g. node ID 2 would set an IP address of `fd00::2/64`. This IP address is configured inside the `perouter` namespace, on the `lo` loopback interface. Traffic via the VXLAN tunnels originates from / and is sent to this IP address, and the IP address is advertised via IS-IS to the rest of the underlay network.
- **`interfaces`**: Selects the underlay interface via which this node actually communicates with the rest of the network. The interface, including its preexisting IP addresses, is moved from the main network namespace into the `perouter` namespace. All preexisting IP addresses will be restored and IS-IS will be activated on the interface.
- **`routerIDCIDR`**: The node's router-id for BGP will be chosen from this subnet, e.g. for subnet `10.0.0.0/24` a node with node ID 4 will have router-id `10.0.0.4`.
- **`isis`**: Enables and configures IS-IS. The single NET address is configured via `baseNet`. The actual NET ID is `baseNet` + node ID. E.g., with `baseNet` `49.0001.0000.0000.0000.00` and node ID 4, the resulting NET will be `49.0001.0000.0000.0004.00`. When the `isis` stanza is present, by default, IS-IS will be enabled for address-family IPv6 only on all interfaces under `underlay.interfaces`, and for the `lo` loopback interfaces, with IS-IS passive for the latter. IS-IS currently has a `features` configuration knob to advertise passive interfaces only as well as an `isis.interfaces` list that allows enabling/disabling specific address-families on specific interfaces (useful if the default settings are insufficient).
- **`srv6`**: Contains Segment Routing over IPv6 related configuration. Currently, only `usid-f3216` is supported. Allows setting the encapsulation behavior (`H.Encaps.Red` or `H.Encaps`). The most important setting here is the `basePrefix`. Based on this prefix, the correct node ID will be chosen inside the locator node segment. A prefix should be chosen so that the first 32 bits, the block segment, are fixed, and the entire mask must be 48 bits, e.g. `fd00:2::/48`. In this example, with a node ID of 2, the FRR setting will be `prefix fd00:2:2::/48 block-len 32 node-len 16`.
- **`nodeSelector`**: Selects the respective node type (control-plane or worker). This setting is currently without effect in the OpenShift setup. Instead, see [Determining the node type](#determining-the-node-type).
- **`routeReflector`**: Only used on the master nodes to make these nodes route reflectors and to set the RR cluster ID.
- **`neighbors`**: Configures the neighbors. For master nodes, we set up an SRv6 overlay with a single neighbor (`fc00:0:20::1`) in this case and we explicitly instruct it here to exchange routes for address-families IPv4 VPN and IPv6 VPN. For EVPN, we configure a `listenRange` of `2600:52:7::/48`. All worker nodes are route reflector clients to the 3 master nodes, and their `eno12399np0` IPv6 address must be inside this subnet. The master nodes also peer between each other for EVPN, and their IP addresses are explicitly defined. Worker nodes have the same setup minus the `listenRange` as they are not route reflectors.

#### L2VNI Configuration (East/West Traffic)

For East/West traffic between the OpenShift nodes only:

- **`vni`**: Configures the VXLAN VNI for the L2 EVPN network. Also determines the name of the bridge, VXLAN interface, and veth inside the `perouter` namespace, e.g. for VNI 210 the bridge name would be `br-pe-210`.
- **`routingDomain`**: Connects this L2 VNI to the same VRF as the L3 network (see below).
- **`vxlanport`**: Should be `4789`.
- **`gatewayIPs`**: Assigns these IP addresses as anycast IPs inside the `perouter` namespace on each OpenShift node, to the bridge inside the perouter, e.g. `br-pe-210`. `br-ex` (on top of `br0`) inside the global network namespace is inside the same subnet, and its IPv4 and IPv6 gateways are configured to be exactly these gateway IP addresses. E.g., traffic destined outside of the cluster originates from `br-ex` in the global network namespace, is switched via `br0`, crosses the veth into the `perouter` namespace, and hits the anycast gateway IP address on `br-pe-210`. From there, it is routed into the SRv6 L3 domain and leaves the nodes via the SRv6 overlay.
- **`hostMaster`**: Points to `br0` and sets up a veth tunnel that connects `br0` with the `br-pe-210` inside the perouter.

#### L3VPN Configuration (North/South Traffic)

For North/South traffic from/to OpenShift and the OpenShift external overlay network:

- **`name`**: Identifier referenced by `l2vni.routingDomain`.
- **`vrf`**: The VRF used inside the `perouter` namespace.
- **`rdAssignedNumber`**: The route distinguisher part, joined to the BGP ASN to form the full Route Distinguisher: `ASN:rdAssignedNumber`.
- **`exportRTs`/`importRTs`**: The exact export and import Route Targets.

> **NOTE:** Should additional raw configuration be needed, consult the [API reference](https://openperouter.github.io/docs/api-reference/) for available options.
