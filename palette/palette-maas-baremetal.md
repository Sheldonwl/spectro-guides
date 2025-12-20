# MAAS & Bare-Metal VMO Deployment Guide

Complete guide for deploying Palette with MAAS bare-metal infrastructure and Virtual Machine Orchestrator (VMO/KubeVirt).

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [MAAS Server Requirements](#maas-server-requirements)
  - [Hardware Requirements](#maas-hardware-requirements)
  - [Network Ports](#maas-network-ports)
  - [PXE Boot Services](#pxe-boot-services)
  - [DNS Configuration](#maas-dns-configuration)
    - [⚠️ Use a Proper Subdomain, Not Just `.maas`](#️-use-a-proper-subdomain-not-just-maas)
    - [Recommended DNS Architecture](#recommended-dns-architecture)
    - [Conditional Forwarding](#conditional-forwarding)
  - [BMC/IPMI Requirements](#bmcipmi-requirements)
- [Private Cloud Gateway (PCG)](#private-cloud-gateway-pcg)
  - [PCG Sizing](#pcg-sizing)
  - [PCG Prerequisites](#pcg-prerequisites)
  - [PCG Network Requirements](#pcg-network-requirements)
  - [IP Requirements](#ip-requirements)
- [Bare-Metal Host Requirements](#bare-metal-host-requirements)
  - [Hardware Specifications](#hardware-specifications)
  - [BIOS Configuration](#bios-configuration)
  - [NIC Layout](#nic-layout)
  - [Bonding Configuration](#bonding-configuration)
- [Kubernetes Cluster Planning](#kubernetes-cluster-planning)
  - [Cluster Sizing](#cluster-sizing)
  - [CIDR Planning](#cidr-planning)
  - [CNI Selection](#cni-selection)
- [Storage (Portworx + Pure FlashArray)](#storage-portworx--pure-flasharray)
  - [Storage Requirements](#storage-requirements)
  - [Portworx Configuration](#portworx-configuration)
  - [FlashArray Integration](#flasharray-integration)
- [VMO (KubeVirt) Configuration](#vmo-kubevirt-configuration)
  - [VMO Prerequisites](#vmo-prerequisites)
  - [Reference Profiles](#reference-profiles)
  - [VMO Pack Settings](#vmo-pack-settings)
  - [OIDC Configuration for VMO](#oidc-configuration-for-vmo)
  - [Custom CA Certificate](#custom-ca-certificate-self-hosted-palette)
  - [VM Networking](#vm-networking)
  - [Verifying VMO Deployment](#verifying-vmo-deployment)
- [Pre-Flight Checklist](#pre-flight-checklist)
- [Deployment Workflow](#deployment-workflow)
  - [Step 1: Verify MAAS is Ready](#step-1-verify-maas-is-ready)
  - [Step 2: Deploy PCG](#step-2-deploy-pcg)
  - [Step 3: Create Cluster Profile](#step-3-create-cluster-profile)
  - [Step 4: Deploy Bare-Metal Cluster](#step-4-deploy-bare-metal-cluster)
  - [Step 5: Configure VMO](#step-5-configure-vmo)
- [Troubleshooting](#troubleshooting)

**Related Guides:**
- [Network Requirements Reference](palette-network-requirements.md) — Complete port, firewall, and connectivity requirements
- [Self-Hosted Helm Installation](palette-selhhosted-helm-install.md) — Step-by-step Palette installation
- [Debugging Guide](palette-debugging.md) — Troubleshooting tips for agents, VMO, OIDC
- [pfSense Integration](palette-pfsense-integration.md) — DNS forwarding, VLAN, and firewall configuration

---

## Overview

This guide covers deploying **VMO (KubeVirt) on bare-metal Kubernetes clusters** provisioned via **MAAS**, using Palette for cluster lifecycle management.

**What this guide covers:**
- MAAS server requirements and configuration
- PCG (Private Cloud Gateway) deployment to connect Palette ↔ MAAS
- Bare-metal host requirements (hardware, networking, storage)
- Cluster profile configuration (CNI, storage, VMO packs)
- VMO deployment and configuration

**Prerequisites (not covered here):**
- **Palette** — Must be running (SaaS or self-hosted). See [Self-Hosted Helm Installation](palette-selhhosted-helm-install.md) if you need to install Palette first.
- **MAAS** — Must be installed and operational. This guide covers requirements, not installation.

**Official Documentation:**
- [Spectro Cloud Docs](https://docs.spectrocloud.com/)
- [VMO Reference Architecture](https://www.spectrocloud.com/resources/collateral/vmo-architecture-pdf)

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                         PALETTE VMO ON BARE METAL                                │
└─────────────────────────────────────────────────────────────────────────────────┘

                              ┌──────────────────────┐
                              │   Palette (Self-     │
                              │   Hosted or SaaS)    │
                              │   443 IN/OUT         │
                              └──────────┬───────────┘
                                         │
                              ┌──────────▼───────────┐
                              │        PCG           │
                              │  (Private Cloud      │
                              │   Gateway)           │
                              │                      │
                              │  OUT: 443, 6443,     │
                              │       22, 5240       │
                              └──────────┬───────────┘
                                         │
              ┌──────────────────────────┼──────────────────────────┐
              │                          │                          │
              ▼                          ▼                          ▼
   ┌──────────────────┐      ┌──────────────────────┐    ┌──────────────────┐
   │   MAAS Server    │      │  Bare-Metal Cluster  │    │  Pure FlashArray │
   │                  │      │                      │    │                  │
   │  5240 (API)      │      │  Control Plane (3)   │    │  443 (API)       │
   │  5248 (HTTP)     │      │  Workers (4-5+)      │    │  FC/iSCSI        │
   │  67-69 (PXE)     │      │                      │    │                  │
   └──────────────────┘      │  ┌────────────────┐  │    └──────────────────┘
                             │  │ VMO (KubeVirt) │  │
                             │  │ Portworx       │  │
                             │  │ Cilium CNI     │  │
                             │  │ MetalLB        │  │
                             │  └────────────────┘  │
                             └──────────────────────┘
```

---

## MAAS Server Requirements

### MAAS Hardware Requirements

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| vCPU | 4 | 6 |
| Memory | 8 GB | 16 GB |
| Disk | 60 GB | 100+ GB |

**Supported Version:** MAAS **3.6.0**

### MAAS Network Ports

| Port | Protocol | Direction | Purpose |
|------|----------|-----------|---------|
| 5240 | TCP | Inbound | UI & API (HTTP) |
| 5443 | TCP | Inbound | API (if TLS enabled) |
| 5248 | TCP | Inbound | Rack HTTP — PXE/iPXE boot assets |
| 5241-5247 | TCP/UDP | Internal | Rack ↔ Region communication |
| 5250-5270 | TCP/UDP | Internal | Worker processes |

### PXE Boot Services

When MAAS provides PXE services:

| Port | Protocol | Purpose |
|------|----------|---------|
| 67 | UDP | DHCP server (receives requests) |
| 68 | UDP | DHCP client (receives responses) |
| 69 | UDP | TFTP — Initial PXE boot stage |
| 5248 | TCP | HTTP — Kernel/initrd downloads |

**PXE Boot Flow:**
```
Client → DHCP (67/68) → TFTP (69) → HTTP (5248) → Boot
```

**Optional MAAS-managed services:**

| Port | Protocol | Purpose |
|------|----------|---------|
| 53 | TCP/UDP | DNS (if MAAS provides) |
| 123 | UDP | NTP (if MAAS provides) |
| 8000 | TCP | HTTP proxy for package downloads |
| 3128 | TCP | Squid proxy (alternative) |

### MAAS DNS Configuration

- MAAS can act as authoritative DNS for its zone
- Configure forwarders for external domains
- If using external DNS, delegate the MAAS zone to the MAAS DNS server
- PCG and clusters must resolve MAAS-deployed machine FQDNs

#### ⚠️ Use a proper subdomain, not just `.maas`

**Recommendation:** Configure MAAS to use a subdomain like `maas.example.local` instead of the default `.maas` TLD.

While MAAS works with the default `.maas` zone for basic provisioning, using a non-standard TLD causes problems in real-world Kubernetes and enterprise deployments:

| Scenario | `.maas` Only | `maas.example.local` |
|----------|--------------|----------------------|
| Basic MAAS provisioning | ✅ Works | ✅ Works |
| TLS/SSL certificates | ❌ Self-signed only — CAs won't issue for non-standard TLDs | ✅ Internal CA works, proper chain of trust |
| Kubernetes node names | ⚠️ Usually works, edge cases with strict FQDN validation | ✅ Always valid FQDN |
| CAPI webhook validation | ⚠️ Some webhooks reject non-standard TLDs | ✅ Passes all validation |
| OIDC/SSO integration | ❌ Cross-resolution fails if IdP on different domain | ✅ Unified DNS hierarchy |
| External DNS integration (pfSense, etc.) | ❌ Separate DNS islands, no forwarding | ✅ Conditional forwarding works |
| cert-manager / Let's Encrypt | ❌ ACME rejects non-standard TLDs | ⚠️ Internal CA only (expected for internal domains) |

#### Recommended DNS Architecture

Use a proper subdomain under your main domain:

```
example.local                    ← Your main domain (main DNS server authoritative)
├── palette.example.local       ← Palette UI
└── maas.example.local          ← MAAS zone (MAAS authoritative)
    ├── controller.maas.example.local
    ├── node1.maas.example.local
    ├── node2.maas.example.local
    └── node3.maas.example.local
```

**Configure MAAS to use the subdomain:**

In MAAS UI: **Settings → Network → DNS**

```yaml
# MAAS configuration
maas_name: maas
dns_domain: maas.example.local   # ← Use this instead of just "maas"
upstream_dns: 192.168.1.1        # ← Your main DNS server
```

#### Conditional Forwarding

If using a separate DNS server (e.g., pfSense, Unbound, dnsmasq), configure conditional forwarding to delegate the MAAS zone to the MAAS controller's DNS.

> **See:** [pfSense Integration Guide](palette-pfsense-integration.md) for detailed pfSense configuration including DNS forwarding, VLAN setup, and firewall rules.

**General concept:**
- Your main DNS server handles queries for your main domain
- Queries for `maas.example.local` are forwarded to the MAAS controller
- MAAS DNS handles resolution for nodes it manages

#### Verify DNS Resolution

After configuration, verify resolution works from all components:

```bash
# From a MAAS-provisioned node — resolve both zones
dig node1.maas.example.local    # Should resolve via MAAS DNS
dig palette.example.local       # Should resolve via upstream DNS
dig google.com                  # Should resolve via upstream forwarders

# From Palette/PCG — resolve MAAS nodes
dig node1.maas.example.local @192.168.1.50   # Direct query to MAAS DNS

# Test conditional forwarding
dig maas.example.local @192.168.1.1          # Should forward to MAAS
```

### BMC/IPMI Requirements

BMC control is required for power-cycling nodes:

| Method | Port | Notes |
|--------|------|-------|
| Redfish (recommended) | 443/TCP | Modern, secure |
| IPMI | 623/UDP | Legacy, configure cipher suite |

> **Recommendation:** Use Redfish where available for better security and functionality.

---

## Private Cloud Gateway (PCG)

PCG bridges your private MAAS network to Palette.

### PCG Sizing

| Deployment | Nodes | CPU/Node | Memory/Node | Disk/Node | Concurrent Clusters |
|------------|-------|----------|-------------|-----------|---------------------|
| Single-node | 1 | 4 vCPU | 8 GB | 60+ GB | 1-3 |
| HA (Production) | 3 | 4 vCPU | 8 GB | 60+ GB | 4-6+ |

### PCG Prerequisites

- **Palette API key** from local tenant admin (SSO won't work for install)
- **Palette CLI** installed on x86-64 Linux host with Docker
- Network connectivity to both Palette and MAAS
- **MAAS API key** and server URL (e.g., `http://<ip>:5240/MAAS`)

### PCG Network Requirements

**Outbound from PCG:**

| Port | Protocol | Destination | Purpose |
|------|----------|-------------|---------|
| 443 | TCP | Palette URL | API, gRPC over TLS |
| 443 | TCP | Container registries | Image pulls |
| 5240 | TCP | MAAS server | MAAS API |
| 6443 | TCP | Workload clusters | Kubernetes API |
| 22 | TCP | Cluster nodes | SSH provisioning |
| 123 | UDP | NTP server | Time sync |

**Inbound to PCG:**

| Port | Purpose |
|------|---------|
| None | PCG initiates all connections outbound |

### IP Requirements

| Requirement | Single-Node | HA (3-node) |
|-------------|-------------|-------------|
| Node IPs | 1 | 3 |
| Kubernetes API VIP | — | 1 |
| PCG VIP | 1 | 1 |
| Repave buffer | 1 | 1 |
| **Total** | **3** | **6** |

> Ensure sufficient IP range in MAAS subnets for PCG and cluster nodes.

---

## Bare-Metal Host Requirements

### Hardware Specifications

#### Control Plane Nodes

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| Nodes | 3 | 3 |
| CPU | 4 vCPU | 8 vCPU |
| Memory | 8 GB | 32 GB |
| NICs | 2×10 GbE | 4×10 GbE |

#### Worker Nodes (VMO)

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| Nodes | 4 | 5+ |
| CPU | 8 cores | 48+ cores |
| Memory | 24 GB | 256 GB+ |
| NICs | 2×10 GbE (data+mgmt) | 4×10 GbE (2 data + 2 mgmt) |
| Storage HBA | 2×16 Gbps FC or 2×10 Gbps iSCSI | 2×16 Gbps FC or 2×25 Gbps iSCSI |
| Disks | Local disk for OS boot | Local disk for OS boot |

> **Why 4-5 workers?** Portworx quorum requires 3 storage nodes minimum. With 4 workers, you have 1 spare. With 5, you have resilience for maintenance.

### BIOS Configuration

**Required settings:**

| Setting | Value | Purpose |
|---------|-------|---------|
| Intel VT-x or AMD-V | Enabled | Hardware virtualization for KubeVirt |
| IOMMU | Enabled | PCI passthrough, SR-IOV |

**Validation:**

```bash
# Check virtualization support
grep -E 'vmx|svm' /proc/cpuinfo

# Check KVM modules
lsmod | grep kvm
```

**Boot parameters (if needed):**

```
intel_iommu=on   # For Intel
amd_iommu=on     # For AMD
```

### NIC Layout

#### 4-NIC Design (Recommended)

```
┌─────────────────────────────────────────────────────────────────┐
│                     BARE-METAL HOST                              │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌──────────────────────┐    ┌──────────────────────┐          │
│  │     bond_mgmt        │    │     bond_data        │          │
│  │     (802.3ad)        │    │     (802.3ad)        │          │
│  │                      │    │                      │          │
│  │  NIC1 ─┬─► VLAN 10   │    │  NIC3 ─┬─► VLAN 20   │          │
│  │  NIC2 ─┘   (K8s mgmt)│    │  NIC4 ─┘   (Data)    │          │
│  │        + PXE native  │    │        + br0 bridge  │          │
│  └──────────────────────┘    └──────────┬───────────┘          │
│                                         │                       │
│                              ┌──────────▼───────────┐          │
│                              │        br0           │          │
│                              │   (Bridge for VMs)   │          │
│                              │   VM VLANs (e.g. 21+)│          │
│                              └──────────────────────┘          │
└─────────────────────────────────────────────────────────────────┘
```

**Configuration:**
- `bond_mgmt` (802.3ad) → PXE native + VLAN 10 (K8s management)
- `bond_data` (802.3ad) → VLAN 20 (data/MetalLB) + default gateway
- `br0` (bridge) on bond_data → Master for Multus/VLAN bridging to VMs

> **Important:** `br0` **must** be a bridge (not a bond or VLAN directly) for VM networking to work.

#### 2-NIC Design (Minimum)

When only 2 NICs are available (shared data+mgmt):
- Single bond (`bond0`) with VLAN subinterfaces
- `br0` bridge with VLAN subinterfaces for VMs
- Note: Some VLANs may not be reachable by VMs depending on termination point

### Bonding Configuration

**Supported bonding modes for VLAN bridging:**

| Mode | Name | Switch Config | Recommendation |
|------|------|---------------|----------------|
| 1 | active-backup | None | Failover only |
| 2 | balance-xor | None | Load balancing |
| 4 | 802.3ad (LACP) | **Required** | **Preferred** |

> **Warning:** Other modes (0, 3, 5, 6) are **not supported** for VLAN bridging due to MAC rewrite issues and broadcast storms.

### PXE Considerations

- **Prefer native (untagged) VLAN** for PXE boot
- Tagged PXE is possible on UEFI hardware but more complex
- Configure switch native VLAN to match PXE VLAN where needed

---

## Kubernetes Cluster Planning

### Cluster Sizing

| Cluster Size | Nodes | Pod CIDR | Service CIDR |
|--------------|-------|----------|--------------|
| Small (≤64 nodes) | Up to 64 | 100.64.0.0/18 | 100.64.64.0/18 |
| Medium (≤128 nodes) | Up to 128 | 100.64.0.0/17 | 100.64.128.0/17 |

> Each worker gets a /24 for pods from the Pod CIDR.

### CIDR Planning

**Reference design (64 nodes):**

```yaml
podCIDR: 100.64.0.0/18      # 16,384 pod IPs
serviceCIDR: 100.64.64.0/18  # 16,384 service IPs
```

**Larger clusters (128 nodes):**

```yaml
podCIDR: 100.64.0.0/17      # 32,768 pod IPs
serviceCIDR: 100.64.128.0/17 # 32,768 service IPs
```

### CNI Selection

**Cilium** is recommended for VMO:

| Feature | Configuration |
|---------|---------------|
| Overlay Mode | VXLAN |
| kube-proxy | Replaced by eBPF |
| VMO Compatibility | ✅ Validated |

**MetalLB** for LoadBalancer services:

| Setting | Value |
|---------|-------|
| Mode | L2 or BGP |
| IP Pool | On data VLAN (bond_data) |
| IPVS | Enable `strictARP: true` |

---

## Storage (Portworx + Pure FlashArray)

### Storage Requirements

**Live migration requires RWX:**
- VM live migration **only works with RWX PersistentVolumes**
- Use **RWX Block** for lowest overhead
- **RWO will NOT allow live migration**

### Portworx Configuration

**Key settings:**

| Setting | Value | Purpose |
|---------|-------|---------|
| License | Enterprise | Required for RWX |
| SAN Type | FC (preferred) | Storage connectivity |
| cloudStorage.deviceSpecs | 1 TB per worker | Minimum LUN size |
| maxStorageNodes | # of workers | Fast LUN failover |

**StorageClass for KubeVirt:**

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: px-kubevirt-rwx
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: pxd.portworx.com
parameters:
  io_profile: auto_journal
  priority_io: high
  repl: "2"
  nodiscard: "true"
  sharedv4: "true"          # Enables RWX
  sharedv4_svc_type: "ClusterIP"
```

### FlashArray Integration

**Requirements:**

| Requirement | Details |
|-------------|---------|
| API access | 443/TCP to FlashArray |
| API token | Generated in Pure GUI |
| FC/iSCSI zoning | Completed before install |
| LUN sizing | ≥1 TB per worker |

**Create Portworx secret:**

```bash
kubectl create secret generic px-pure-secret \
  --from-literal=pure_fa_endpoint=<flasharray-ip> \
  --from-literal=pure_fa_api_token=<api-token> \
  -n kube-system
```

> **Note:** The Portworx CSI will auto-provision resources. Do not manually create host entries.

### Upgrade/Repave Considerations

- CAPI repaves replace nodes entirely
- Avoid data rebuild storms by:
  - Keeping worker pools fixed
  - **Not wiping non-OS disks** during repave (MAAS setting)
  - Using `maxStorageNodes` equal to worker count

---

## VMO (KubeVirt) Configuration

### VMO Prerequisites

Before deploying VMO:

| Requirement | Status | Notes |
|-------------|--------|-------|
| Kubernetes cluster deployed | ✅ | Via Palette with MAAS |
| CNI (Cilium) configured | ✅ | Recommended for VMO |
| MetalLB configured | ✅ | For LoadBalancer services |
| **RWX storage available** | ✅ | **Required for live migration** |
| Hardware virtualization enabled | ✅ | VT-x/AMD-V in BIOS |
| br0 bridge on data bond | ✅ | For VM VLAN bridging |

> **⚠️ Live Migration Requires RWX Storage:** VM live migration **only works with RWX (ReadWriteMany) PersistentVolumes**. RWO volumes will NOT allow live migration. Portworx with `sharedv4: true` or similar RWX-capable storage is required.

### Reference Profiles

Spectro Cloud provides **reference profiles** with pre-configured VMO stacks. Contact your Spectro Cloud representative to request access to:

- **VMO Reference Profile** — Complete VMO stack with KubeVirt, CDI, and Dashboard
- **VMO with Portworx** — VMO with Portworx storage for production workloads
- **VMO with Rook-Ceph** — VMO with Rook-Ceph storage

These reference profiles include tested configurations and recommended settings.

### VMO Pack Settings

**Key configurations:**

| Setting | Value | Purpose |
|---------|-------|---------|
| vlanFiltering | true | VLAN isolation on br0 |
| allowedVlans | (e.g., 21-100) | VM VLAN range — customize to your environment |
| accessMode | Proxied or Direct | Dashboard access |

**Access modes:**

| Mode | Description | When to Use | Configuration |
|------|-------------|-------------|---------------|
| **Direct** | VMO dashboard accessed via LoadBalancer IP | Palette can reach cluster LB directly | Set `consoleBaseAddress` to LB IP |
| **Proxied** | VMO dashboard routed through Spectro Proxy | Palette cannot reach cluster directly | Leave `consoleBaseAddress` empty, configure Spectro Proxy |

> **Recommendation:** Use **Direct mode** when possible (simpler, no proxy needed). Only use Proxied mode if Palette cannot reach the cluster's LoadBalancer (e.g., Palette SaaS with on-prem clusters, or isolated networks).

### OIDC Configuration for VMO

VMO requires OIDC for dashboard authentication. Configure this in the **Kubernetes layer** of your cluster profile:

| OIDC IdP Option | Description |
|-----------------|-------------|
| **Palette** | Uses Palette as the OIDC provider — **recommended** |
| **Inherit from Tenant** | Uses the tenant's configured OIDC settings |
| **Custom** | Manually configure OIDC issuer, client ID, etc. |
| **None** | No OIDC — VMO authentication will be disabled |

> **⚠️ Warning:** If you select **None**, VMO will run without authentication (anyone can access the dashboard).

**VMO authentication modes:**

| Auth Mode | When Used | Production Ready? |
|-----------|-----------|-------------------|
| `oidc` | OIDC fully configured | ✅ Yes |
| `disabled` | OIDC not configured | ❌ No — anyone can access |
| `openshift` | OpenShift OAuth | ✅ Yes (OpenShift only) |

### Custom CA Certificate (Self-Hosted Palette)

When using self-hosted Palette with custom/self-signed certificates, VMO must trust the Palette TLS certificate.

**When to configure:**
- Palette uses a self-signed certificate
- Palette uses a certificate from a private/internal CA
- You see `x509: certificate signed by unknown authority` errors

**Step 1: Create the ConfigMap FIRST**

```bash
# Extract CA from Palette (if needed)
openssl s_client -connect <palette-url>:443 -showcerts </dev/null 2>/dev/null | \
  awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/' > palette-ca.crt

# Create ConfigMap in vm-dashboard namespace
kubectl create configmap custom-ca \
  --from-file=cert=palette-ca.crt \
  --namespace vm-dashboard
```

**Step 2: Enable in VMO Pack**

Only after the ConfigMap exists:

```yaml
charts:
  virtual-machine-orchestrator:
    privateCaCertificate:
      enabled: true              # Enable AFTER ConfigMap exists!
      configmapName: custom-ca
      certificateKey: cert
      mountPath: /etc/ssl/certs/
```

**Step 3: Add CA to Cluster Profile (Recommended)**

For MAAS/Ubuntu-based clusters, add the CA certificate to the OS layer:

```yaml
# In the Ubuntu/MAAS layer of cluster profile
additionalTrustBundle: |
  -----BEGIN CERTIFICATE-----
  <your CA certificate content>
  -----END CERTIFICATE-----
```

### VM Networking

**Multus NetworkAttachmentDefinitions:**

Create NADs for each VLAN exposed to VMs:

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

**VLAN configuration:**
- Configure VLAN filtering on br0
- Set allowed VLANs per your environment
- Create NetworkAttachmentDefinitions for each tenant VLAN
- Ensure switch ports trunk required VLANs

### Verifying VMO Deployment

After deploying a cluster with VMO:

```bash
# Check KubeVirt is healthy
kubectl get kubevirt -n kubevirt

# Check VMO pods are running
kubectl get pods -n vm-dashboard

# Check CDI is ready
kubectl get cdi -n cdi

# Verify storage class is RWX-capable
kubectl get sc
```

**Access the VM Dashboard:**
1. In Palette UI, navigate to the cluster
2. Click the **Virtual Machines** tab
3. The VMO dashboard should load in the iframe

> **Self-hosted Palette users:** If the VMO dashboard doesn't load, see the [Self-Hosted Helm Installation Guide](palette-selhhosted-helm-install.md#vmo-gui-issues-on-self-hosted) for GUI troubleshooting (wildcard DNS, CSP, rate limiting).

---

## Pre-Flight Checklist

Complete this checklist **before** starting the [Deployment Workflow](#deployment-workflow).

### 1. Palette Access

- [ ] Palette running (SaaS or self-hosted)
- [ ] Tenant admin access to Palette
- [ ] Palette CLI installed on a Linux workstation

### 2. People & Access

- [ ] MAAS admin available with API token
- [ ] Storage admin (Pure) with LUN provisioning access
- [ ] Network admin available for VLANs, LACP/LAG, BGP/L2

### 3. Hardware (Per Server)

- [ ] Workers: Modern x86-64 CPU, ≥256 GB RAM (min 24 GB)
- [ ] 2×10 GbE NICs (or more) for bonding
- [ ] FC (preferred) or iSCSI HBAs
- [ ] Local OS disk
- [ ] Control plane: 3 nodes, 4-8 vCPU, 8-32 GB RAM

### 4. Networking

- [ ] VLANs defined: PXE, mgmt, data, VM VLANs (IDs per your environment)
- [ ] Host bonds configured (802.3ad preferred)
- [ ] br0 bridge on data bond
- [ ] Switch LACP configured
- [ ] MetalLB IP pool on data VLAN
- [ ] BGP or L2 advertisement mode chosen
- [ ] Pod/Service CIDRs sized for node count

### 5. Storage (Pure + Portworx)

- [ ] Pure FlashArray reachable (443/TCP)
- [ ] API token generated
- [ ] FC/iSCSI zoning complete
- [ ] ≥1 TB LUN per worker allocated
- [ ] Portworx Enterprise license

### 6. MAAS

- [ ] MAAS 3.6.0 installed
- [ ] DHCP/PXE configured
- [ ] Images synced
- [ ] BMC/IPMI configured for all nodes
- [ ] Commissioning passes for all nodes

### 7. VMO (Post-Deployment)

- [ ] VMO pack in cluster profile
- [ ] VLAN filtering enabled on br0
- [ ] Multus NADs created
- [ ] CDI configured for golden images
- [ ] VM templates prepared (Ubuntu, Windows)

---

## Deployment Workflow

Once all prerequisites are met, follow this workflow to deploy VMO on MAAS bare-metal:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        DEPLOYMENT WORKFLOW                                   │
└─────────────────────────────────────────────────────────────────────────────┘

Step 1: Verify MAAS Ready
        │
        ├── Nodes commissioned and in "Ready" state
        ├── DHCP/PXE/DNS configured
        └── BMC/IPMI credentials verified
        │
        ▼
Step 2: Deploy PCG
        │
        ├── Register MAAS cloud account in Palette
        ├── Deploy PCG via Palette CLI
        └── Verify PCG shows "Healthy" in Palette UI
        │
        ▼
Step 3: Create Cluster Profile - Recommended to use Reference Packs
        │
        ├── Base OS layer (Ubuntu, etc.)
        ├── Kubernetes layer (kubeadm)
        ├── CNI layer (Cilium recommended)
        ├── Storage layer (Portworx)
        ├── Load balancer (MetalLB)
        └── VMO pack (KubeVirt + CDI + Multus)
        │
        ▼
Step 4: Deploy Bare-Metal Cluster
        │
        ├── Select machine pool from MAAS
        ├── Configure node counts (3 CP + 4-5 workers)
        ├── Set network configuration (bonds, VLANs)
        └── Deploy and wait for cluster to become healthy
        │
        ▼
Step 5: Configure VMO
        │
        ├── Create NetworkAttachmentDefinitions for VM VLANs
        ├── Configure VLAN filtering on br0
        ├── Import VM images via CDI
        └── Create VM templates
```

### Step 1: Verify MAAS is Ready

Before deploying PCG, confirm MAAS is properly configured:

```bash
# List commissioned machines (should show "Ready" status)
maas $PROFILE machines read | jq '.[] | {hostname, status_name, power_type}'

# Verify DHCP is enabled on the correct subnet
maas $PROFILE subnets read | jq '.[] | {name, cidr, managed}'

# Check BMC connectivity (should return power state)
maas $PROFILE machine power-query <system_id>
```

### Step 2: Deploy PCG

1. **Register MAAS as a Cloud Account in Palette:**
   - Navigate to **Tenant Settings → Cloud Accounts → Add Cloud Account**
   - Select **MAAS**
   - Enter MAAS API endpoint: `http://<maas-ip>:5240/MAAS`
   - Enter MAAS API key (from MAAS UI: User → API Keys)

2. **Deploy PCG:**
   First, install the Palette CLI from the official downloads page:
   - [https://docs.spectrocloud.com/downloads/cli-tools/](https://docs.spectrocloud.com/downloads/cli-tools/)
   
   Then deploy PCG:
   ```bash
   # Deploy PCG (interactive wizard)
   palette pcg install
   ```

3. **Verify PCG Health:**
   - In Palette UI: **Tenant Settings → Private Cloud Gateways**
   - PCG should show **Healthy** status
   - MAAS machines should be visible in cluster deployment wizard

### Step 3: Create Cluster Profile

Create a cluster profile with the required layers for VMO:

| Layer | Pack | Key Settings |
|-------|------|--------------|
| OS | Ubuntu 22.04 | LTS, matches MAAS images |
| Kubernetes | Kubernetes (kubeadm) | Version compatible with VMO |
| Network | Cilium | VXLAN overlay, kube-proxy replacement |
| Load Balancer | MetalLB | L2 or BGP mode, IP pool on data VLAN |
| Storage | Portworx | Enterprise license, FlashArray backend |
| Add-on | VMO | VLAN filtering, allowed VLANs, access mode |

> **Note:** Layer order matters. Add VMO as an add-on pack after core infrastructure is defined.

### Step 4: Deploy Bare-Metal Cluster

1. **Create Cluster** from the cluster profile
2. **Select MAAS Cloud Account** and target PCG
3. **Configure Machine Pools:**
   - Control Plane: 3 nodes, select appropriate machines
   - Worker Pool: 4-5 nodes with VMO hardware requirements
4. **Configure Networking** per your NIC layout (bonds, VLANs)
5. **Deploy** and monitor progress in Palette UI

**Estimated deployment time:** 20-45 minutes depending on node count and network speed.

### Step 5: Configure VMO

After cluster is healthy, complete VMO setup:

1. **Create NetworkAttachmentDefinitions** for VM VLANs (see [VM Networking](#vm-networking))
2. **Import VM images** using CDI DataVolumes
3. **Create VM templates** for common OS types
4. **Test VM deployment** with a simple Linux VM

---

## Troubleshooting

### Node Maintenance & Recovery

#### Putting a Node in Maintenance Mode

Palette's maintenance mode performs a **cordon + drain** on the node AND pauses CAPI reconciliation:

**What maintenance mode does:**
- **Cordon**: Sets `node.spec.unschedulable=true`, preventing new pods from being scheduled
- **Drain**: Evicts existing pods gracefully (respects PodDisruptionBudgets)
- **Pauses CAPI Machine reconciliation**: Has the same effect as adding `cluster.x-k8s.io/paused` annotation to the Machine resource
- **Prevents node restarts**: CAPI health checks won't trigger remediation while in maintenance mode

**Maintenance mode vs manual pause annotation:**
| Capability | Maintenance Mode | `cluster.x-k8s.io/paused` on Machine |
|------------|------------------|-------------------------------------|
| Cordon node | ✅ Yes | ❌ No (manual step) |
| Drain pods | ✅ Yes | ❌ No (manual step) |
| Pause core CAPI | ✅ Yes | ✅ Yes |
| Pause health checks | ✅ Yes | ✅ Yes |
| Pause infra provider (MaasMachine) | ❌ **No** | ❌ **No** |

> **Important:** Both maintenance mode and the `cluster.x-k8s.io/paused` annotation on the Machine **do NOT pause the infrastructure provider** (e.g., `capmaas-controller-manager`). If you release a node in MAAS while in maintenance mode, the MaasMachine controller may still attempt to re-deploy it. See the section on [pausing the infrastructure provider](#️-important-pausing-machine-does-not-pause-the-infrastructure-provider) for how to fully pause all controllers.

#### Understanding CAPI Resource Hierarchy

Before pausing resources, it's important to understand how CAPI manages machines:

```
Cluster                          ← Represents the entire K8s cluster
├── KubeadmControlPlane          ← Manages control plane machines (etcd, API server)
│   └── Machine (CP)             ← Individual control plane node
│       ├── KubeadmConfig        ← Bootstrap config (kubeadm init/join)
│       └── MaasMachine          ← Infrastructure object (MAAS-specific)
│
└── MachineDeployment            ← Manages worker node pool (like Deployment for Pods)
    └── MachineSet               ← Manages replicas (like ReplicaSet)
        └── Machine              ← Individual worker node
            ├── KubeadmConfig    ← Bootstrap config (kubeadm join)
            └── MaasMachine      ← Infrastructure object (MAAS-specific)
```

**Each resource has its own controller:**

| Controller | Namespace | What It Manages | What It Does |
|------------|-----------|-----------------|--------------|
| `capi-controller-manager` | `cluster-<UUID>` | `Machine`, `MachineSet`, `MachineDeployment` | Core lifecycle — creates/deletes Machines, triggers drain, manages finalizers |
| `capi-kubeadm-bootstrap-controller-manager` | `cluster-<UUID>` | `KubeadmConfig` | Generates cloud-init/bootstrap data for kubeadm |
| `capi-kubeadm-control-plane-controller-manager` | `cluster-<UUID>` | `KubeadmControlPlane` | Manages CP scaling, upgrades, etcd health |
| `capmaas-controller-manager` | `capi-webhook-system` | `MaasMachine`, `MaasCluster` | **Infrastructure provider** — talks to MAAS API, allocates/deploys/releases machines |

#### Pausing CAPI Reconciliation (For Manual Interventions)

If you need to make changes to a node without CAPI interference (e.g., debugging, manual repairs), you need to understand which controllers to pause.

**Basic pause (stops core CAPI controllers and health checks):**

```bash
# Find your cluster namespace and machine
kubectl get machines -A | grep <cluster-name>

# Pause reconciliation on a specific machine
kubectl annotate machine <machine-name> -n <cluster-namespace> \
  cluster.x-k8s.io/paused=""

# When done, remove the annotation to resume reconciliation
kubectl annotate machine <machine-name> -n <cluster-namespace> \
  cluster.x-k8s.io/paused-
```

> **⚠️ Annotation syntax:**
> - To **add** an annotation: `cluster.x-k8s.io/paused=""`
> - To **remove** an annotation: `cluster.x-k8s.io/paused-` (note the `-` at the end)
> - ❌ **Wrong:** `cluster.x-k8s.io/paused=false` — This sets the value to "false", it does NOT remove the annotation. The pause check only looks for the **presence** of the key, not the value.

This annotation:
- Stops `capi-controller-manager` from reconciling the Machine
- Prevents MachineHealthCheck from triggering remediation
- Allows you to safely power off the node for maintenance

> **Tip:** You can also skip only health check remediation (while allowing other reconciliation) using:
> ```bash
> kubectl annotate machine <machine-name> -n <cluster-namespace> \
>   cluster.x-k8s.io/skip-remediation=""
> ```

#### ⚠️ Important: Pausing Machine Does NOT Pause the Infrastructure Provider

**The `cluster.x-k8s.io/paused` annotation on the Machine only pauses core CAPI controllers — it does NOT pause the MAAS infrastructure provider (`capmaas-controller-manager`).**

This means if you:
1. Pause the Machine with the annotation
2. Release the node directly in MAAS
3. The `MaasMachine` controller will detect the state change and **attempt to re-deploy** the machine

```
Machine (paused ✅)          MaasMachine (NOT paused ❌)
      │                            │
      ▼                            ▼
capi-controller-manager      capmaas-controller-manager
   (stopped reconciling)        (still reconciling!)
```

**To fully pause ALL CAPI activity including infrastructure provider:**

**Option 1: Pause both Machine AND MaasMachine**
```bash
# Find the MaasMachine name (usually same as Machine name)
kubectl get maasmachine -n <cluster-namespace>

# Pause both resources
kubectl annotate machine <machine-name> -n <cluster-namespace> \
  cluster.x-k8s.io/paused=""
kubectl annotate maasmachine <maasmachine-name> -n <cluster-namespace> \
  cluster.x-k8s.io/paused=""

# When done, remove both annotations
kubectl annotate machine <machine-name> -n <cluster-namespace> \
  cluster.x-k8s.io/paused-
kubectl annotate maasmachine <maasmachine-name> -n <cluster-namespace> \
  cluster.x-k8s.io/paused-
```

**Option 2: Pause the entire cluster**
```bash
# Pause ALL machines in the cluster
kubectl patch cluster <cluster-name> -n <cluster-namespace> \
  --type=merge -p '{"spec":{"paused":true}}'

# Resume when done
kubectl patch cluster <cluster-name> -n <cluster-namespace> \
  --type=merge -p '{"spec":{"paused":false}}'
```

**Summary — What Each Pause Method Affects:**

| Pause Method | Core CAPI | Health Check | Bootstrap | MAAS Provider |
|--------------|-----------|--------------|-----------|---------------|
| `cluster.x-k8s.io/paused` on Machine | ✅ Paused | ✅ Paused | ✅ Paused | ❌ **Still running** |
| `cluster.x-k8s.io/paused` on Machine + MaasMachine | ✅ Paused | ✅ Paused | ✅ Paused | ✅ Paused |
| `cluster.spec.paused=true` | ✅ Paused | ✅ Paused | ✅ Paused | ✅ Paused |
| `cluster.x-k8s.io/skip-remediation` on Machine | ❌ Running | ✅ Paused | ❌ Running | ❌ Running |

#### ⚠️ Never Release a Node in MAAS Without Deleting the Machine Resource

**Problem:** If you "Release" a node directly in MAAS while the CAPI Machine resource still exists, the node will **not come back healthy**.

**Why this happens:**
1. MAAS "Release" returns the bare-metal machine to the available pool and wipes its state
2. The CAPI Machine resource still references the (now-released) MAAS machine
3. CAPI expects to manage a deployed machine, but MAAS has deallocated it
4. The `MaasMachine` infrastructure object becomes orphaned — it references a machine ID that MAAS no longer associates with your cluster
5. Re-deploying the same machine in MAAS creates a new allocation that doesn't match the existing CAPI resources

**Correct approach to remove a problematic node:**

1. **Scale down via Palette UI** (preferred) — reduces node count, Palette handles cleanup
2. **Or delete the Machine resource in CAPI** — this triggers proper cleanup:
   ```bash
   # This will drain the node, delete the MaasMachine, and release in MAAS
   kubectl delete machine <machine-name> -n <cluster-namespace>
   ```
3. **Then** the node is properly released in MAAS and available for re-provisioning

**If you already released in MAAS:**

If you've already released a node in MAAS and the cluster is stuck:

```bash
# 1. Delete the orphaned Machine resource (skip drain since node is gone)
kubectl delete machine <machine-name> -n <cluster-namespace>

# 2. If Machine deletion is stuck, you may need to remove the finalizer
kubectl patch machine <machine-name> -n <cluster-namespace> \
  -p '{"metadata":{"finalizers":[]}}' --type=merge

# 3. Also clean up the MaasMachine if it still exists
kubectl delete maasmachine <maasmachine-name> -n <cluster-namespace>
```

Then scale the cluster back up in Palette to provision a replacement node.

---

### ⚠️ Storage Considerations When Removing Nodes

Releasing or removing a node has significant implications for distributed storage systems. Each storage solution handles node loss differently, and abrupt removal (releasing in MAAS without graceful drain) can cause data loss or extended rebuild times.

#### Impact by Storage Solution

| Storage | Min Nodes | Default Replicas | Node Loss Impact | Recovery | Survive Abrupt Release? | Survive CAPI Repave? |
|---------|-----------|------------------|------------------|----------|------------------------|---------------------|
| **Portworx** | 3 | 2-3 | Quorum at risk if fewer than 3 nodes remain | Auto-rebuild to healthy nodes | ⚠️ Yes, if quorum maintained | ✅ Yes |
| **Longhorn** | 1 | 3 | Volume degraded until replica rebuilt | Auto-rebuild if healthy nodes exist | ⚠️ Yes, but with rebuild storm | ✅ Yes |
| **Rook-Ceph** | 3 | 3 (OSD) | MON/OSD quorum at risk | Ceph rebalance (slow) | ⚠️ Yes, if quorum maintained | ✅ Yes |
| **Piraeus (LINSTOR)** | 1 | 2-3 | DRBD out-of-sync | **Manual** pool rebuild required | ⚠️ Yes, DRBD handles split | ❌ **No** — manual intervention |

#### Portworx

**Quorum:** Portworx requires **minimum 3 storage nodes** online for its internal kvdb (etcd-based). Losing a node temporarily is survivable, but losing 2+ nodes risks quorum loss.

**Node removal impact:**
- **Graceful removal (via CAPI/drain):** Portworx detects the drain, migrates data to other nodes, and decommissions cleanly
- **Abrupt release:** Portworx marks node as offline, begins rebuilding replicas to remaining nodes (can cause I/O storm)
- **Data safety:** Volumes with `repl: 2` or higher survive single node loss; `repl: 1` volumes lose data

**Best practice:**
```bash
# Before removing a node, enter Portworx maintenance mode
pxctl service maintenance --enter

# After returning the node
pxctl service maintenance --exit
```

**MAAS-specific:** Configure `maxStorageNodes = #workers` and **do not wipe non-OS disks** during repave to preserve Portworx pools.

#### Longhorn

**Architecture:** Longhorn uses per-volume replicas distributed across nodes. Default is 3 replicas.

**Node removal impact:**
- **Graceful removal:** Longhorn detects cordon/drain, rebuilds replicas to other nodes before removal
- **Abrupt release:** Longhorn marks replicas on the missing node as failed, begins auto-salvage and rebuild
- **Data safety:** Volumes survive if at least 1 healthy replica exists on another node

**Key settings that affect recovery:**
- `defaultSettings.replicaReplenishmentWaitInterval` — seconds before rebuilding (default: 600)
- `defaultSettings.replicaAutoBalance` — automatically rebalances replicas
- `defaultSettings.autoSalvage` — auto-recovers volumes when replicas become faulty
- `defaultSettings.nodeDownPodDeletionPolicy` — controls pod behavior when node fails

**Risk:** If you release a node with the **only replica** of a volume, data is **permanently lost**.

#### Rook-Ceph

**Quorum:** Ceph requires odd number of MONs (monitors) — typically 3. OSD (storage daemons) run on each storage node.

**Node removal impact:**
- **Graceful removal:** Set OSD `noout` flag, drain node, Ceph rebalances safely
- **Abrupt release:** Ceph detects OSD as down, waits ~5 minutes, then starts rebalancing PGs (placement groups)
- **Data safety:** Ceph survives if pool `min_size` replicas remain (default: 2 of 3)

**Best practice before removing a node:**
```bash
# Prevent Ceph from rebalancing during maintenance
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd set noout
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd set norebalance

# After returning the node
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd unset noout
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd unset norebalance
```

**Risk:** Removing a MON node without replacement can break quorum. Never remove more than (n-1)/2 MONs at once.

#### Piraeus (LINSTOR/DRBD)

**Architecture:** DRBD provides synchronous block replication. LINSTOR manages resource placement.

> **⚠️ CAPI Repave Limitation:** Piraeus/LINSTOR does **NOT support automatic pool rebuilding or rebalancing** when nodes are replaced via CAPI repave. Unlike Portworx, Longhorn, or Rook-Ceph, Piraeus cannot automatically recreate storage pools on a replacement node. This is a known limitation with an open enhancement request.

**Node removal impact:**
- **Graceful removal:** LINSTOR can migrate resources, but does NOT auto-rebuild pools
- **Abrupt release:** DRBD marks the missing node's replicas as "Outdated", remaining replicas continue serving
- **CAPI repave:** When CAPI replaces a node, the new node has a **different hostname and no storage pool** — Piraeus will NOT automatically recreate the pool or rebalance data
- **Data safety:** DRBD is designed for split-brain scenarios; data is safe if at least one in-sync replica exists

**Key limitations (compared to other storage solutions):**

| Feature | Piraeus | Portworx | Longhorn | Rook-Ceph |
|---------|---------|----------|----------|-----------|
| Auto pool rebuild on new node | ❌ **No** | ✅ Yes | ✅ Yes | ✅ Yes |
| Auto rebalance after node replace | ❌ **No** | ✅ Yes | ✅ Yes | ✅ Yes |
| Survive CAPI repave | ⚠️ **Manual intervention required** | ✅ Yes | ✅ Yes | ✅ Yes |
| Local disk dependency | ✅ Yes | ⚠️ Configurable | ✅ Yes | ✅ Yes |

**Why Piraeus struggles with CAPI repave:**
1. Piraeus/LINSTOR uses local disk storage pools (LVM) tied to the **node hostname**
2. CAPI repave replaces the node entirely — new hostname, new machine ID
3. LINSTOR sees this as a completely new node, not a replacement
4. Storage pools must be **manually recreated** on the new node
5. Resources/replicas must be **manually migrated or recreated**

**Workaround for CAPI environments:**

If using Piraeus with CAPI-managed clusters:
1. **Avoid repaving storage nodes** — use maintenance mode instead of full repave
2. **Manual pool recreation required:**
   ```bash
   # On the new node, recreate the storage pool
   linstor physical-storage create-device-pool --pool-name lvm-thin LVM_THIN /dev/sdb --storage-pool lvm-thin
   
   # Register the new node's storage pool
   linstor storage-pool create lvmthin <new-node-name> lvm-thin drbd-vg/thinpool
   
   # Manually trigger resource rebalancing
   linstor resource-group spawn <resource-group> <volume-number>
   ```
3. **Consider alternative storage** for CAPI-managed bare-metal clusters where repaves are expected

**Best practice:**
```bash
# Check resource status before removing node
linstor resource list -n <node-name>

# List storage pools to see node dependencies
linstor storage-pool list

# Delete resources from node gracefully (MANUAL step)
linstor node delete <node-name>
```

> **Recommendation:** For bare-metal clusters managed by CAPI/Palette where node repaves are expected, consider using **Portworx, Longhorn, or Rook-Ceph** instead of Piraeus, as they support automatic pool rebuilding and rebalancing.

#### Recommendations for All Storage Solutions

1. **Always use maintenance mode or cordon/drain** before removing nodes
2. **Wait for data replication** to complete before removing additional nodes
3. **Never remove multiple nodes simultaneously** if they hold replicas of the same volumes
4. **Monitor storage health** during node operations:
   - Portworx: `pxctl status`, `pxctl cluster list`
   - Longhorn: Longhorn UI or `kubectl get volumes -n longhorn-system`
   - Rook-Ceph: `ceph status`, `ceph osd tree`
   - Piraeus: `linstor resource list`, `linstor node list`

5. **For MAAS bare-metal specifically:**
   - Configure MAAS to **not wipe non-OS disks** on release
   - Use the same machine for re-provisioning when possible (preserves local storage pools)
   - Allow sufficient time for storage rebuild before next maintenance operation

---

### MAAS Issues

| Symptom | Cause | Fix |
|---------|-------|-----|
| PXE boot fails | DHCP/TFTP blocked | Check ports 67-69, 5248 |
| Commission fails | BMC unreachable | Verify IPMI/Redfish access |
| Node stuck in "Deploying" | Image download failed | Check HTTP proxy, image sync |
| Node won't rejoin after MAAS release | Machine resource orphaned | Delete Machine in CAPI, then scale up |

### PCG Issues

| Symptom | Cause | Fix |
|---------|-------|-----|
| "invalid character 'N'" error | HTTPS vs HTTP mismatch | Use `http://` for MAAS URL |
| PCG can't reach MAAS | Firewall blocking 5240 | Allow outbound to MAAS |
| Cluster provisioning stuck | PCG ↔ node SSH failed | Check port 22 access |

### VMO Issues

| Symptom | Cause | Fix |
|---------|-------|-----|
| VMs won't start | No KVM module | Enable VT-x/AMD-V in BIOS |
| Live migration fails | RWO volumes | Use RWX storage class |
| VM network unreachable | VLAN not trunked | Configure switch ports |
| Dashboard not loading | Wildcard DNS missing | Add `*.palette.example.com` |

### Storage Issues

| Symptom | Cause | Fix |
|---------|-------|-----|
| Portworx pods failing | FlashArray unreachable | Check 443/TCP to array |
| PVC stuck Pending | No storage nodes | Verify Portworx cluster health |
| Poor I/O performance | Wrong storage class | Use `io_profile: auto_journal` |

---

## References

- [Spectro Cloud Documentation](https://docs.spectrocloud.com/)
- [VMO Reference Architecture](https://www.spectrocloud.com/resources/collateral/vmo-architecture-pdf)
- [MAAS Integration](https://docs.spectrocloud.com/clusters/data-center/maas/)
- [MAAS Architecture](https://docs.spectrocloud.com/clusters/data-center/maas/architecture/)
- [PCG Deployment](https://docs.spectrocloud.com/clusters/pcg/)
- [PCG Sizing](https://docs.spectrocloud.com/clusters/pcg/deploy-pcg/#pcg-sizing)
- [Self-Hosted Installation](https://docs.spectrocloud.com/enterprise-version/)
- [Air-gapped Installation](https://docs.spectrocloud.com/enterprise-version/install-palette/)
