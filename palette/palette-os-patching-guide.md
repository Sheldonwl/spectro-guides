# Palette On-Demand OS Patching Guide

This guide explains how to use Palette's **On-Demand OS Patching** feature to apply security updates to cluster nodes, troubleshoot common issues, and perform manual patching when needed.

## Overview

Palette's **On-Demand OS Patching** allows you to trigger security updates on cluster nodes directly from the Palette UI. Instead of manually accessing each node via SSH, you can initiate patching with a single click.

The patching process:

- Applies **security updates only** (not full OS upgrades)
- **Preserves Kubernetes versions** (kubelet, kubeadm, kubectl are held)
- Processes nodes **sequentially** to maintain cluster availability
- **Reboots nodes** only when kernel updates require it

## How On-Demand Patching Works

When you trigger an on-demand OS patch from the Palette UI:

1. **Palette schedules the patch** for a future time (typically 10 minutes)
2. **Each node is processed sequentially** - one at a time
3. **For each node:**
   - A patching job runs in a privileged container
   - Security updates are downloaded and installed
   - If a reboot is required (kernel updates), the node reboots
   - The node is marked as patched
4. **Palette updates the cluster status** when all nodes complete

```
┌─────────────────────────────────────────────────────────────────────────┐
│                      On-Demand OS Patching Flow                         │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│   Palette UI                                                            │
│   On-Demand    ───▶  Schedule Patch  ───▶  Process Nodes Sequentially   │
│     Update                                                              │
│                                                                         │
│                              For Each Node:                             │
│                              ┌────────────────────────────────────────┐ │
│                              │  1. Run patching container             │ │
│                              │  2. Apply security updates             │ │
│                              │  3. Reboot if required                 │ │
│                              │  4. Mark node as patched               │ │
│                              └────────────────────────────────────────┘ │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

## Using On-Demand Patching

### Prerequisites

- Cluster must be in a healthy state
- Nodes must have network access to OS package repositories (e.g., Ubuntu security mirrors)
- Sufficient disk space for package downloads

### Triggering an On-Demand Patch

1. Navigate to **Clusters** in Palette
2. Select your cluster
3. Click **Settings** → **On-Demand Update**
4. Confirm the action

The patch will be scheduled and begin processing within approximately 10 minutes.

### Monitoring Progress

**In the Palette UI:**
- Check the **Nodes** tab for individual node status
- Nodes will show patching status during the process
- After completion, the last patch timestamp is updated

**Via kubectl** (on the target cluster):

| What to Check | Command |
|---------------|---------|
| Patching task status | `kubectl get spectrosystemtask -n os-patch` |
| Active patching jobs | `kubectl get jobs -n os-patch` |
| Job details for a node | `kubectl describe job apply-on-demand-os-patch-on-<node-name> -n os-patch` |
| Patching logs | `kubectl logs -n os-patch -l app.kubernetes.io/name=crony` |
| Node patch status | `kubectl get nodes -o yaml \| grep -A3 spectronodetask` |
| Which nodes are marked patched | `kubectl get nodes --show-labels \| grep task.cluster.spectrocloud.com` |

**Understanding the output:**

- **SpectroSystemTask** - Shows the overall patch request and its state
- **Jobs** - One job per node being patched; check for Running/Succeeded/Failed
- **Node annotations** - Show patch status, timestamp, and any error messages

## Troubleshooting

### Nothing Happens After Clicking On-Demand Update

**Symptoms:** You click On-Demand Update, but no patching activity occurs.

**Possible causes:**

| Cause | Solution |
|-------|----------|
| Previous patch still in progress | Wait for current patch to complete |
| Timestamp stuck in the past | Clear the timestamp and retry (see below) |
| Nodes already marked as patched | Reset the patch tracking labels (see below) |
| Cluster agent issues | Check cluster health and agent connectivity |
| No matching nodes | Check that nodes have the required OS labels |

### Why On-Demand Update Gets "Stuck" (Common Issue)

This is a common issue that occurs after your first successful patch.

**How it works:**

1. When you click On-Demand Update, Palette schedules patching for ~10 minutes in the future
2. After patching completes, that scheduled time is now **in the past**
3. The old timestamp remains stored in the cluster configuration
4. When you click On-Demand Update again, the system may not register a new timer because the old timestamp still exists
5. The API rejects past timestamps, so nothing happens

**Why just clicking On-Demand Update again doesn't work:**

Even though you're clicking the menu option again, the old timestamp value is still stored in the database. The system sees this old (past) timestamp and doesn't properly register a new patch timer.

**The fix - Clear the timestamp first:**

You need to clear the old `onDemandPatchAfter` timestamp before triggering a new update.

#### Option A: Use the Palette API (Recommended)

```bash
# Get your cluster UID and project UID from the Palette URL when viewing the cluster
# Example: https://palette.example.com/admin/project/abc123/clusters/def456/overview
#          Project UID: abc123
#          Cluster UID: def456

