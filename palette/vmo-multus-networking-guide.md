# VMO & Multus Network Attachment Definition Guide

Complete guide for configuring VM networking with Multus Network Attachment Definitions (NADs) in Palette VMO (Virtual Machine Orchestrator).

## Table of Contents

- [Overview](#overview)
- [Why VMO Requires br0 Bridge](#why-vmo-requires-br0-bridge)
  - [How VM Networking Works](#how-vm-networking-works)
  - [Why br0 and Not Direct Bond/NIC](#why-br0-and-not-direct-bondnic)
  - [Cilium Configuration for br0](#cilium-configuration-for-br0)
- [Network Attachment Definition Options](#network-attachment-definition-options)
  - [Option 1: Linux Bridge (Easiest)](#option-1-linux-bridge-easiest)
  - [Option 2: Macvlan](#option-2-macvlan)
  - [Option 3: SR-IOV (High Performance)](#option-3-sr-iov-high-performance)
  - [Option 4: OVN-Kubernetes](#option-4-ovn-kubernetes)
- [IPAM Options](#ipam-options)
- [Creating NADs via YAML](#creating-nads-via-yaml)
- [VLAN Filtering](#vlan-filtering)
- [Troubleshooting](#troubleshooting)
- [References](#references)

---

## Overview

**Multus CNI** is a meta-plugin that enables attaching multiple network interfaces to pods (and VMs). In VMO/KubeVirt, Multus allows VMs to have additional network interfaces beyond the default pod network, enabling VMs to connect to VLANs, external networks, and high-performance networks.

**Network Attachment Definitions (NADs)** are Kubernetes Custom Resources that define how secondary networks are configured. Each NAD specifies a CNI plugin configuration that Multus will use to attach an interface to a VM.

**Key Concepts:**
- **Primary Network**: The default pod network (managed by the cluster CNI like Cilium)
- **Secondary Networks**: Additional networks attached via Multus NADs
- **Bridge (br0)**: A host-level Linux bridge that acts as a virtual switch for VM traffic

---

## Why VMO Requires br0 Bridge

### How VM Networking Works

When you attach a VM to a secondary network using Multus, the VM's virtual NIC (vNIC) needs to connect to the physical network. This happens through a **bridge interface** on the host:

```
┌────────────────────────────────────────────────────────────────────────────┐
│                              KUBERNETES NODE                               │
├────────────────────────────────────────────────────────────────────────────┤
│                                                                            │
│  ┌───────────────┐  ┌───────────────┐  ┌───────────────┐                   │
│  │     VM 1      │  │     VM 2      │  │     VM 3      │                   │
│  │  VLAN 25      │  │  VLAN 30      │  │  VLAN 25      │                   │
│  └───────┬───────┘  └───────┬───────┘  └───────┬───────┘                   │
│          │                  │                  │                           │
│          │ veth/tap         │ veth/tap         │ veth/tap                  │
│          │                  │                  │                           │
│  ┌───────┴──────────────────┴──────────────────┴────────┐                  │
│  │                         br0                          │                  │
│  │               (Linux Bridge Interface)               │                  │
│  │         ← VLAN filtering enabled here                │                  │
│  └───────────────────────────┬──────────────────────────┘                  │
│                              │                                             │
│  ┌───────────────────────────┴───────────────────────────┐                 │
│  │                bond_data (optional)                   │                 │
│  │             (NIC Bond - mode 1, 2, or 4)              │                 │
│  └───────────────────────────┬───────────────────────────┘                 │
│                              │                                             │
│  ┌───────────────────────────┴───────────────────────────┐                 │
│  │                    Physical NICs                      │                 │
│  │                   (eth2, eth3, etc.)                  │                 │
│  └───────────────────────────────────────────────────────┘                 │
└────────────────────────────────────────────────────────────────────────────┘
                               │
                               │ Trunked VLANs (25, 30, etc.)
                               ▼
                        ┌──────────────┐
                        │   Switch     │
                        └──────────────┘
```

### Why br0 and Not Direct Bond/NIC

The **Linux bridge CNI plugin** (used for VM networking) specifically requires a **bridge interface**. Here's why:

| Approach | Works? | Why? |
|----------|--------|------|
| `bridge: "br0"` | ✅ Yes | Bridge CNI attaches VM veth interfaces as bridge ports |
| `master: "bond0"` | ❌ No | Bonds don't support attaching veth interfaces as ports |
| `master: "eth0"` | ❌ No | Physical NICs don't support multiple MAC addresses cleanly |

**Technical reasons:**
1. **Layer 2 Switching**: A Linux bridge acts as a virtual switch, allowing multiple VMs to share the same physical uplink while maintaining their own MAC addresses
2. **VLAN Tagging**: The bridge can apply VLAN tags to VM traffic, enabling per-VM VLAN isolation
3. **Multiple MACs**: Each VM has its own MAC address; a bridge properly handles multiple MACs unlike direct NIC attachment
4. **Port Attachment**: The bridge CNI plugin uses `brctl addif` (or `ip link set master`) to attach VM veth interfaces — this only works with bridge interfaces

### Bond is Optional (But Recommended)

The bond underneath `br0` is **optional** — you can create a bridge directly on a single physical NIC:

```
Option A: br0 on Bond (Recommended)     Option B: br0 on Single NIC (Simpler)
┌─────────────────────────────┐         ┌─────────────────────────────┐
│           br0               │         │           br0               │
│      (Linux Bridge)         │         │      (Linux Bridge)         │
└─────────────┬───────────────┘         └─────────────┬───────────────┘
              │                                       │
┌─────────────┴───────────────┐         ┌─────────────┴───────────────┐
│         bond_data           │         │           eth1              │
│  (mode 1, 2, or 4 — see     │         │      (Single NIC)           │
│   supported modes below)    │         │                             │
└──────┬──────────────┬───────┘         └─────────────────────────────┘
       │              │
┌──────┴─────┐ ┌──────┴─────┐
│   eth2     │ │   eth3     │
└────────────┘ └────────────┘
```

**When to use a bond:**

| Consideration | Bond (Recommended) | Single NIC |
|---------------|-------------------|------------|
| **Production workloads** | ✅ Yes | ⚠️ Risk |
| **High availability** | ✅ Link redundancy | ❌ Single point of failure |
| **Aggregate bandwidth** | ✅ Up to 2×10G (mode dependent) | ❌ Limited to NIC speed |
| **Lab/Dev environments** | Optional | ✅ Simpler setup |
| **Switch configuration** | Depends on mode (see below) | None |
| **NIC failure tolerance** | ✅ Survives NIC failure | ❌ VM network down |

### Supported Bonding Modes for VLAN Bridging

Not all bonding modes work correctly with VLAN bridging. The following modes are **supported**:

| Mode | Name | Switch Config | Load Balancing | Use Case |
|------|------|---------------|----------------|----------|
| 1 | `active-backup` | **None required** | ❌ No | Failover only — simple redundancy |
| 2 | `balance-xor` | **None required** | ✅ Yes (hash-based) | Load balancing without switch support |
| 4 | `802.3ad` (LACP) | **LACP required** | ✅ Yes (aggregated) | **Preferred** — best throughput + redundancy |

> **⚠️ Warning:** Other modes (0, 3, 5, 6) are **not supported** for VLAN bridging due to MAC rewrite issues and broadcast storms that can occur when frames traverse the bridge.

**Mode recommendations:**

| Scenario | Recommended Mode | Why |
|----------|-----------------|-----|
| **Managed switch with LACP support** | Mode 4 (802.3ad) | Best performance + redundancy |
| **No switch config possible** | Mode 1 (active-backup) | Simple failover, no switch changes |
| **Unmanaged switch** | Mode 1 (active-backup) | Works without any switch configuration |
| **Need load balancing, no LACP** | Mode 2 (balance-xor) | Hash-based distribution |

**Recommendation:**
- **Production/VMO workloads**: Use a bond for redundancy — Mode 4 (802.3ad/LACP) if switch supports it, otherwise Mode 1 (active-backup)
- **Lab/Dev/PoC**: Single NIC is acceptable for simplicity
- **Edge deployments**: May use single NIC if hardware is limited, or Mode 1 for basic redundancy

**Example: br0 directly on a single NIC** (no bond):

```yaml
# Netplan example - br0 on single NIC
network:
  version: 2
  ethernets:
    eth1:
      dhcp4: false
  bridges:
    br0:
      interfaces: [eth1]
      dhcp4: true
      # Or static IP:
      # addresses: [192.168.1.10/24]
      # gateway4: 192.168.1.1
```

> **Note:** The bridge (`br0`) is always required for VM networking. The bond is optional but provides resilience for production deployments where VM network availability is critical.

**From the VMO pack configuration** (`values.yaml`):

```yaml
vlanFiltering:
  enabled: false
  env:
    # Which bridge interface to control
    bridgeIF: "br0"
    # Beginning of VLAN range to enable
    allowedVlans: "1"
```

The VMO pack explicitly expects `br0` as the bridge interface name for VLAN filtering.

### Cilium Configuration for VMO

When using Cilium as your CNI with VMO, there are two configuration scenarios depending on your network topology.

#### Always Required: VMO Compatibility Settings

These settings are **always required** when running VMO with Cilium, regardless of your NIC configuration:

```yaml
# VMO Compatibility - Always Required
cni:
  exclusive: false          # Allow Multus to coexist with Cilium
socketLB:
  hostNamespaceOnly: true   # Required for KubeVirt compatibility
```

> **💡 Preset available:** In the Cilium pack, use the preset **VMO Compatibility → Enable** to automatically configure these settings.

#### Optional: Running Cilium on br0

Running Cilium directly on the `br0` bridge interface is **only needed in specific scenarios** — it is not required for most VMO deployments.

**When do you need Cilium on br0?**

| Scenario | Cilium on br0? | Why |
|----------|----------------|-----|
| **Separate NICs for K8s and VMs** | ❌ No | Cilium runs on the K8s management NIC; br0 is on a separate data NIC |
| **2-NIC design with dedicated data bond** | ⚠️ Verify | Cilium typically uses the interface with the default route — verify your routing table |
| **Single NIC/bond for everything** | ✅ Yes | The only network path is through br0 |
| **br0 is on the primary/only interface** | ✅ Yes | Cilium must use br0 to reach other nodes |
| **Default route goes through br0** | ✅ Yes | Cilium follows the default route for device detection |

> **How Cilium auto-detects devices:** When `devices` is not explicitly set, Cilium detects which network interface(s) to use based on the **default route** and interfaces with valid IP addresses. In multi-NIC setups, this detection may not always select the interface you expect. If your default route goes through a bridge or you have complex routing, explicitly set `devices` to avoid surprises.

**Typical network designs:**

```
Design A: Separate Interfaces (Cilium on br0 NOT needed)
┌──────────────────────────────────────────────────────────────┐
│                         NODE                                 │
│                                                              │
│   ┌─────────────────┐          ┌─────────────────┐           │
│   │   bond_mgmt     │          │    bond_data    │           │
│   │  (K8s traffic)  │          │   (VM traffic)  │           │
│   │  default route  │          │        │        │           │
│   │  ← Cilium here  │          │       br0       │           │
│   └─────────────────┘          └─────────────────┘           │
└──────────────────────────────────────────────────────────────┘
Default route via bond_mgmt → Cilium uses bond_mgmt; br0 is independent.
Verify with: ip route show default

Design B: Single Interface (Cilium on br0 REQUIRED)
┌──────────────────────────────────────────────────────────────┐
│                         NODE                                 │
│                                                              │
│                    ┌─────────────────┐                       │
│                    │       br0       │                       │
│                    │  (All traffic)  │                       │
│                    │                 │                       │
│                    │  ← Cilium must  │                       │
│                    │    run here     │                       │
│                    └────────┬────────┘                       │
│                             │                                │
│                    ┌────────┴────────┐                       │
│                    │  bond0 or eth0  │                       │
│                    │  (single path)  │                       │
│                    └─────────────────┘                       │
└──────────────────────────────────────────────────────────────┘
br0 is on the only network interface; Cilium must use it.
```

**If you need Cilium on br0**, add these settings:

```yaml
# Only if br0 is on your primary/only interface
devices: "br0"
bpf:
  hostLegacyRouting: true   # Required when using bridge interfaces
```

> **💡 Preset available:** In the Cilium pack, use the preset **VMO - Bridge Interface → Run Cilium On Bridge (br0)** to automatically configure these settings. This preset is available alongside the VMO Compatibility preset.

> **About `bpf.hostLegacyRouting`:** When set to `true`, Cilium routes traffic via the Linux host networking stack. When `false` (default), Cilium routes more efficiently directly out of BPF, bypassing netfilter in the host namespace. The Cilium pack sets this to `true` for bridge interfaces because native BPF routing is not currently compatible with bridge interfaces.

**From the Cilium pack documentation:**

> **VMO - Bridge Interface:**
> - **Autodetect Cilium interface**: Let Cilium auto-detect devices (default)
> - **Run Cilium On Bridge (br0)**: If you run VMO and have limited NICs available, you may need to run a bridge interface on your primary NIC/bond to allow VMs to run on VLANs. In this situation, enable this option to configure `devices: br0` for Cilium and make sure every node in the cluster has a `br0` interface. This option will set `bpf.hostLegacyRouting: true` since native routing is not currently compatible with bridge interfaces.

---

## Network Attachment Definition Options

Below are the available NAD types, ordered from **easiest to configure** to **most complex/specialized**.

### Option 1: Linux Bridge (Easiest)

**Best for:** Most VMO deployments, VLAN-based isolation, general VM connectivity

The Linux bridge CNI plugin connects VMs to a Linux bridge on the host. This is the **recommended approach** for VMO.

**Pros:**
- Simple configuration
- Works with any physical network topology
- Supports VLAN tagging per VM
- No special hardware required
- Works well with bonded interfaces

**Cons:**
- Software-based (not bare-metal performance)
- All VM traffic goes through the host kernel

**Prerequisites:**
- `br0` bridge must exist on all nodes (configured via OS/network layer)
- Bridge must be a member of a bond or NIC connected to trunked switch ports

**Configuration:**

```yaml
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: vlan-25
  namespace: default
spec:
  config: |
    {
      "cniVersion": "0.3.1",
      "type": "bridge",
      "bridge": "br0",
      "vlan": 25,
      "ipam": {}
    }
```

**Parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `type` | Yes | Must be `"bridge"` |
| `bridge` | Yes | Name of the Linux bridge (typically `br0`) |
| `vlan` | No | VLAN ID to tag traffic (omit for untagged) |
| `ipam` | No | IPAM configuration (empty `{}` for no IPAM, letting VMs use DHCP) |

**Optional security/VLAN parameters:**

| Parameter | Default | Description |
|-----------|---------|-------------|
| `macspoofchk` | `true` | **MAC spoofing protection.** When enabled, the bridge verifies that outgoing frames have the expected source MAC address (the one assigned to the VM's vNIC). Prevents VMs from impersonating other MAC addresses on the network. Recommended to keep enabled for security. |
| `preserveDefaultVlan` | `true` | **Preserve native VLAN (PVID) on the bridge port.** When `false`, the VM's bridge port won't participate in the bridge's default untagged VLAN — traffic must be explicitly tagged. Set to `false` when using explicit VLAN tagging to prevent untagged traffic leakage. |

---

### Option 2: Macvlan

**Best for:** Simple VM-to-external-network connectivity without a bridge, when VMs need their own IP directly on the physical network

Macvlan creates virtual interfaces with unique MAC addresses directly on a physical interface (NIC or bond).

> **🔑 Key difference from Linux Bridge:** Macvlan does **NOT** require `br0`. Instead, you specify the physical interface (`master`) directly — typically a NIC (`eth1`, `ens5`) or bond (`bond0`). This makes macvlan simpler to set up when you don't need VLAN tagging or bridge-based features.

**Pros:**
- **No bridge (br0) required** — simpler network topology
- Slightly better performance than bridge (fewer hops)
- VMs get IPs directly from the physical network

**Cons:**
- **VM-to-host communication is blocked** (macvlan limitation)
- **VM-to-VM on same host may be blocked** in some modes
- Less flexible than bridge for VLAN configurations
- Host cannot communicate with VMs using the same interface
- VLAN tagging less straightforward than with bridge CNI

**Prerequisites:**
- A physical NIC or bond that VMs will attach to (e.g., `bond0`, `eth1`)
- The interface must be connected to the network you want VMs to access
- No br0 bridge required

**Configuration (recommended — external DHCP or static IP inside VM):**

```yaml
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: macvlan-net
  namespace: default
spec:
  config: |
    {
      "cniVersion": "0.3.1",
      "type": "macvlan",
      "master": "bond0",
      "mode": "bridge",
      "ipam": {}
    }
```

With `"ipam": {}`, the CNI does not assign an IP. The VM must get its IP via:
- **DHCP** from an external DHCP server on the network
- **Static IP** configured inside the VM's OS

**Alternative — CNI-managed IP allocation:**

```yaml
spec:
  config: |
    {
      "cniVersion": "0.3.1",
      "type": "macvlan",
      "master": "bond0",
      "mode": "bridge",
      "ipam": {
        "type": "host-local",
        "subnet": "192.168.1.0/24",
        "rangeStart": "192.168.1.200",
        "rangeEnd": "192.168.1.250",
        "routes": [{ "dst": "0.0.0.0/0" }],
        "gateway": "192.168.1.1"
      }
    }
```

> **⚠️ Warning about `host-local` IPAM:** The `host-local` IPAM plugin allocates IPs **per-node** — each node tracks allocations independently. This means:
> - VM1 on Node-A might get `192.168.1.200`
> - VM2 on Node-B might **also** get `192.168.1.200` → **IP conflict!**
>
> For VMs, prefer one of:
> - **Empty IPAM** (`{}`) with external DHCP — most reliable for multi-node clusters
> - **Whereabouts IPAM** — cluster-wide IP tracking that prevents conflicts (requires deploying whereabouts)
> - **Static IPs** configured inside each VM

**Macvlan Modes:**

| Mode | Description | VM ↔ VM (same host) | VM ↔ Host |
|------|-------------|---------------------|-----------|
| `bridge` | VMs can communicate with each other | ✅ Yes | ❌ No |
| `vepa` | Traffic hairpins through external switch | ⚠️ Via switch only | ❌ No |
| `private` | VMs isolated from each other | ❌ No | ❌ No |
| `passthru` | Single VM takes over the interface | N/A | ❌ No |

> **⚠️ Important:** Macvlan inherently blocks host-to-VM communication. If your VMs need to communicate with services running on the Kubernetes node itself, use Linux bridge instead.

---

### Option 3: SR-IOV (High Performance)

**Best for:** High-performance workloads requiring near-native network throughput (NFV, HPC, latency-sensitive applications)

SR-IOV (Single Root I/O Virtualization) creates Virtual Functions (VFs) directly on the NIC hardware, bypassing the host kernel for maximum performance.

**Pros:**
- Near bare-metal network performance
- Lower latency and higher throughput
- Offloads processing to NIC hardware
- Direct hardware access for VMs

**Cons:**
- Requires SR-IOV capable NICs (Intel X710, Mellanox, etc.)
- Complex setup (BIOS, drivers, operator configuration)
- Limited number of VFs per physical NIC
- Less flexible (VFs are fixed resources)

**Prerequisites:**
1. SR-IOV capable NIC (check vendor documentation)
2. BIOS: Enable SR-IOV, VT-d/IOMMU
3. Kernel parameters: `intel_iommu=on` or `amd_iommu=on`
4. SR-IOV Device Plugin and Operator deployed
5. VFs created on the host

**Configuration:**

```yaml
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: sriov-net
  namespace: default
  annotations:
    k8s.v1.cni.cncf.io/resourceName: intel.com/intel_sriov_netdevice
spec:
  config: |
    {
      "cniVersion": "0.3.1",
      "type": "sriov",
      "vlan": 100,
      "ipam": {}
    }
```

**SR-IOV Setup Steps:**

1. **Enable SR-IOV in BIOS** and configure VFs:
   ```bash
   # Check SR-IOV support
   lspci -v | grep -i sr-iov
   
   # Create VFs (example for Intel NIC)
   echo 8 > /sys/class/net/ens3f0/device/sriov_numvfs
   ```

2. **Deploy SR-IOV Network Operator** (typically via Palette add-on pack)

3. **Create SriovNetworkNodePolicy**:
   ```yaml
   apiVersion: sriovnetwork.openshift.io/v1
   kind: SriovNetworkNodePolicy
   metadata:
     name: policy-intel-sriov
     namespace: sriov-network-operator
   spec:
     resourceName: intel_sriov_netdevice
     nodeSelector:
       feature.node.kubernetes.io/network-sriov.capable: "true"
     numVfs: 8
     nicSelector:
       pfNames: ["ens3f0"]
     deviceType: netdevice
   ```

4. **Create the NAD** referencing the resource name from the policy

---

### Option 4: OVN-Kubernetes

**Best for:** Clusters using OVN-Kubernetes CNI, software-defined networking, overlay networks

OVN-Kubernetes provides software-defined networking with two topology options.

> **Note:** OVN-Kubernetes NADs require OVN-Kubernetes as your cluster CNI. For most Palette VMO deployments (which typically use Cilium), Linux bridge is preferred.

#### OVN Layer 2 Overlay

Creates a virtual L2 network across nodes using OVN (Open Virtual Network).

```yaml
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: l2-network
  namespace: default
spec:
  config: |
    {
      "cniVersion": "0.4.0",
      "name": "l2-network",
      "type": "ovn-k8s-cni-overlay",
      "topology": "layer2",
      "netAttachDefName": "default/l2-network",
      "subnets": "192.168.100.0/24"
    }
```

#### OVN Localnet (Physical Network Access)

Connects VMs to external physical networks via OVS bridge mappings.

```yaml
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: localnet-external
  namespace: default
spec:
  config: |
    {
      "cniVersion": "0.4.0",
      "name": "physnet1",
      "type": "ovn-k8s-cni-overlay",
      "topology": "localnet",
      "netAttachDefName": "default/localnet-external",
      "vlanID": 100,
      "mtu": 1500
    }
```

**OVN Localnet Prerequisites:**
- OVS bridge mapping configured on nodes
- Physical network name must match bridge mapping configuration

---

## IPAM Options

IPAM (IP Address Management) determines how VMs get their IP addresses.

### No IPAM (External DHCP or Static)

Use when VMs get IPs from external DHCP or configure IPs manually inside the VM.

```yaml
"ipam": {}
```

### Host-Local IPAM

Allocates IPs from a local range. **Each node tracks allocations independently.**

```yaml
"ipam": {
  "type": "host-local",
  "subnet": "192.168.1.0/24",
  "rangeStart": "192.168.1.100",
  "rangeEnd": "192.168.1.200",
  "routes": [
    { "dst": "0.0.0.0/0" }
  ],
  "gateway": "192.168.1.1"
}
```

> **⚠️ Not recommended for VMs in multi-node clusters:** Since each node allocates IPs independently, two VMs on different nodes can get the same IP address, causing conflicts. Use **Whereabouts** or **external DHCP** instead for VMs.

### Static IPAM

Assigns a fixed IP (rarely used in NADs, more common in pod annotations).

```yaml
"ipam": {
  "type": "static",
  "addresses": [
    { "address": "192.168.1.50/24" }
  ]
}
```

### Whereabouts IPAM

Cluster-wide IPAM that tracks allocations across nodes (prevents IP conflicts).

```yaml
"ipam": {
  "type": "whereabouts",
  "range": "192.168.1.0/24",
  "exclude": ["192.168.1.1/32", "192.168.1.254/32"]
}
```

> **Recommendation:** For most VMO deployments, use empty IPAM (`{}`) and configure VMs to use DHCP from your external network, or use Whereabouts for cluster-managed IP allocation.

---

## Creating NADs via YAML

> **Note:** NADs must be created via YAML/kubectl. The VMO Dashboard allows you to **select** existing NADs when creating VMs, but does not provide a UI for creating NADs.

### Example: Multiple VLANs on br0

```yaml
---
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: vlan-10-management
  namespace: virtual-machines
spec:
  config: |
    {
      "cniVersion": "0.3.1",
      "type": "bridge",
      "bridge": "br0",
      "vlan": 10,
      "ipam": {}
    }
---
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: vlan-20-data
  namespace: virtual-machines
spec:
  config: |
    {
      "cniVersion": "0.3.1",
      "type": "bridge",
      "bridge": "br0",
      "vlan": 20,
      "ipam": {}
    }
---
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: vlan-100-dmz
  namespace: virtual-machines
spec:
  config: |
    {
      "cniVersion": "0.3.1",
      "type": "bridge",
      "bridge": "br0",
      "vlan": 100,
      "ipam": {}
    }
```

Apply:

```bash
kubectl apply -f network-attachment-definitions.yaml
```

### Attaching NADs to VMs

When creating a VM, add the network interface in the VM spec:

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: my-vm
  namespace: virtual-machines
spec:
  template:
    spec:
      domain:
        devices:
          interfaces:
            - name: default
              masquerade: {}
            - name: vlan25
              bridge: {}
      networks:
        - name: default
          pod: {}
        - name: vlan25
          multus:
            networkName: vlan-25
```

---

## VLAN Filtering

VMO includes a VLAN filtering DaemonSet that controls which VLANs are allowed on `br0`. This is a security feature that prevents VMs from accessing unauthorized VLANs.

### Enable VLAN Filtering in VMO Pack

```yaml
charts:
  virtual-machine-orchestrator:
    vlanFiltering:
      enabled: true
      namespace: kube-system
      env:
        # Which bridge interface to control
        bridgeIF: "br0"
        # VLANs allowed for VM traffic (comma-separated or range)
        allowedVlans: "10,20,25-100"
        # Enable VLANs on the host's br0 interface itself
        allowVlansOnSelf: "true"
        # VLANs allowed on the host (for host services)
        allowedVlansOnSelf: "1,10"
```

> **💡 Reference Profiles:** If you're using Spectro Cloud's VMO reference profiles, these VLAN filtering options are exposed as **cluster profile variables** that you can configure when deploying a cluster — no need to edit the pack YAML directly.

### How VLAN Filtering Works

1. The DaemonSet runs on each node
2. It configures bridge VLAN filtering using `bridge vlan` commands
3. VMs can only send/receive traffic on allowed VLANs
4. Unauthorized VLAN traffic is dropped

```bash
# View current VLAN configuration on br0
bridge vlan show dev br0

# Example output:
# port   vlan-id  
# br0      1 PVID Egress Untagged
#         10
#         20
#         25
```

---

## Troubleshooting

### NAD Not Working

1. **Check NAD exists and is valid:**
   ```bash
   kubectl get net-attach-def -n <namespace>
   kubectl describe net-attach-def <nad-name> -n <namespace>
   ```

2. **Check Multus is running:**
   ```bash
   kubectl get pods -n kube-system -l app=multus
   ```

3. **Check br0 exists on nodes:**
   ```bash
   # SSH to node
   ip link show br0
   bridge link show
   ```

### VM Network Interface Not Attached

1. **Check VM events:**
   ```bash
   kubectl describe vm <vm-name> -n <namespace>
   ```

2. **Check virt-launcher pod:**
   ```bash
   kubectl describe pod virt-launcher-<vm>-<id> -n <namespace>
   ```

3. **Verify NAD namespace matches VM namespace** (or use `<namespace>/<nad-name>` syntax)

### VLAN Traffic Not Working

1. **Check switch configuration:**
   - Ensure switch ports are configured as trunks
   - Verify VLANs are allowed on trunk ports

2. **Check VLAN filtering:**
   ```bash
   # On the node
   bridge vlan show dev br0
   ```

3. **Verify bond is member of bridge:**
   ```bash
   bridge link show
   # Should show bond_data or similar as member of br0
   ```

### Macvlan Issues

1. **VM can't reach host:**
   - This is expected — macvlan blocks host-to-VM communication
   - Use Linux bridge instead if host communication is required

2. **VMs can't communicate with each other:**
   - Check macvlan mode (use `bridge` mode for VM-to-VM)
   - Verify switch doesn't block hairpin traffic (for `vepa` mode)

### SR-IOV Issues

1. **VFs not created:**
   ```bash
   cat /sys/class/net/<pf>/device/sriov_numvfs
   lspci | grep -i virtual
   ```

2. **Resource not advertised:**
   ```bash
   kubectl get node <node> -o json | jq '.status.allocatable'
   # Should show intel.com/intel_sriov_netdevice or similar
   ```

3. **Check SR-IOV operator:**
   ```bash
   kubectl get sriovnetworknodestates -A
   kubectl get sriovnetworknodepolicies -A
   ```

---

## Comparison Summary

| Feature | Linux Bridge | Macvlan | SR-IOV | OVN |
|---------|-------------|---------|--------|-----|
| **Ease of Setup** | ⭐⭐⭐ Easy | ⭐⭐ Medium | ⭐ Complex | ⭐⭐ Medium |
| **Requires br0 bridge** | ✅ Yes | ❌ No | ❌ No | ❌ No |
| **Performance** | Good | Better | Best | Good |
| **VLAN Support** | ✅ Yes | ⚠️ Limited | ✅ Yes | ✅ Yes |
| **VM-to-Host** | ✅ Yes | ❌ No | ✅ Yes | ✅ Yes |
| **Hardware Required** | No | No | SR-IOV NIC | No |
| **Recommended For** | Most deployments | Simple external access | High-performance | OVN-Kubernetes CNI |

**Recommendation:** Start with **Linux Bridge** for most VMO deployments. It's the simplest, most flexible option that works with any network configuration. Use **Macvlan** if you want simpler network topology without br0 and don't need VM-to-host communication. Only consider **SR-IOV** for workloads that truly require bare-metal network performance.

---

## References

- [Spectro Cloud VMO Documentation](https://docs.spectrocloud.com/vm-management/)
- [Multus CNI Documentation](https://github.com/k8snetworkplumbingwg/multus-cni)
- [KubeVirt Networking](https://kubevirt.io/user-guide/virtual_machines/interfaces_and_networks/)
- [Linux Bridge CNI Plugin](https://www.cni.dev/plugins/current/main/bridge/)
- [SR-IOV Network Operator](https://github.com/k8snetworkplumbingwg/sriov-network-operator)
- [MAAS & Bare-Metal VMO Guide](palette-maas-baremetal-vmo.md)
