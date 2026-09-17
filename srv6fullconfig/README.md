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

The systemd services in [`extras/rawconfig/`](extras/rawconfig/) run in
sequence at boot to configure each node:

| Script | What it does |
|--------|-------------|
| `setup-underlay.sh` | Waits for FRR and br0/br-ex, derives the node index (last octet) from the bridge IP |
| `generate-config.sh` | Determines node role (master/worker) from node index, copies the matching YAML configs |
| `openperouter-common.sh` | Shared helpers (logging, namespace utilities) sourced by all scripts |

## FRR Configuration

FRR config files live in `extras/rawconfig/`:

- **`openpe_master.yaml`** - OpenPERouter configuration for the masters
- **`openpe_worker.yaml`** - OpenPERouter configuration for the workers

`generate-config.sh` selects master or worker configs by comparing the node's
last octet against `RR_NODE_IDX_0/1/2` and copies the matching YAML files.

## Configuration (vpn-setup.env)

All tunable parameters live in [`extras/rawconfig/vpn-setup.env`](extras/rawconfig/vpn-setup.env):

| Variable | Default | Description |
|----------|---------|-------------|
| `FRR_READY_TIMEOUT` | `60` | Seconds to wait for the FRR container to start |
| `BR0_READY_TIMEOUT` | `120` | Seconds to wait for br0/br-ex to get an IP |

## MTU Configuration

The MTU must be lowered in three places to account for double
encapsulation (Geneve overlay inside IPv6/VXLAN overlay). All values
below assume a 1500 byte MTU on the wire.

**1. agent-config.yaml** — sets the br0 MTU during initial install:

```yaml
- name: br0
  type: linux-bridge
  state: up
  mtu: 1430
```

**2. MachineConfigurations** — after the nodes reboot and reconfigure
networking, a NetworkManager drop-in keeps the br0 MTU at 1430.
`configimage/generate_machineconfigs.sh` generates these from
`configimage/if-mtu.bu` (masters) and `configimage/if-mtu-worker.bu`
(workers). The source file is `extras/rawconfig/br0-mtu.conf`.

**3. Cluster network MTU** — OVN-Kubernetes defaults to 1400
(1500 − 100 for Geneve). With IPv6 VXLAN the additional overhead is
70 bytes, so the cluster MTU must be set to 1330.
`configimage/generate_machineconfigs.sh` generates a Network operator
manifest (`set-cluster-mtu.yaml`) with `mtu: 1330`.

## Building

- **Appliance ISO**: [`appliance/generate_appliance.sh`](appliance/generate_appliance.sh) `<pull_secret_file>`
- **Config-image ISO**: [`configimage/generate_config_image.sh`](configimage/generate_config_image.sh) `<pull_secret_file>`
