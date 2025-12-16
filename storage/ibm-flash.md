# IBM FlashSystem Storage for Kubernetes and KubeVirt

This guide covers setting up IBM FlashSystem 7300 and 9000 series storage arrays for Kubernetes and KubeVirt workloads using the IBM Block CSI Driver.

## Table of Contents

- [Overview](#overview)
- [Supported Storage Systems](#supported-storage-systems)
- [Prerequisites](#prerequisites)
- [IBM Block CSI Driver Installation](#ibm-block-csi-driver-installation)
- [Configuration](#configuration)
- [Creating PersistentVolumeClaims (PVCs)](#creating-persistentvolumeclaims-pvcs)
- [How RWX Block Storage Works](#how-rwx-block-storage-works)
- [KubeVirt Integration](#kubevirt-integration)
- [Testing and Validation](#testing-and-validation)
- [Limitations and Considerations](#limitations-and-considerations)
- [Troubleshooting](#troubleshooting)

---

## Overview

The IBM Block CSI Driver enables Kubernetes to manage persistent storage on IBM FlashSystem arrays. As of **version 1.13.0** (latest GA release), the driver supports:

- Dynamic volume provisioning
- Volume snapshots and clones
- Volume expansion
- Raw block volumes
- **RWX (ReadWriteMany) block storage** (added in v1.12.0) - critical for KubeVirt live migration
- Fibre Channel (FC) and iSCSI connectivity
- NVMe/FC connectivity

### Key Version Information

| Version | Release Date | Key Features | Source |
|---------|--------------|--------------|--------|
| 1.13.0 | 2024 | Latest GA, stability improvements | [GitHub Releases](https://github.com/IBM/ibm-block-csi-driver/releases) |
| 1.12.0 | Oct 2024 | **RWX block storage support for KubeVirt** | [IBM Ideas Portal SCSI-I-1255](https://ibm-sys-storage.ideas.ibm.com/ideas/SCSI-I-1255) |
| 1.11.x | 2024 | Volume group snapshots | [GitHub Releases](https://github.com/IBM/ibm-block-csi-driver/releases) |

---

## Supported Storage Systems

### FlashSystem 7300 Series
- Entry to mid-range enterprise storage
- Supports FC, iSCSI connectivity
- NVMe-oF support
- IBM FlashCore Modules with hardware compression

### FlashSystem 9000 Series (9200, 9500)
- High-end enterprise storage
- IBM FlashCore Modules with hardware compression
- Supports FC, iSCSI, NVMe/FC
- AI-powered storage tiering (Easy Tier)

### Other Supported Systems
- IBM Storage Virtualize family
- IBM SAN Volume Controller (SVC)
- IBM FlashSystem 5000 series
- IBM DS8000 series

> **Source**: [IBM FlashSystem 7300](https://www.ibm.com/products/flashsystem-7300), [IBM FlashSystem 9500](https://www.ibm.com/products/flashsystem-9500)

---

## Prerequisites

### Storage Array Requirements

1. **Firmware Version**: Ensure your FlashSystem is running a supported firmware version
   - FlashSystem 7300: v8.5.x or later recommended
   - FlashSystem 9500: v8.6.x or later recommended

2. **Storage Pools**: Create storage pools for Kubernetes volumes
   ```
   # Example: Create a pool named 'k8s-pool' via CLI
   svctask mkmdiskgrp -name k8s-pool -ext 1024 -mdisk mdisk0
   ```

3. **Host Connectivity**:
   - **iSCSI**: Configure iSCSI portals and ensure network connectivity
   - **Fibre Channel**: Zone the FC switches appropriately
   - **NVMe/FC**: Configure NVMe namespaces if using NVMe

4. **User Account**: Create a dedicated user for CSI driver operations
   ```
   # Create user with appropriate permissions
   svctask mkuser -name csi-user -usergrp Administrator
   ```

### Kubernetes Node Requirements

1. **Kubernetes Version**: 1.25 or later recommended

2. **Connectivity** (choose ONE - FC or iSCSI, not both):

   **Option A: Fibre Channel** (recommended for production)
   - Ensure FC HBAs are installed and configured
   - Verify WWPNs are visible: `cat /sys/class/fc_host/host*/port_name`
   - No additional software required beyond FC HBA drivers

   **Option B: iSCSI**
   ```bash
   # Install iSCSI initiator (Ubuntu/Debian)
   apt install open-iscsi -y
   
   # For RHEL/CentOS/Rocky:
   # yum install iscsi-initiator-utils -y
   
   # Enable and start iscsid
   systemctl enable iscsid
   systemctl start iscsid
   ```

---

## IBM Block CSI Driver Installation

### Step 1: Enable Multipath (Required)

> ⚠️ **Critical**: Multipath **must** be enabled on all Kubernetes **worker nodes** (and any control plane nodes that run workloads) before using the CSI driver. Without multipath, pod creation will fail with PVC mount errors.

**On each worker node**, install and enable multipath:

```bash
# Install multipath packages (Ubuntu/Debian)
apt install multipath-tools -y

# For RHEL/CentOS/Rocky:
# yum install device-mapper-multipath -y

# Enable multipath configuration
mpathconf --enable

# Enable and start the multipath daemon
systemctl enable multipathd.service
systemctl start multipathd.service
```

**Validation - verify multipath is running**:
```bash
# Check service status
systemctl status multipathd.service
# Should show: Active: active (running)

# Verify config file exists
ls -la /etc/multipath.conf
# Should exist after mpathconf --enable

# Check multipath daemon is responding
multipathd show status
# Should show: path checker states, etc.

# List multipath devices (will be empty until volumes attached)
multipath -ll
```

**Expected output** (after volumes are attached):
```
mpathh (3600507680c8006be780000000000001c) dm-7 IBM,2145
size=40G features='1 queue_if_no_path' hwhandler='1 alua' wp=rw
|-+- policy='service-time 0' prio=50 status=active
| |- 33:0:10:83 sdbu 68:128 active ready running
| `- 33:0:7:83  sdbs 68:96  active ready running
`-+- policy='service-time 0' prio=10 status=enabled
  |- 33:0:1:83  sdbr 68:80  active ready running
  `- 33:0:8:83  sdbt 68:112 active ready running
```

**Symptoms of missing multipath**:
- Pod stuck in `ContainerCreating` state
- Events show: `MountVolume.MountDevice failed for volume <pvc uuid> : rpc error: code = Internal desc = exit status 1`
- CSI node logs show: `/etc/multipath.conf does not exist, blacklisting all devices`

> **Source**: [IBM Docs - Enable Multipath](https://www.ibm.com/docs/en/stg-block-csi-driver/1.12.5?topic=configuring-enabling-multipath)

### Step 2: Install the Operator and Driver

The operator method is recommended for production environments.

```bash
# Create namespace
kubectl create namespace ibm-block-csi

# Apply the operator manifests
kubectl apply -f https://raw.githubusercontent.com/IBM/ibm-block-csi-operator/v1.13.0/deploy/installer/generated/ibm-block-csi-operator.yaml
```

Deploy the CSI driver via the operator custom resource:

```yaml
# ibm-block-csi-cr.yaml
apiVersion: csi.ibm.com/v1
kind: IBMBlockCSI
metadata:
  name: ibm-block-csi
  namespace: ibm-block-csi
spec:
  controller:
    repository: ibmcom/ibm-block-csi-driver-controller
    tag: "1.13.0"
    affinity:
      nodeAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
          nodeSelectorTerms:
            - matchExpressions:
                - key: node-role.kubernetes.io/control-plane
                  operator: Exists
  node:
    repository: ibmcom/ibm-block-csi-driver-node
    tag: "1.13.0"
```

```bash
kubectl apply -f ibm-block-csi-cr.yaml
```

**Validation - verify installation**:

```bash
# Check operator pod is running
kubectl get pods -n ibm-block-csi -l app.kubernetes.io/name=ibm-block-csi-operator
# Should show: Running

# Check CSI driver pods (after applying CR)
kubectl get pods -n ibm-block-csi
# Expected output:
# NAME                                        READY   STATUS    RESTARTS   AGE
# ibm-block-csi-controller-xxxxxxxxx-xxxxx    6/6     Running   0          2m
# ibm-block-csi-node-xxxxx                    3/3     Running   0          2m
# ibm-block-csi-operator-xxxxxxxxx-xxxxx      1/1     Running   0          5m

# Verify CSI driver is registered with Kubernetes
kubectl get csidrivers | grep block.csi.ibm.com
# Should show: block.csi.ibm.com

# Check CSI driver version
kubectl get ibmblockcsi -n ibm-block-csi -o jsonpath='{.items[0].spec.controller.tag}'
# Should show: 1.13.0

# Verify node plugin is running on all worker nodes
kubectl get pods -n ibm-block-csi -l app=ibm-block-csi-node -o wide
# Should show one pod per worker node, all Running
```

> **Source**: [IBM Docs - Installing the operator and driver](https://www.ibm.com/docs/en/stg-block-csi-driver/1.12.5?topic=installation-installing-operator-driver)

---

## Configuration

Follow these steps in order after installing the CSI driver. Each step builds on the previous one.

> **Source**: [IBM Docs - Configuring](https://www.ibm.com/docs/en/stg-block-csi-driver/1.12.5?topic=configuring)

### Step 3: Create a Secret

Create an array secret to define the storage credentials (username and password) and management address.

> ⚠️ **Important**: When your storage system password is changed, be sure to also change the passwords in the corresponding secrets. Failing to do so causes mismatched passwords and user lockout.

**Option A: Using a YAML file**

```yaml
# demo-secret.yaml
kind: Secret
apiVersion: v1
metadata:
  name: demo-secret
  namespace: default
type: Opaque
stringData:
  management_address: "192.168.1.100,192.168.1.101"  # Comma-separated for HA
  username: "csi-user"
data:
  password: "BASE64_ENCODED_PASSWORD"  # echo -n 'your-password' | base64
```

```bash
kubectl apply -f demo-secret.yaml
```

**Option B: Using command line**

```bash
kubectl create secret generic demo-secret \
  --from-literal=username=csi-user \
  --from-literal=password=your-password \
  --from-literal=management_address=192.168.1.100,192.168.1.101 \
  -n default
```

**Validation - verify secret and array connectivity**:

```bash
# Verify secret was created
kubectl get secret demo-secret -n default
# Should show: demo-secret   Opaque   3

# Verify secret contains expected keys
kubectl get secret demo-secret -n default -o jsonpath='{.data}' | jq 'keys'
# Should show: ["management_address", "password", "username"]

# Test array connectivity from a node (replace with your array IP)
curl -k -s -o /dev/null -w "%{http_code}" https://192.168.1.100:7443/rest/v1/system
# Should return: 401 (unauthorized but reachable) or 200 if auth works

# If you have SSH access to the array, verify the user exists
ssh admin@192.168.1.100 lsuser
# Should list csi-user
```

> **Source**: [IBM Docs - Creating a Secret](https://www.ibm.com/docs/en/stg-block-csi-driver/1.12.5?topic=configuring-creating-secret)

### Step 4: Create a StorageClass

Create a StorageClass to define storage parameters such as pool name, space efficiency, and filesystem type.

**SpaceEfficiency parameter values by storage system**:

| Storage System | Supported Values |
|----------------|------------------|
| IBM FlashSystem / Storage Virtualize | `thick`, `thin`, `compressed`, `deduplicated`, `dedup_compressed` |
| IBM DS8000 | `none`, `thin` |

**StorageClass for standard workloads (RWO)**:

```yaml
# demo-storageclass.yaml
kind: StorageClass
apiVersion: storage.k8s.io/v1
metadata:
  name: demo-storageclass
provisioner: block.csi.ibm.com
parameters:
  pool: demo-pool                           # Required: Storage pool name
  io_group: demo-iogrp                      # Optional: I/O group
  volume_group: demo-volumegroup            # Optional: Volume group
  SpaceEfficiency: thin                     # Optional: thick/thin/compressed/deduplicated/dedup_compressed
  volume_name_prefix: demo                  # Optional: Max 20 chars (5 for DS8000)
  virt_snap_func: "false"                   # Optional: Use Snapshot function instead of FlashCopy
  csi.storage.k8s.io/fstype: xfs            # Optional: ext4 (default) or xfs
  csi.storage.k8s.io/secret-name: demo-secret
  csi.storage.k8s.io/secret-namespace: default
allowVolumeExpansion: true                  # Required for volume expansion
```

```bash
kubectl apply -f demo-storageclass.yaml
```

**Validation - verify StorageClass and test provisioning**:

```bash
# Verify StorageClass was created
kubectl get storageclass demo-storageclass
# Should show: demo-storageclass   block.csi.ibm.com   Delete   Immediate   true

# Verify StorageClass parameters
kubectl describe storageclass demo-storageclass
# Should show pool, secret references, etc.

# Test provisioning with a small PVC
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
  storageClassName: demo-storageclass
EOF

# Wait for PVC to bind (should take ~30 seconds)
kubectl get pvc test-pvc -w
# Should show: Bound

# Verify volume was created on the array (if SSH access available)
ssh admin@192.168.1.100 lsvdisk -filtervalue name=demo*
# Should show the new volume

# Clean up test PVC
kubectl delete pvc test-pvc
```

> **Source**: [IBM Docs - Creating a StorageClass](https://www.ibm.com/docs/en/stg-block-csi-driver/1.12.5?topic=configuring-creating-storageclass)

### Step 5: Create a VolumeSnapshotClass (Optional)

Required if you want to use volume snapshots.

```yaml
# demo-volumesnapshotclass.yaml
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  name: demo-volumesnapshotclass
driver: block.csi.ibm.com
deletionPolicy: Delete
parameters:
  pool: demo-pool                           # Optional: Different pool than source
  SpaceEfficiency: thin                     # Optional: Different efficiency than source
  snapshot_name_prefix: demo                # Optional: Max 20 chars (5 for DS8000)
  virt_snap_func: "false"                   # Optional: Must match StorageClass value
  csi.storage.k8s.io/snapshotter-secret-name: demo-secret
  csi.storage.k8s.io/snapshotter-secret-namespace: default
```

```bash
kubectl apply -f demo-volumesnapshotclass.yaml
```

**Validation - verify VolumeSnapshotClass**:

```bash
# Verify VolumeSnapshotClass was created
kubectl get volumesnapshotclass demo-volumesnapshotclass
# Should show: demo-volumesnapshotclass   block.csi.ibm.com   Delete

# Verify VolumeSnapshotClass parameters
kubectl describe volumesnapshotclass demo-volumesnapshotclass
# Should show secret references and parameters
```

> **Source**: [IBM Docs - Creating a VolumeSnapshotClass](https://www.ibm.com/docs/en/stg-block-csi-driver/1.12.5?topic=configuring-creating-volumesnapshotclass)

### Step 6: Verify Dynamic Host Definition

The host definer automatically creates host definitions on the storage array when nodes need access to volumes. This eliminates manual host configuration.

**Validation - verify host definitions**:

```bash
# Check host definition status
kubectl get hostdefinitions
# Expected output:
# NAME                     AGE    PHASE   NODE          MANAGEMENT_ADDRESS
# host-definition-node1    102m   Ready   node1         192.168.1.100
# host-definition-node2    102m   Ready   node2         192.168.1.100

# Verify all nodes have Ready status
kubectl get hostdefinitions -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\n"}{end}'
# All should show: Ready

# Verify hosts were created on the array (if SSH access available)
ssh admin@192.168.1.100 lshost
# Should show hosts matching your Kubernetes node names

# Check host details on array
ssh admin@192.168.1.100 lshost -delim : <hostname>
# Should show FC WWPNs or iSCSI IQNs for the node
```

If any host definitions show `Error` status, see the Troubleshooting section.

> **Source**: [IBM Docs - Using dynamic host definition](https://www.ibm.com/docs/en/stg-block-csi-driver/1.12.5?topic=using-dynamic-host-connectivity)

---

## Creating PersistentVolumeClaims (PVCs)

The IBM block storage CSI driver supports both **Filesystem** and **Block** volume modes.

> **Source**: [IBM Docs - Creating a PVC](https://www.ibm.com/docs/en/stg-block-csi-driver/1.12.5?topic=configuring-creating-persistentvolumeclaim-pvc)

### PVC for Filesystem Volume (RWO)

```yaml
# demo-pvc-file-system.yaml
kind: PersistentVolumeClaim
apiVersion: v1
metadata:
  name: demo-pvc-file-system
spec:
  volumeMode: Filesystem          # Default mode
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
  storageClassName: demo-storageclass
```

### PVC for Raw Block Volume (RWO)

```yaml
# demo-pvc-raw-block.yaml
kind: PersistentVolumeClaim
apiVersion: v1
metadata:
  name: demo-pvc-raw-block
spec:
  volumeMode: Block               # Raw block device
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
  storageClassName: demo-storageclass
```

### PVC with ReadWriteMany Access Mode (RWX)

**Required for KubeVirt live migration.** RWX allows multiple pods/nodes to access the volume simultaneously.

```yaml
# demo-pvc-rwx-block.yaml
kind: PersistentVolumeClaim
apiVersion: v1
metadata:
  name: demo-pvc-rwx-block
spec:
  volumeMode: Block
  accessModes:
    - ReadWriteMany               # Allows multi-node access
  resources:
    requests:
      storage: 50Gi
  storageClassName: demo-storageclass
```

> ⚠️ **Important**: If `ReadWriteMany` is specified, Kubernetes allows multiple pod containers to concurrently access the volume. If the application doesn't support multiple access, it is the user's responsibility to ensure only a single pod accesses the volume.

### PVC from Volume Snapshot (Clone)

```yaml
# demo-pvc-from-snapshot.yaml
kind: PersistentVolumeClaim
apiVersion: v1
metadata:
  name: demo-pvc-from-snapshot
spec:
  volumeMode: Filesystem
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
  storageClassName: demo-storageclass
  dataSource:
    name: demo-volumesnapshot
    kind: VolumeSnapshot
    apiGroup: snapshot.storage.k8s.io
```

### PVC Clone from Existing PVC

```yaml
# demo-pvc-cloned.yaml
kind: PersistentVolumeClaim
apiVersion: v1
metadata:
  name: demo-pvc-cloned
spec:
  volumeMode: Filesystem
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
  storageClassName: demo-storageclass
  dataSource:
    name: demo-pvc-file-system
    kind: PersistentVolumeClaim
```

---

## How RWX Block Storage Works

RWX block storage on IBM FlashSystem is **not NFS-based**. Instead, it uses **direct multi-host LUN access** (shared raw block):

1. **Shared LUN Mapping**: The same LUN is mapped to multiple Kubernetes nodes simultaneously via FC or iSCSI
2. **SCSI Persistent Reservations**: FlashSystem supports SCSI-3 Persistent Reservations (PR) to coordinate multi-host access and prevent data corruption
3. **KubeVirt I/O Coordination**: During live migration, KubeVirt handles I/O coordination between source and destination nodes - it ensures no simultaneous writes occur that would cause inconsistency
4. **No Filesystem Overhead**: Raw block access eliminates filesystem overhead, providing better performance than NFS-based RWX solutions

This approach provides:
- **Lower latency** than NFS-based shared storage
- **Direct block access** for VM disks (optimal for KubeVirt)
- **Native SAN performance** characteristics

> **Source**: [IBM FlashSystem Persistent Reservations](https://www.ibm.com/docs/en/flashsystem-7x00/8.4.0?topic=to-standard-persistent-reservations), [IBM Ideas Portal SCSI-I-1255](https://ibm-sys-storage.ideas.ibm.com/ideas/SCSI-I-1255)

---

## KubeVirt Integration

### Storage Requirements for KubeVirt

| Feature | Storage Requirement | IBM CSI Support | Source |
|---------|---------------------|-----------------|--------|
| Basic VM Storage | RWO Block/Filesystem | ✅ Yes | [KubeVirt Docs](https://kubevirt.io/user-guide/storage/disks_and_volumes/) |
| Live Migration | **RWX Block** | ✅ Yes (v1.12.0+) | [KubeVirt Live Migration](https://kubevirt.io/user-guide/compute/live_migration/), [IBM Ideas SCSI-I-1255](https://ibm-sys-storage.ideas.ibm.com/ideas/SCSI-I-1255) |
| VM Snapshots | Volume Snapshots | ✅ Yes | [IBM CSI Driver Docs](https://www.ibm.com/docs/en/stg-block-csi-driver) |
| VM Cloning | Volume Clones | ✅ Yes | [IBM CSI Driver Docs](https://www.ibm.com/docs/en/stg-block-csi-driver) |
| Disk Expansion | Volume Expansion | ✅ Yes | [IBM CSI Driver Docs](https://www.ibm.com/docs/en/stg-block-csi-driver) |
| Hot-plug Disks | RWO/RWX | ✅ Yes | [KubeVirt Docs](https://kubevirt.io/user-guide/storage/disks_and_volumes/) |

### PVC for KubeVirt VM with Live Migration Support

```yaml
# kubevirt-pvc-rwx.yaml
kind: PersistentVolumeClaim
apiVersion: v1
metadata:
  name: vm-disk-rwx
spec:
  accessModes:
    - ReadWriteMany               # Required for live migration
  volumeMode: Block               # Block mode for best performance
  resources:
    requests:
      storage: 50Gi
  storageClassName: demo-storageclass
```

### KubeVirt VM with Live Migration Enabled

```yaml
# kubevirt-vm-livemigration.yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: fedora-vm
spec:
  running: true
  template:
    metadata:
      labels:
        kubevirt.io/vm: fedora-vm
    spec:
      domain:
        devices:
          disks:
            - name: rootdisk
              disk:
                bus: virtio
            - name: cloudinitdisk
              disk:
                bus: virtio
          interfaces:
            - name: default
              masquerade: {}
        resources:
          requests:
            memory: 2Gi
      networks:
        - name: default
          pod: {}
      volumes:
        - name: rootdisk
          persistentVolumeClaim:
            claimName: vm-disk-rwx
        - name: cloudinitdisk
          cloudInitNoCloud:
            userData: |
              #cloud-config
              password: fedora
              chpasswd: { expire: False }
      # Enable live migration
      evictionStrategy: LiveMigrate
```

### DataVolume for VM Provisioning (with CDI)

```yaml
# datavolume-vm.yaml
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: fedora-dv
spec:
  source:
    registry:
      url: "docker://quay.io/containerdisks/fedora:latest"
  pvc:
    accessModes:
      - ReadWriteMany
    volumeMode: Block
    resources:
      requests:
        storage: 30Gi
    storageClassName: ibm-flash-rwx-block
```

### Shareable Disk Between VMs

For clustered applications or shared storage scenarios:

```yaml
# shared-disk-pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: shared-cluster-disk
spec:
  accessModes:
    - ReadWriteMany
  volumeMode: Block
  resources:
    requests:
      storage: 100Gi
  storageClassName: ibm-flash-rwx-block
---
# VM using shareable disk
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: cluster-node-1
spec:
  running: true
  template:
    spec:
      domain:
        devices:
          disks:
            - name: rootdisk
              disk:
                bus: virtio
            - name: shareddisk
              disk:
                bus: virtio
              shareable: true    # Enable sharing
        resources:
          requests:
            memory: 4Gi
      volumes:
        - name: rootdisk
          persistentVolumeClaim:
            claimName: node1-root
        - name: shareddisk
          persistentVolumeClaim:
            claimName: shared-cluster-disk
```

---

## Testing and Validation

### Test 1: Basic PVC Creation

```bash
# Create test PVC
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc
spec:
  accessModes:
    - ReadWriteOnce
  volumeMode: Filesystem
  resources:
    requests:
      storage: 10Gi
  storageClassName: ibm-flash-gold
EOF

# Verify PVC is bound
kubectl get pvc test-pvc
# Expected: STATUS = Bound

# Check PV details
kubectl describe pv $(kubectl get pvc test-pvc -o jsonpath='{.spec.volumeName}')
```

### Test 2: RWX Block Volume for KubeVirt

```bash
# Create RWX block PVC
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-rwx-block
spec:
  accessModes:
    - ReadWriteMany
  volumeMode: Block
  resources:
    requests:
      storage: 20Gi
  storageClassName: ibm-flash-rwx-block
EOF

# Verify PVC
kubectl get pvc test-rwx-block
```

### Test 3: VM Live Migration

```bash
# Create a test VM with RWX storage
# (Use the kubevirt-vm-livemigration.yaml from above)

# Verify VM is running
kubectl get vmi fedora-vm

# Initiate live migration
virtctl migrate fedora-vm

# Watch migration progress
kubectl get vmim -w

# Verify VM moved to different node
kubectl get vmi fedora-vm -o wide
```

### Test 4: Volume Snapshot

```bash
# Create snapshot
cat <<EOF | kubectl apply -f -
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: test-snapshot
spec:
  volumeSnapshotClassName: ibm-flash-snapclass
  source:
    persistentVolumeClaimName: test-pvc
EOF

# Verify snapshot
kubectl get volumesnapshot test-snapshot
```

### Test 5: Volume Expansion

```bash
# Expand PVC
kubectl patch pvc test-pvc -p '{"spec":{"resources":{"requests":{"storage":"20Gi"}}}}'

# Verify expansion
kubectl get pvc test-pvc
```

---

## Limitations and Considerations

### What Works with IBM FlashSystem + KubeVirt

| Feature | Status | Notes |
|---------|--------|-------|
| VM Boot Disks | ✅ | RWO or RWX |
| Live Migration | ✅ | Requires RWX block (v1.12.0+) |
| VM Snapshots | ✅ | Via VolumeSnapshot |
| VM Cloning | ✅ | Via DataVolume/CDI |
| Hot-plug Disks | ✅ | Supported |
| Disk Expansion | ✅ | Online expansion supported |
| Shareable Disks | ✅ | With `shareable: true` |
| FC Connectivity | ✅ | Recommended for production |
| iSCSI Connectivity | ✅ | Supported |
| NVMe/FC | ✅ | FlashSystem 9000 series |

### Limitations

1. **RWX Block Requires v1.12.0+**
   - Older CSI driver versions only support RWO block and RWX filesystem
   - Upgrade to v1.12.0 or later for KubeVirt live migration

2. **No RWX Filesystem for VM Disks**
   - KubeVirt requires block mode for best performance
   - RWX filesystem mode is available but not recommended for VM disks

3. **Storage Pool Considerations**
   - Each PVC creates a separate LUN on the array
   - Plan storage pool capacity accordingly
   - Consider thin provisioning to optimize capacity

4. **Network Requirements**
   - iSCSI requires dedicated storage network (recommended)
   - FC requires proper zoning
   - Multipathing is essential for HA

5. **Snapshot Limitations**
   - Snapshots consume space on the same pool
   - Plan for snapshot retention policies
   - IBM recommends sum of volume copies and snapshots should not exceed 50,000 when using standard pools

6. **No Native Replication via CSI**
   - DR/replication must be configured at the array level
   - Metro Mirror / Global Mirror for FlashSystem
   - Not exposed through CSI

### IBM FlashSystem Configuration Limits

> ⚠️ **Important**: Consult the [IBM Configuration Limits documentation](https://www.ibm.com/support/pages/v872x-configuration-limits-ibm-flashsystem-and-san-volume-controller) for your specific firmware version. The limits below are general guidance.

Key limits to be aware of (verify with IBM docs for your version):

| Limit Type | Typical Value | Notes |
|------------|---------------|-------|
| Volumes per host | Varies by model | Check IBM docs for your FlashSystem model |
| Hosts per system | Varies by model | Includes all Kubernetes nodes |
| Total volumes per system | Varies by model | Each PVC = 1 volume |
| FC logins per port | Limited | Includes HBAs, remote systems |
| Snapshots + FlashCopy | ≤50,000 recommended | For standard pools |

> **Source**: [IBM Configuration Limits](https://www.ibm.com/support/pages/v872x-configuration-limits-ibm-flashsystem-and-san-volume-controller)

#### Linux Host-Side LUN Limits

In addition to storage array limits, **Linux has its own SCSI layer limits**:

| Limit | Default | Notes |
|-------|---------|-------|
| LUNs per SCSI target | **256-512** (driver dependent) | Can be increased to **2048** via HBA driver parameters |
| Max LUNs (kernel) | **2048** | Hard limit in many SCSI drivers (e.g., QLogic, Emulex) |

**To increase LUN limits on Linux** (example for QLogic HBA):
```bash
# Check current limit
cat /sys/module/qla2xxx/parameters/ql2xmaxlun

# Set in /etc/modprobe.d/qla2xxx.conf
options qla2xxx ql2xmaxlun=2048

# Reload module or reboot
```

> ⚠️ **Planning Note**: If you expect more than 500 PVCs per Kubernetes node, verify both the FlashSystem "volumes per host" limit AND the Linux SCSI driver limits on your nodes.

> **Source**: [Linux Kernel SCSI Documentation](https://docs.kernel.org/driver-api/scsi.html)

### Mass Migration Scenarios (Node Failure)

When a Kubernetes node fails and VMs need to migrate to other nodes, several issues can arise:

#### KubeVirt Migration Limits

KubeVirt has built-in throttling to prevent overwhelming the cluster:

| Setting | Default | Description |
|---------|---------|-------------|
| `parallelMigrationsPerCluster` | **5** | Max concurrent migrations cluster-wide |
| `parallelOutboundMigrationsPerNode` | **2** | Max migrations leaving a single node |
| `bandwidthPerMigration` | **64Mi** | Network bandwidth limit per migration |
| `completionTimeoutPerGiB` | 800s | Timeout based on VM memory size |
| `progressTimeout` | 150s | Timeout if migration makes no progress |

**To adjust these limits** (in the KubeVirt CR):

```yaml
apiVersion: kubevirt.io/v1
kind: Kubevirt
metadata:
  name: kubevirt
  namespace: kubevirt
spec:
  configuration:
    migrations:
      parallelMigrationsPerCluster: 10    # Increase for faster recovery
      parallelOutboundMigrationsPerNode: 4
      bandwidthPerMigration: 128Mi
```

> **Source**: [KubeVirt Live Migration Configuration](https://kubevirt.io/user-guide/compute/live_migration/)

#### Potential Issues During Mass Migration

1. **Storage I/O Contention**
   - Multiple VMs accessing RWX volumes simultaneously during migration
   - FlashSystem queue depths may become saturated
   - **Mitigation**: Ensure adequate I/O groups and paths

2. **SCSI Reservation Contention**
   - RWX block uses SCSI-3 Persistent Reservations
   - Many simultaneous reservation changes can cause delays
   - **Mitigation**: Stagger migrations, don't exceed KubeVirt defaults without testing

3. **Network Bandwidth Saturation**
   - Memory migration competes with storage I/O
   - **Mitigation**: Use dedicated migration network, adjust `bandwidthPerMigration`

4. **Host Definition Updates**
   - CSI driver's host definer must update mappings on target nodes
   - Many simultaneous updates can cause delays
   - **Mitigation**: Verify all nodes have `Ready` host definitions before node maintenance

5. **Migration Queue Backlog**
   - With default limits (5 parallel), many VMs will queue
   - A node with 50 VMs takes minimum 10 migration cycles
   - **Mitigation**: Plan maintenance windows, increase parallel limits after testing

#### Best Practices for Node Failure Resilience

1. **Pre-stage host definitions** - Ensure all nodes have `Ready` status before any maintenance
2. **Test migration limits** - Validate increased parallel migration settings in non-prod first
3. **Monitor storage latency** - Watch FlashSystem I/O latency during migrations
4. **Use dedicated migration network** - Separate migration traffic from storage traffic
5. **Spread VMs across nodes** - Avoid concentrating too many VMs on single nodes

### Performance Recommendations

1. **Use Block Mode** for VM disks (not Filesystem mode)
2. **Enable Multipathing** for redundancy and performance
3. **Use Fibre Channel** for lowest latency workloads
4. **Thin Provisioning** for capacity efficiency
5. **Dedicated Storage Pools** for different workload tiers
6. **Multiple I/O Groups** - Distribute load across I/O groups for large deployments

---

## Troubleshooting

### Multipath Not Enabled (Most Common Issue)

**Symptoms**:
- Pod stuck in `ContainerCreating` state
- Events show: `MountVolume.MountDevice failed for volume <pvc uuid> : rpc error: code = Internal desc = exit status 1`

**Diagnosis** - Check CSI node logs:
```bash
kubectl logs -n ibm-block-csi -l app=ibm-block-csi-node -c ibm-block-csi-node
```

Look for:
```
/etc/multipath.conf does not exist, blacklisting all devices.
You can run "/sbin/mpathconf --enable" to create /etc/multipath.conf
```

**Solution** - Enable multipath on the affected node:
```bash
mpathconf --enable
systemctl start multipathd.service
multipath -ll
```

> **Source**: [IBM Docs - Enable Multipath](https://www.ibm.com/docs/en/stg-block-csi-driver/1.12.5?topic=configuring-enabling-multipath)

### Host Definition Errors

**Symptoms**:
- `kubectl get hostdefinitions` shows `Error` phase

**Solution**:
1. Undeploy the CSI node pod from the affected node
2. Verify all HostDefinition instances are deleted:
   ```bash
   kubectl get hostdefinitions -o=jsonpath='{range .items[?(@.spec.hostDefinition.nodeName=="<node-name>")]}{.metadata.name}{"\n"}{end}'
   ```
3. Redeploy the CSI node pod
4. Verify hostdefinition is in `Ready` phase:
   ```bash
   kubectl get hostdefinition
   ```

> **Source**: [IBM Docs - Using dynamic host definition](https://www.ibm.com/docs/en/stg-block-csi-driver/1.12.5?topic=using-dynamic-host-connectivity)

### PVC Stuck in Pending

```bash
# Check CSI controller logs
kubectl logs -n ibm-block-csi -l app=ibm-block-csi-controller -c ibm-block-csi-controller

# Common causes:
# - Invalid secret credentials
# - Storage pool doesn't exist
# - Network connectivity to array
# - Insufficient capacity
```

### Volume Attach Failures

```bash
# Check node plugin logs
kubectl logs -n ibm-block-csi -l app=ibm-block-csi-node -c ibm-block-csi-node

# Verify multipath on node
ssh <node> multipath -ll

# Check iSCSI sessions (if using iSCSI)
ssh <node> iscsiadm -m session
```

### Live Migration Fails

```bash
# Verify PVC access mode - must be ReadWriteMany
kubectl get pvc <pvc-name> -o jsonpath='{.spec.accessModes}'

# Verify volume mode - should be Block
kubectl get pvc <pvc-name> -o jsonpath='{.spec.volumeMode}'

# Check VMI conditions
kubectl describe vmi <vm-name>
```

### Verify Array Connectivity

```bash
# Test management API connectivity
curl -k -u csi-user:password https://<array-ip>:7443/rest/v1/system

# Check host definitions on array
ssh admin@<array-ip> lshost
```

### Useful Commands

```bash
# Check host definition status
kubectl get hostdefinitions

# List all IBM CSI volumes on array (via CLI)
ssh admin@<array-ip> lsvdisk -filtervalue name=demo*

# Check multipath status on all nodes
for node in $(kubectl get nodes -o name); do
  echo "=== $node ==="
  kubectl debug node/${node#node/} -it --image=alpine -- chroot /host multipath -ll
done

# View CSI driver events
kubectl get events --field-selector reason=ProvisioningFailed
```

---

## References

### IBM Block CSI Driver Documentation
- [IBM Block CSI Driver v1.12.5 - Configuring](https://www.ibm.com/docs/en/stg-block-csi-driver/1.12.5?topic=configuring) - Primary source for this guide
- [IBM Block CSI Driver Documentation](https://www.ibm.com/docs/en/stg-block-csi-driver)
- [IBM Block CSI Driver GitHub](https://github.com/IBM/ibm-block-csi-driver)
- [IBM Block CSI Operator GitHub](https://github.com/IBM/ibm-block-csi-operator)

### IBM FlashSystem Documentation
- [IBM FlashSystem 7300 Documentation](https://www.ibm.com/docs/en/flashsystem-7x00)
- [IBM FlashSystem 9500 Documentation](https://www.ibm.com/docs/en/flashsystem-9x00)
- [IBM FlashSystem Persistent Reservations](https://www.ibm.com/docs/en/flashsystem-7x00/8.4.0?topic=to-standard-persistent-reservations)

### KubeVirt Documentation
- [KubeVirt Storage Documentation](https://kubevirt.io/user-guide/storage/disks_and_volumes/)
- [KubeVirt Live Migration](https://kubevirt.io/user-guide/compute/live_migration/)

### Feature Requests and Community
- [IBM Ideas Portal - RWX Block Storage for KubeVirt (SCSI-I-1255)](https://ibm-sys-storage.ideas.ibm.com/ideas/SCSI-I-1255) - Confirmed RWX block support delivered in v1.12.0