CLUSTER_UID="your-cluster-uid"
PROJECT_UID="your-project-uid"
PALETTE_URL="https://your-palette.example.com"
API_KEY="your-api-key"  # The raw API key from Palette (Tenant Settings → API Keys)

# Clear the onDemandPatchAfter field
curl -X PATCH "$PALETTE_URL/v1/spectroclusters/$CLUSTER_UID/clusterConfig/osPatch" \
  -H "ApiKey: $API_KEY" \
  -H "ProjectUid: $PROJECT_UID" \
  -H "Content-Type: application/json" \
  -d '{"onDemandPatchAfter":""}'
```

> **Note:** 
> - The API key header is `ApiKey:` not `Authorization:`
> - The **ProjectUid header is required** for project-scoped clusters
> - Generate an API key in Palette under **Tenant Settings** → **API Keys**
> - The API key must have `cluster.update` permission (Cluster Admin or higher role)

#### Option B: Edit SpectroCluster Resource via kubectl

This requires kubectl access to the **Palette management cluster** (not the target cluster).

```bash
# Find the SpectroCluster resource for your cluster
kubectl get spectrocluster -A | grep <your-cluster-name>

# Edit it
kubectl edit spectrocluster <name> -n <namespace>

# Look for this section and REMOVE the onDemandPatchAfter line:
#   machineManagementConfig:
#     osPatchConfig:
#       onDemandPatchAfter: "2026-01-08T17:32:08Z"  ← DELETE THIS LINE
#       rebootIfRequired: true
```

#### After Clearing

1. Go to **Settings** → **On-Demand Update** in the Palette UI
2. Click to trigger a new patch
3. A new future timestamp will be set (~10 minutes ahead)

#### Verify the Fix

```bash
# Check the SpectroCluster resource to see the new timestamp
kubectl get spectrocluster <name> -n <namespace> -o yaml | grep -A5 osPatchConfig
```

You should see a new `onDemandPatchAfter` time that is in the future.

### Understanding How Patching Tracks Nodes

Palette uses a **label-based tracking system** to know which nodes have been patched:

1. When you trigger On-Demand Update, Palette creates a **patching task** with a unique version hash
2. The system selects nodes that **don't have** this hash in their labels
3. After successfully patching a node, a label is applied marking it as "patched with this version"
4. Nodes with the current hash are **skipped** in future patch runs

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         Node Selection Logic                             │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│   Patch Task Created (version hash: abc123)                              │
│                    │                                                     │
│                    ▼                                                     │
│   ┌────────────────────────────────────────────────────────────────┐    │
│   │  Select nodes WHERE:                                            │    │
│   │    • OS label exists (Linux nodes)                              │    │
│   │    • Task label ≠ "abc123" (not already patched)                │    │
│   │    • Task label ≠ "disabled" (not excluded)                     │    │
│   └────────────────────────────────────────────────────────────────┘    │
│                    │                                                     │
│                    ▼                                                     │
│   Matching nodes are queued for patching (one at a time)                 │
│                    │                                                     │
│                    ▼                                                     │
│   After success: Node gets label with task hash                          │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

**This is why:**
- Running On-Demand Update twice in a row does nothing (nodes already marked)
- New nodes added to the cluster will be patched (they don't have the marker)
- You may need to reset markers to re-patch nodes

### Resetting the Patch State

If you need to **re-run patching on nodes that were already patched**, you must reset the tracking markers.

**When to reset:**
- Patching completed but you want to run it again
- A patch run was interrupted and nodes are in an inconsistent state
- Testing patching behavior

**How to reset:**

1. **Remove the patch tracking labels from nodes**
   - Each patched node has a label like `task.cluster.spectrocloud.com/on-demand-os-patch=<hash>`
   - Removing this label makes nodes eligible for patching again
   - Use kubectl on the target cluster to remove labels from all nodes

2. **Clear the stuck timestamp** (if On-Demand Update isn't working)
   - Use the Palette API or edit the SpectroCluster resource to clear the `onDemandPatchAfter` field

3. **Trigger a new patch**
   - Go to **Settings** → **On-Demand Update**
   - This creates a new patch task with a new version hash
   - Nodes without the matching label will be selected for patching

### Patching Jobs and Status

For each node being patched, Palette creates a **Kubernetes Job** in the `os-patch` namespace:

| Component | Purpose |
|-----------|---------|
| **SpectroSystemTask** | Defines what should happen (patch OS) and which nodes |
| **Job** | One per node - runs the actual patching container |
| **Pod** | The patching container that runs on the target node |

**Job naming:** `apply-on-demand-os-patch-on-<node-name>`

**Checking patch status:**

1. Look at Jobs in the `os-patch` namespace
2. Check Job completion status (Succeeded, Failed, Running)
3. View Job logs for detailed patching output

**Common Job states:**

| State | Meaning |
|-------|---------|
| **Running** | Patching in progress on that node |
| **Succeeded** | Node was patched successfully |
| **Failed** | Patching encountered an error |
| **Pending** | Waiting for resources or scheduling |

### Patching Seems Stuck

**Symptoms:** Patching started but a node has been processing for an extended time.

**Check:**
- Node connectivity - can the node reach package repositories?
- Disk space - is there sufficient space for downloads?
- Package lock - is another apt/yum process running?
- Job status - is the patching Job running or stuck?

### Patching Fails with GPG Keyserver Errors

**Symptoms:** Patching fails with errors like:

```
gpg: keyserver receive failed: End of file
```

**Root Cause:** This occurs in network-restricted environments (DR sites, air-gapped networks, environments with strict firewall rules) where nodes cannot reach external GPG keyservers.

The patching script attempts to fetch GPG signing keys from `keyserver.ubuntu.com` before updating packages. In restricted networks, this connection fails.

**Important:** On most modern Palette clusters, these keys are **not actually required** because:
- Kubernetes packages are pre-installed in the node image
- No external Kubernetes apt repository is configured
- The key fetch is legacy code that should be skipped

**Diagnosis:**

SSH to a node and check:
1. Does `/etc/apt/sources.list.d/kubernetes.list` exist? (Often it doesn't)
2. Run `apt-cache policy kubelet` - if the source is `/var/lib/dpkg/status`, packages are pre-installed

**Solutions:**

| Option | When to Use |
|--------|-------------|
| **Use manual patching script** | Immediate fix - bypass the issue entirely |
| **Modify the patching script** | Permanent fix for the cluster |
| **Open firewall for keyservers** | If network policy allows (ports 11371, 443, 80 to keyserver.ubuntu.com) |

See the [Manual OS Patching](#manual-os-patching) section below for the recommended workaround.

### Node Fails to Rejoin After Reboot

**Symptoms:** A node reboots for kernel updates but doesn't rejoin the cluster.

**Check:**
- Node boot status (via infrastructure provider console)
- kubelet service status
- Network connectivity

## Manual OS Patching

When Palette's automated patching fails or isn't suitable, you can patch nodes manually. This is useful for:

- Network-restricted environments with keyserver issues
- Emergency patching requirements
- Debugging patching failures

### Before Manual Patching

1. **Put the node in maintenance mode** (recommended):
   - In Palette UI: Select the node → **⋮** menu → **Enter Maintenance Mode**
   - This cordons the node and drains workloads safely

2. **Wait for workloads to evacuate:**
   - VMs (if using VMO) will live-migrate to other nodes
   - Pods will be rescheduled

3. **Verify the node is drained** before proceeding

### Manual Patching Script

Use this script to patch nodes directly via SSH. It works in restricted networks (no keyserver access required).

> **Designed for restricted networks:** This script does NOT require keyserver access or external connectivity beyond your package repositories.

**Save as `manual-os-patch.sh` and run with `sudo bash manual-os-patch.sh`**

```bash
#!/bin/bash
#
# manual-os-patch.sh - Run OS security patches directly on a node
#
# Usage: sudo bash manual-os-patch.sh [--reboot]
#
# This script does the same thing as Palette's OS patching but runs directly
# on the node without Kubernetes.
#
# ADVANTAGES OVER PALETTE'S BUILT-IN SCRIPT:
#   - Does NOT require keyserver access (works in restricted networks)
#   - Does NOT require Kubernetes API access
#   - Can be run via SSH when Palette automation fails
#
# IMPORTANT: This only patches the OS - it does NOT:
#   - Cordon/uncordon the node
#   - Update Palette annotations
#   - Drain workloads
#
# You should manually drain the node before running if you want safe patching:
#   kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data
#

