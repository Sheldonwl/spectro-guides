# IBM FlashSystem Storage for Palette Edge (CanvOS)

This guide covers building immutable Palette Edge images with IBM FlashSystem storage support using CanvOS, and the unique host identifiers that must be verified on each edge host.

## Table of Contents

- [Overview](#overview)
- [Unique Host Identifiers to Verify](#unique-host-identifiers-to-verify)
- [CanvOS Build Configuration](#canvos-build-configuration)
- [User Data Configuration](#user-data-configuration)
- [Dockerfile Customizations](#dockerfile-customizations)
- [Post-Deployment Validation](#post-deployment-validation)

---

## Overview

When using Palette Edge with immutable Kairos-based images, storage packages like `multipath-tools` and `open-iscsi` are pre-installed in the image. However, certain host identifiers **must be unique per host** for IBM FlashSystem to correctly identify and map volumes.

---

## Unique Host Identifiers to Verify

After deploying an immutable edge image, verify these identifiers are unique on each host:

### iSCSI Initiator Name (IQN)

The iSCSI Qualified Name (IQN) must be unique per host. If cloned from an image, it may be duplicated.

```bash
# Check current IQN
cat /etc/iscsi/initiatorname.iscsi

# Example output (should be unique per host):
# InitiatorName=iqn.1993-08.org.debian:01:abc123def456
```

**If duplicated**, regenerate with:
```bash
# Generate new unique IQN based on hostname
echo "InitiatorName=iqn.$(date +%Y-%m).$(hostname -d | awk -F. '{for(i=NF;i>0;i--) printf $i"."}' | sed 's/\.$//')$(hostname -s)" > /etc/iscsi/initiatorname.iscsi

# Or use iscsi-iname utility
iscsi-iname > /etc/iscsi/initiatorname.iscsi

# Restart iSCSI services
systemctl restart iscsid
systemctl restart open-iscsi
```

### Fibre Channel WWPNs

For FC connectivity, WWPNs are hardware-based and should be unique. Verify they're detected:

```bash
# List FC HBA WWPNs
cat /sys/class/fc_host/host*/port_name

# Example output:
# 0x2100001b32a12345
# 0x2100001b32a12346
```

> **Note**: WWPNs are burned into the HBA hardware and should always be unique. No action needed unless using virtual FC.

### Multipath Device Names

Verify multipath is detecting unique device identifiers:

```bash
# Check multipath devices
multipath -ll

# Verify WWID is unique per volume
multipathd show paths format "%w %d %s"
```

### Machine ID

The machine-id should be unique per host. Kairos typically regenerates this on first boot, but verify:

```bash
# Check machine-id
cat /etc/machine-id

# If duplicated across hosts, regenerate:
rm /etc/machine-id
systemd-machine-id-setup
```

### Hostname

Ensure hostname is unique (used by IBM CSI driver for host definitions):

```bash
# Check hostname
hostname

# The CSI driver uses this for host definitions on the FlashSystem
kubectl get hostdefinitions -A
```

---

## CanvOS Build Configuration

Clone CanvOS and configure for IBM FlashSystem support:

```bash
git clone https://github.com/spectrocloud/CanvOS.git
cd CanvOS
git checkout v4.8.1
```

### .arg File

Create `.arg` file with the following configuration:

```bash
CANVOS_VERSION=v4.8.1
K8S_VERSION=1.33.5
CUSTOM_TAG=multipath
IMAGE_REGISTRY=fake
OS_DISTRIBUTION=ubuntu
IMAGE_REPO=canvos
OS_VERSION=24.04
K8S_DISTRIBUTION=k3s
ISO_NAME=installer-generic-iso
ARCH=amd64
HTTPS_PROXY=
HTTP_PROXY=
PROXY_CERT_PATH=
UPDATE_KERNEL=false
CLUSTERCONFIG=spc.tgz
CIS_HARDENING=false
EDGE_CUSTOM_CONFIG=.edge-custom-config.yaml

# If you have Ubuntu Pro, use the UBUNTU_PRO_KEY variable to activate it as part of the image build
# UBUNTU_PRO_KEY=your-key

# For enabling Secure Boot with Full Disk Encryption
# IS_UKI=true
# MY_ORG="ACME Corporation"
# UKI_BRING_YOUR_OWN_KEYS=false         # See sb-private-ca/howto.md for instructions on bringing your own certiticates
# INCLUDE_MS_SECUREBOOT_KEYS=true       # Adds Microsoft Secure Boot certificates; if you export existing keys from a device, you typically won't need this
# AUTO_ENROLL_SECUREBOOT_KEYS=false     # Set to true to automatically enroll certificates on devices in Setup Mode, useful for flashing devices without user interaction
```

---

## Building the Image and ISO

### Prerequisites

Ensure you have Docker installed on your build machine:

```bash
# Docker (required) - Earthly runs inside a container, no separate install needed
docker --version
```

> **Note**: CanvOS uses `earthly.sh` which runs Earthly inside a Docker container. You do **not** need to install Earthly separately.

### Step 1: Build All Images (Provider + ISO)

Build both the provider images and installer ISO in one command:

```bash
# From the CanvOS directory
./earthly.sh +build-all-images --ARCH=amd64
```

Or build them separately:

```bash
# Build only the provider images
./earthly.sh +build-provider-images --ARCH=amd64

# Build only the installer ISO
./earthly.sh +iso --ARCH=amd64
```

### Step 2: Verify the Build

```bash
# Check the ISO was created
ls -lh build/
# Output: palette-edge-installer.iso, palette-edge-installer.iso.sha256

# Check the provider images were created
docker images | grep <IMAGE_REGISTRY>
```

Example output:
```
REPOSITORY              TAG                              IMAGE ID       CREATED        SIZE
fake/canvos             k3s-1.33.5-v4.8.1-multipath      cad8acdd2797   17 hours ago   4.62GB
```

### Step 3: Push Images to Registry

The provider images are **not automatically pushed**. Push them manually:

```bash
# Login to your registry
docker login <IMAGE_REGISTRY>

# Push the provider image (use the tag WITHOUT _linux_amd64 suffix)
docker push <IMAGE_REGISTRY>/<IMAGE_REPO>:<K8S_DISTRIBUTION>-<K8S_VERSION>-<CANVOS_VERSION>-<CUSTOM_TAG>

# Example:
docker push fake/canvos:k3s-1.33.5-v4.8.1-multipath
```

### Step 4: Use the system.uri in Palette

After building, the output will show the `system.uri` to use in your cluster profile:

```yaml
system.uri: "{{ .spectro.pack.edge-native-byoi.options.system.registry }}/{{ .spectro.pack.edge-native-byoi.options.system.repo }}:{{ .spectro.pack.edge-native-byoi.options.system.k8sDistribution }}-{{ .spectro.system.kubernetes.version }}-{{ .spectro.pack.edge-native-byoi.options.system.peVersion }}-{{ .spectro.pack.edge-native-byoi.options.system.customTag }}"
system.registry: fake
system.repo: canvos
system.k8sDistribution: k3s
system.osName: ubuntu
system.peVersion: v4.8.1
system.customTag: multipath
system.osVersion: 24.04
```

### Build Summary

| Artifact | Location | Purpose |
|----------|----------|---------|
| Provider Image | `<REGISTRY>/<REPO>:<TAG>` | Container image for Palette Edge |
| Installer ISO | `./build/palette-edge-installer.iso` | Bootable ISO for edge device installation |

### Common Build Issues

**Docker permission denied**:
```bash
# Add user to docker group
sudo usermod -aG docker $USER
newgrp docker
```

**Registry authentication failed**:
```bash
# Ensure you're logged in
docker login <IMAGE_REGISTRY>
```

**Proxy issues**:
```bash
# Configure git proxy if behind a proxy
git config --global http.proxy <your-proxy-server>
git config --global https.proxy <your-proxy-server>
```

---

## User Data Configuration

Create `user-data` file with multipath and iSCSI service configuration:

```yaml
#cloud-config

install:
  reboot: false
  poweroff: true

stylus:
  includeTui: true
  trace: true
  site:
    paletteEndpoint: api.spectrocloud.com
    edgeHostToken: 

stages:
  initramfs:
    - name: create-user-kairos
      users:
        kairos:
          groups: [sudo]
          passwd: "kairos"
          homedir: /home/kairos
          shell: /bin/bash
    - name: setup-multipath-config
      files:
        - path: /etc/multipath.conf
          permissions: 0644
          owner: 0
          group: 0
          content: |
            defaults {
              user_friendly_names yes
              find_multipaths yes
            }
  rootfs:
    - name: enable-storage-services
      commands:
        - mpathconf --enable --with_multipathd y
        - systemctl enable multipathd.service
        - systemctl enable open-iscsi.service 
        - systemctl enable iscsid.socket
  boot:
    - name: start-storage-services
      commands:
        - systemctl start multipathd.service
        - systemctl start iscsid.socket
        - systemctl start open-iscsi.service
```

### Ensuring Unique iSCSI IQN Per Host (Optional)

> **Note**: On Palette Edge devices, the iSCSI IQN is typically **generated randomly on first boot** by the `open-iscsi` package. This section is only needed if you're experiencing duplicate IQN issues (e.g., cloning VMs or using pre-configured images where the IQN was already set).

If you need to explicitly ensure unique IQNs, add this to the `boot` stage:

```yaml
stages:
  boot:
    - name: ensure-unique-iscsi-iqn
      commands:
        # Generate unique IQN if it contains the default/cloned value
        - |
          if grep -q "iqn.1993-08.org.debian" /etc/iscsi/initiatorname.iscsi 2>/dev/null; then
            NEW_IQN="iqn.$(date +%Y-%m).com.spectrocloud:$(hostname)"
            echo "InitiatorName=$NEW_IQN" > /etc/iscsi/initiatorname.iscsi
            systemctl restart iscsid
          fi
    - name: start-storage-services
      commands:
        - systemctl start multipathd.service
        - systemctl start iscsid.socket
        - systemctl start open-iscsi.service
```

---

## Dockerfile Customizations

Add IBM FlashSystem required packages to the Dockerfile:

```dockerfile
ARG BASE
FROM $BASE

ARG OS_DISTRIBUTION
ARG PROXY_CERT_PATH
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY

RUN mkdir -p /certs
COPY certs/ /certs/
RUN if [ "${OS_DISTRIBUTION}" = "ubuntu" ]; then \
    cp -a /certs/. /usr/local/share/ca-certificates/ && \
    update-ca-certificates; \
    fi 
RUN if [ "${OS_DISTRIBUTION}" = "opensuse-leap" ]; then \
    cp -a /certs/. /usr/share/pki/trust/anchors/ && \
    update-ca-certificates; \
    fi

RUN if [ "${OS_DISTRIBUTION}" = "rhel" ]; then \
    cp -a /certs/. /etc/pki/ca-trust/source/anchors/ && \
    update-ca-trust; \
    fi
RUN rm -rf /certs


########################### IBM FlashSystem Storage Packages #######################

RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        # Debugging tools
        traceroute \
        iputils-ping \
        net-tools \
        tcpdump \
        bind9-dnsutils \
        netcat-openbsd \
        netplan.io \
        ncdu \
        fio \
        # IBM FlashSystem required packages
        open-iscsi \
        nfs-common \
        multipath-tools && \
    rm -rf /var/lib/apt/lists/*
```

### Key Packages for IBM FlashSystem

| Package | Purpose |
|---------|---------|
| `multipath-tools` | **Required** - Device mapper multipathing for FC/iSCSI |
| `open-iscsi` | Required for iSCSI connectivity |
| `nfs-common` | Optional - Only if using NFS for other workloads |

---

## Post-Deployment Validation

After deploying the edge host, run these checks:

### 1. Verify Unique Identifiers

```bash
# Check iSCSI IQN is unique
cat /etc/iscsi/initiatorname.iscsi

# Check hostname matches expected
hostname

# Check machine-id
cat /etc/machine-id

# For FC, check WWPNs
cat /sys/class/fc_host/host*/port_name 2>/dev/null || echo "No FC HBAs detected"
```

### 2. Verify Storage Services

```bash
# Check multipath daemon
systemctl status multipathd

# Check iSCSI services
systemctl status iscsid
systemctl status open-iscsi

# Verify multipath configuration
multipath -ll
```

### 3. Verify CSI Driver Host Definition

After the IBM Block CSI driver is deployed:

```bash
# Check host definition was created
kubectl get hostdefinitions -A

# Verify status is Ready
kubectl get hostdefinitions -A -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\n"}{end}'
```

### 4. Test PVC Creation

```bash
# Create a test PVC
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-ibm-pvc
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: ibm-flash-storageclass
  resources:
    requests:
      storage: 1Gi
EOF

# Verify it binds
kubectl get pvc test-ibm-pvc

# Clean up
kubectl delete pvc test-ibm-pvc
```

---

## Troubleshooting Unique Identifier Issues

### Duplicate IQN Across Hosts

**Symptom**: Multiple hosts appear as the same initiator on FlashSystem, causing volume mapping conflicts.

**Solution**:
```bash
# On each affected host, regenerate IQN
NEW_IQN="iqn.$(date +%Y-%m).com.spectrocloud:$(hostname)"
echo "InitiatorName=$NEW_IQN" > /etc/iscsi/initiatorname.iscsi
systemctl restart iscsid open-iscsi

# Verify on FlashSystem that hosts now appear separately
```

### Host Definition Shows Wrong Node

**Symptom**: `kubectl get hostdefinitions` shows incorrect node mapping.

**Solution**:
```bash
# Delete the incorrect host definition
kubectl delete hostdefinition <name>

# Restart CSI node pod to recreate
kubectl delete pod -n <csi-namespace> -l app=ibm-block-csi-node
```

### Multipath Not Detecting Paths

**Symptom**: `multipath -ll` shows no devices or single path only.

**Solution**:
```bash
# Verify multipathd is running
systemctl status multipathd

# Rescan for devices
multipathd reconfigure

# For iSCSI, verify sessions
iscsiadm -m session

# For FC, rescan HBAs
echo "1" > /sys/class/fc_host/host*/issue_lip
```

---

## References

- [CanvOS Repository](https://github.com/spectrocloud/CanvOS)
- [IBM Block CSI Driver Documentation](https://www.ibm.com/docs/en/stg-block-csi-driver/1.12.5?topic=configuring)
- [Palette Edge Documentation](https://docs.spectrocloud.com/clusters/edge/)
- [IBM FlashSystem Storage Guide](ibm-flash.md)
