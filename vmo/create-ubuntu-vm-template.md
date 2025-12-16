# Creating an Ubuntu VM Template for KubeVirt

This guide covers creating an optimized Ubuntu VM image using KVM/virt-manager, preparing it as a reusable template, packaging it as a container image, and deploying it to KubeVirt.

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Create the VM](#create-the-vm)
3. [Install Ubuntu](#install-ubuntu)
4. [Configure the VM](#configure-the-vm)
5. [Sysprep the Template](#sysprep-the-template)
6. [Compress and Package](#compress-and-package)
7. [Deploy to KubeVirt](#deploy-to-kubevirt)
8. [Storage Recommendations](#storage-recommendations)
9. [Troubleshooting](#troubleshooting)

---

## Prerequisites

```bash
# Install required packages on Ubuntu host
sudo apt update
sudo apt install -y \
  qemu-kvm \
  libvirt-daemon-system \
  libvirt-clients \
  virt-manager \
  virtinst \
  libguestfs-tools \
  qemu-utils

# Add your user to the libvirt and kvm groups
sudo usermod -aG libvirt,kvm $USER

# Download Ubuntu Server 24.04 LTS (latest)
wget https://releases.ubuntu.com/noble/ubuntu-24.04.3-live-server-amd64.iso -O ~/ubuntu-24.04-server.iso

# Install Docker (needed for building container images)
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER
```

---

## Create the VM

### Using virt-manager GUI

1. Launch `virt-manager`
2. **File** → **New Virtual Machine** → **Local install media**
3. Browse and select the Ubuntu ISO
4. **Memory**: 2048 MB, **CPUs**: 2
5. **Storage**: 20 GiB, check **Customize configuration before install**
6. **Name**: `ubuntu-24.04-template`

### Before Starting Installation

In the configuration window:

1. **VirtIO Disk 1**:
   - Disk bus: **virtio**
   - Cache mode: **none**
   - Discard mode: **unmap**

2. **NIC**: Device model: **virtio**

3. Click **Begin Installation**

### Alternative: Command Line

```bash
virt-install \
  --name ubuntu-24.04-template \
  --ram 2048 \
  --vcpus 2 \
  --os-variant ubuntu24.04 \
  --cdrom ~/ubuntu-24.04-server.iso \
  --disk path=/var/lib/libvirt/images/ubuntu-24.04-template.qcow2,size=20,format=qcow2,bus=virtio,cache=none,discard=unmap \
  --network network=default,model=virtio \
  --graphics vnc \
  --boot cdrom,hd
```

---

## Install Ubuntu

During installation:

1. **Installation Type**: Ubuntu Server (minimized)
2. **Storage**: Use entire disk (LVM optional - both work with disk expansion)
3. **Profile**:
   - Username: `ubuntu`
   - Server name: `ubuntu-template`
   - Password: (temporary, will be removed)
4. **SSH**: Install OpenSSH server
5. **Snaps**: Skip all

Complete installation and reboot.

---

## Configure the VM

Log in and run these commands:

### System Updates and Essential Packages

```bash
# Update system
sudo apt update && sudo apt upgrade -y

# Install essential packages for KubeVirt
sudo apt install -y cloud-init qemu-guest-agent cloud-guest-utils

# Enable QEMU guest agent
sudo systemctl enable --now qemu-guest-agent
```

### Configure cloud-init (Critical)

```bash
# CRITICAL: Configure cloud-init to detect NoCloud datasource
# This is required for KubeVirt's cloudInitNoCloud to work
sudo tee /etc/cloud/cloud.cfg.d/99-datasource.cfg << 'EOF'
datasource_list: [ NoCloud, ConfigDrive, None ]
datasource:
  NoCloud:
    fs_label: cidata
EOF

# Disable warnings
sudo tee /etc/cloud/cloud.cfg.d/99-warnings.cfg << 'EOF'
warnings:
  dsid_missing_source: off
EOF

# Enable automatic disk expansion
sudo tee /etc/cloud/cloud.cfg.d/99-growpart.cfg << 'EOF'
growpart:
  mode: auto
  devices: ['/']
  ignore_growroot_disabled: false
resize_rootfs: true
EOF
```

> **Important**: The `fs_label: cidata` setting is critical! Without it, cloud-init won't detect KubeVirt's cloudInitNoCloud disk.

### Optional: Performance Tuning

```bash
# Enable TRIM for thin provisioning
sudo systemctl enable fstrim.timer

# Optimize I/O scheduler for virtio
echo 'ACTION=="add|change", KERNEL=="vd[a-z]", ATTR{queue/scheduler}="none"' | \
  sudo tee /etc/udev/rules.d/60-scheduler.rules
```

---

## Sysprep the Template

This removes machine-specific data to create a reusable template:

```bash
# Remove SSH host keys
sudo rm -f /etc/ssh/ssh_host_*

# Remove machine-id
sudo truncate -s 0 /etc/machine-id
sudo rm -f /var/lib/dbus/machine-id

# CRITICAL: Remove all cloud-init state
sudo cloud-init clean --logs
sudo rm -rf /var/lib/cloud/*
sudo mkdir -p /var/lib/cloud/{instances,data,scripts/per-boot,scripts/per-instance}

# Clean up
sudo rm -rf /tmp/* /var/tmp/*
sudo apt clean
sudo rm -rf /var/lib/apt/lists/*
sudo find /var/log -type f -exec truncate -s 0 {} \;

# Remove user password (cloud-init will set it)
sudo passwd -d ubuntu

# Clear history
cat /dev/null > ~/.bash_history
history -c

# Zero free space for compression
sudo dd if=/dev/zero of=/EMPTY bs=1M 2>/dev/null || true
sudo rm -f /EMPTY

# Shutdown
sudo sync
sudo shutdown -h now
```

---

## Compress and Package

### Compress the Disk Image

On the host after VM shutdown:

```bash
cd /var/lib/libvirt/images

# Compress the image
sudo qemu-img convert -c -O qcow2 \
  ubuntu-24.04-template.qcow2 \
  ubuntu-24.04-template-compressed.qcow2

# Verify
qemu-img info ubuntu-24.04-template-compressed.qcow2
```

Expected: ~1-2GB compressed from 20GB allocated.

### Build Container Image

```bash
mkdir -p ~/ubuntu-vm-image && cd ~/ubuntu-vm-image

# Copy the compressed image
cp /var/lib/libvirt/images/ubuntu-24.04-template-compressed.qcow2 ./disk.qcow2

# Create Dockerfile
cat > Dockerfile << 'EOF'
FROM scratch
ADD disk.qcow2 /disk/disk.img
EOF

# Build and push
REGISTRY="your-registry.example.com"
docker build -t ${REGISTRY}/ubuntu-vm:24.04 .
docker push ${REGISTRY}/ubuntu-vm:24.04
```

---

## Deploy to KubeVirt

### DataVolume (imports the image)

```yaml
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: ubuntu-vm-01-disk
spec:
  source:
    registry:
      url: "docker://your-registry.example.com/ubuntu-vm:24.04"
  storage:
    accessModes:
      - ReadWriteOnce
    volumeMode: Block
    resources:
      requests:
        storage: 20Gi
    storageClassName: longhorn  # Adjust to your storage class
```

### VirtualMachine

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: ubuntu-vm-01
spec:
  running: true
  template:
    spec:
      domain:
        cpu:
          cores: 2
        memory:
          guest: 4Gi
        devices:
          disks:
            - name: rootdisk
              disk:
                bus: virtio
              bootOrder: 1
            - name: cloudinitdisk
              disk:
                bus: virtio
          interfaces:
            - name: default
              masquerade: {}
          rng: {}
        machine:
          type: q35
      networks:
        - name: default
          pod: {}
      volumes:
        - name: rootdisk
          dataVolume:
            name: ubuntu-vm-01-disk
        - name: cloudinitdisk
          cloudInitNoCloud:
            userData: |
              #cloud-config
              hostname: ubuntu-vm-01
              manage_etc_hosts: true
              user: ubuntu
              password: ubuntu
              chpasswd:
                expire: false
                users:
                  - name: ubuntu
                    password: ubuntu
                    type: text
              ssh_pwauth: true
              runcmd:
                - systemctl enable --now qemu-guest-agent
```

### Deploy

```bash
kubectl apply -f datavolume.yaml
kubectl get dv ubuntu-vm-01-disk -w  # Wait for import

kubectl apply -f vm.yaml
virtctl console ubuntu-vm-01
```

Login with `ubuntu` / `ubuntu`.

---

## Storage Recommendations

### RWX Block vs RWX Filesystem

**KubeVirt live migration requires RWX (ReadWriteMany) access mode.**

| Volume Mode | Performance | Use Case |
|-------------|-------------|----------|
| **Block** | ⭐⭐⭐ Best | Live migration, HA |
| **Filesystem** | ⭐⭐ Good | Simpler setup |

### RWX Support by Provider

| Provider | RWX Block | RWX Filesystem | Live Migration |
|----------|-----------|----------------|----------------|
| **Portworx** | ✅ Native | ✅ | ✅ Best option |
| **Rook-Ceph** | ⚠️ Unsafe | ✅ CephFS | ✅ Via CephFS |
| **Longhorn** | ❌ | ✅ NFS | ✅ Via NFS |
| **Piraeus/LINSTOR** | ❌ | ✅ NFS | ✅ Via NFS |

### Portworx (Best for RWX Block)

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: px-rwx-block-kubevirt
parameters:
  repl: "2"
  sharedv4: "true"
provisioner: pxd.portworx.com
allowVolumeExpansion: true
```

### Rook-Ceph (CephFS for RWX)

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: rook-cephfs
provisioner: rook-ceph.cephfs.csi.ceph.com
parameters:
  clusterID: rook-ceph
  fsName: myfs
  pool: myfs-data0
```

> **Warning**: Ceph RBD can do RWX Block by disabling `exclusive-lock`, but this removes data corruption protection. **Not recommended.**

### Longhorn (NFS for RWX)

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: longhorn-rwx
provisioner: driver.longhorn.io
parameters:
  numberOfReplicas: "3"
  nfsOptions: "vers=4.1,noresvport,softerr,timeo=600,retrans=5"
```

### Piraeus/LINSTOR (NFS for RWX)

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: linstor-rwx
provisioner: linstor.csi.linbit.com
parameters:
  linstor.csi.linbit.com/storagePool: "lvm-thin"
  linstor.csi.linbit.com/nfs: "true"
```

### Best Practices

1. **Live migration**: Use RWX (Portworx Block preferred, or Filesystem with others)
2. **Single VM performance**: Use RWO Block
3. **Don't disable RBD exclusive-lock** for RWX - it's unsafe
4. **Enable TRIM** in VM for thin provisioning
5. **Size PVCs ≥ virtual disk size**

---

## Troubleshooting

### cloud-init Not Working

**Symptoms**: Hostname still shows `ubuntu-template`, password doesn't work.

**Cause**: cloud-init state wasn't cleaned, or datasource not configured.

**Fix**: Ensure the template has:
1. `fs_label: cidata` in `/etc/cloud/cloud.cfg.d/99-datasource.cfg`
2. Empty `/var/lib/cloud/` directory
3. Empty `/etc/machine-id`

### Quick Fix with virt-customize

If you need to fix an existing image:

```bash
sudo virt-customize -a /path/to/image.qcow2 \
  --run-command 'rm -rf /etc/cloud/cloud.cfg.d/*' \
  --write '/etc/cloud/cloud.cfg.d/99-datasource.cfg:datasource_list: [ NoCloud, ConfigDrive, None ]
datasource:
  NoCloud:
    fs_label: cidata
' \
  --run-command 'rm -rf /var/lib/cloud/*' \
  --run-command 'mkdir -p /var/lib/cloud/instances /var/lib/cloud/data' \
  --run-command 'truncate -s 0 /etc/machine-id' \
  --run-command 'rm -f /etc/ssh/ssh_host_*'
```

### Check cloud-init Inside VM

```bash
cloud-init status
cat /var/log/cloud-init.log
cat /run/cloud-init/ds-identify.log
```

### Common Issues

| Issue | Cause | Solution |
|-------|-------|----------|
| Hostname not changed | cloud-init didn't run | Add `fs_label: cidata` datasource config |
| Password not working | cloud-init didn't run | Add `fs_label: cidata` datasource config |
| "Used fallback datasource" | Missing `fs_label: cidata` | Add datasource config |
| cloud-init status: done but no changes | Stale state from template | Clean `/var/lib/cloud/` and `/etc/machine-id` |