set -e

# ============================================================================
# Configuration
# ============================================================================

REBOOT_IF_REQUIRED=false
LOG_FILE="/var/log/manual-os-patch.log"

# Parse arguments
if [[ "$1" == "--reboot" ]]; then
    REBOOT_IF_REQUIRED=true
fi

# ============================================================================
# Functions
# ============================================================================

log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

handle_error() {
    log_message "ERROR: $1"
    exit 1
}

retry_command() {
    local cmd="$1"
    local max_retries=5
    local delay=30
    local retry=0
    
    while [ $retry -lt $max_retries ]; do
        if eval "$cmd"; then
            return 0
        fi
        retry=$((retry + 1))
        log_message "Command failed, retrying ($retry/$max_retries)..."
        sleep $delay
    done
    return 1
}

# ============================================================================
# Pre-flight Checks
# ============================================================================

log_message "=========================================="
log_message "Starting Manual OS Patching"
log_message "=========================================="

# Must be root
if [[ $EUID -ne 0 ]]; then
    handle_error "This script must be run as root (use sudo)"
fi

# Detect OS
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_FAMILY=$ID
    OS_VERSION=$VERSION_ID
else
    handle_error "Could not detect OS family (/etc/os-release not found)"
fi

log_message "Detected OS: $OS_FAMILY $OS_VERSION"
log_message "Reboot if required: $REBOOT_IF_REQUIRED"

# ============================================================================
# Ubuntu/Debian Patching
# ============================================================================

if [[ "$OS_FAMILY" == "ubuntu" || "$OS_FAMILY" == "debian" ]]; then
    log_message "Processing Ubuntu/Debian system..."
    
    # Set non-interactive mode
    export DEBIAN_FRONTEND=noninteractive
    
    # CRITICAL: Hold Kubernetes packages - do NOT upgrade these!
    log_message "Holding Kubernetes packages..."
    apt-mark hold kubeadm kubectl kubelet kubernetes-cni 2>/dev/null || true
    
    # Remove kubernetes apt source if it exists (prevents K8s upgrades)
    if [ -f /etc/apt/sources.list.d/kubernetes.list ]; then
        log_message "Temporarily removing kubernetes.list..."
        mv /etc/apt/sources.list.d/kubernetes.list /etc/apt/sources.list.d/kubernetes.list.bak
    fi
    
    # Create security-only sources list
    log_message "Creating security-only sources list..."
    grep -i security /etc/apt/sources.list > /etc/apt/security.sources.list || true
    
    # If no security sources found, warn but continue
    if [ ! -s /etc/apt/security.sources.list ]; then
        log_message "WARNING: No security sources found, will use all sources"
        cp /etc/apt/sources.list /etc/apt/security.sources.list
    fi
    
    # Wait for any existing apt locks
    log_message "Waiting for apt locks..."
    while fuser /var/lib/dpkg/lock >/dev/null 2>&1 || \
          fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || \
          fuser /var/cache/apt/archives/lock >/dev/null 2>&1; do
        log_message "Waiting for other apt process to finish..."
        sleep 5
    done
    
    # Update apt cache
    log_message "Updating apt cache..."
    retry_command "apt-get update -o Dir::Etc::SourceList=/etc/apt/security.sources.list"
    
    # Show what would be upgraded
    log_message "Packages that will be upgraded:"
    apt-get -s upgrade -o Dir::Etc::SourceList=/etc/apt/security.sources.list 2>&1 | grep "^Inst" || true
    
    # Perform the upgrade
    log_message "Installing security updates..."
    retry_command "apt-get -y \
        -o Dpkg::Options::='--force-confdef' \
        -o Dpkg::Options::='--force-confold' \
        upgrade -o Dir::Etc::SourceList=/etc/apt/security.sources.list"
    
    # Restore kubernetes.list if we moved it
    if [ -f /etc/apt/sources.list.d/kubernetes.list.bak ]; then
        log_message "Restoring kubernetes.list..."
        mv /etc/apt/sources.list.d/kubernetes.list.bak /etc/apt/sources.list.d/kubernetes.list
    fi
    
    # Check if reboot is required
    if [ -f /var/run/reboot-required ]; then
        log_message "REBOOT REQUIRED: /var/run/reboot-required exists"
        cat /var/run/reboot-required.pkgs 2>/dev/null || true
        
        if [ "$REBOOT_IF_REQUIRED" = "true" ]; then
            log_message "Rebooting in 10 seconds..."
            sleep 10
            reboot
        else
            log_message "Reboot required but --reboot not specified. Please reboot manually."
        fi
    else
        log_message "No reboot required."
    fi

# ============================================================================
# RHEL/CentOS/Rocky Patching
# ============================================================================

elif [[ "$OS_FAMILY" == "centos" || "$OS_FAMILY" == "rhel" || "$OS_FAMILY" == "rocky" ]]; then
    log_message "Processing RHEL/CentOS/Rocky system..."
    
    # Exclude kubernetes packages
    EXCLUDE_PKGS="kubeadm,kubectl,kubelet,kubernetes-cni"
    
    # Check for security updates
    log_message "Checking for security updates..."
    yum updateinfo list security --exclude=$EXCLUDE_PKGS 2>&1 || true
    
    # Install security updates
    log_message "Installing security updates..."
    retry_command "yum update -y --security --exclude=$EXCLUDE_PKGS"
    
    # Check if reboot is required
    if command -v needs-restarting &> /dev/null; then
        if needs-restarting -r &> /dev/null; then
            log_message "No reboot required."
        else
            log_message "REBOOT REQUIRED"
            if [ "$REBOOT_IF_REQUIRED" = "true" ]; then
                log_message "Rebooting in 10 seconds..."
                sleep 10
                reboot
            else
                log_message "Reboot required but --reboot not specified. Please reboot manually."
            fi
        fi
    fi

else
    handle_error "Unsupported OS family: $OS_FAMILY"
fi

# ============================================================================
# Completion
# ============================================================================

log_message "=========================================="
log_message "OS Patching completed successfully"
log_message "=========================================="
log_message "Log file: $LOG_FILE"
```

### How to Use the Script

**Step 1: Drain the node first (recommended)**

```bash
# From a machine with kubectl access
NODE_NAME="your-node-name"
kubectl cordon $NODE_NAME
kubectl drain $NODE_NAME --ignore-daemonsets --delete-emptydir-data --grace-period=60
```

**Step 2: Copy and run the script on the node**

```bash
# Copy the script to the node
scp manual-os-patch.sh user@node:/tmp/

# SSH and run
ssh user@node
sudo bash /tmp/manual-os-patch.sh

# Or with automatic reboot:
sudo bash /tmp/manual-os-patch.sh --reboot
```

**Step 3: Uncordon the node after patching**

```bash
kubectl uncordon $NODE_NAME
```

### After Manual Patching

1. **Exit maintenance mode:**
   - In Palette UI: Select the node → **⋮** menu → **Exit Maintenance Mode**
   - Or the node will automatically uncordon after patching

2. **Verify node status:**
   - Node should show as Ready in the cluster
   - Workloads should be able to schedule on the node

3. **Proceed to next node** if patching multiple nodes (one at a time)

## Best Practices

### General Recommendations

| Practice | Reason |
|----------|--------|
| **Patch during maintenance windows** | Minimize impact on workloads |
| **Patch one node at a time** | Maintain cluster availability |
| **Verify cluster health before patching** | Ensure clean starting state |
| **Test in non-production first** | Validate patching behavior |

### For Network-Restricted Environments

| Practice | Reason |
|----------|--------|
| **Use manual patching** | Avoids keyserver connectivity issues |
| **Configure internal package mirrors** | Ensures nodes can fetch updates |
| **Pre-test network connectivity** | Identify issues before patching |

### For VMO (KubeVirt) Clusters

| Practice | Reason |
|----------|--------|
| **Use maintenance mode** | Triggers VM live migration |
| **Ensure RWX storage for VMs** | Required for live migration |
| **Allow sufficient drain time** | VMs take longer to migrate than pods |

## Frequently Asked Questions

### Does OS patching upgrade Kubernetes?

No. Kubernetes packages (kubelet, kubeadm, kubectl) are explicitly held/excluded during patching. Only OS-level security updates are applied.

### Will patching cause downtime?

Nodes are patched sequentially, so workloads are rescheduled to other nodes during each node's patch cycle. Clusters remain available, though individual workloads may experience brief interruption during rescheduling.

### How often should I patch?

Follow your organization's security policy. Many organizations patch monthly or when critical security updates are released.

### What if a node won't reboot?

If a node fails to reboot or rejoin:
1. Check the node via your infrastructure provider's console
2. Verify network connectivity
3. Check kubelet service status
4. If unrecoverable, the node may need to be replaced

### Can I patch specific nodes only?

Palette's on-demand patching applies to all nodes in the cluster. For selective patching, use the manual patching approach on specific nodes.

### What packages are updated?

Only packages from security repositories are updated. This typically includes:
- Kernel security patches
- OpenSSL/cryptographic library updates
- System utility security fixes
- Other CVE-related patches

### How do I know if patching worked?

After patching completes:
- Check node status in Palette UI
- SSH to node and verify package versions
- Check `/var/log/` for patching logs

---

## Related Documentation

- Cluster Management
- Node Maintenance Mode
- VMO and KubeVirt Operations
- Network Requirements
