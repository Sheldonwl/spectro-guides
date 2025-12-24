# MAAS Multi-NIC Cluster Troubleshooting

This guide addresses issues with MAAS-deployed Kubernetes clusters where nodes have multiple network interfaces (NICs), causing DNS records to contain multiple IPs including unreachable networks (e.g., PXE, BMC).

## Related Guides

- [MAAS & Bare-Metal VMO Guide](palette-maas-baremetal-vmo.md) — Full MAAS deployment guide
- [Debugging Guide](palette-debugging.md) — General troubleshooting

---

## The Problem

When MAAS provisions bare-metal nodes with multiple NICs, the Kubernetes API server DNS record may contain IPs from ALL networks, including:
- ✅ Management network (correct)
- ✅ Data/storage network (may be correct)
- ❌ PXE network (wrong - not routable from other clusters)
- ❌ BMC/IPMI network (wrong - not routable)

### Symptom

When connecting to the cluster (e.g., for Portworx DR peering, cluster federation, or kubectl access), clients cycle through all DNS IPs and fail intermittently:

**Example output** (your cluster name and IPs will differ):

```
# Testing connectivity to cluster - notice how it cycles through different IPs
root@control-plane-1:/tmp# nc -vz <your-cluster>.maas.<domain> 6443
connection to <your-cluster>.maas.<domain> (10.200.136.19) 6443 port [tcp/*] succeeded!

root@control-plane-1:/tmp# nc -vz <your-cluster>.maas.<domain> 6443
c: connect to <your-cluster>.maas.<domain> (10.200.132.20) port 6443 (tcp) failed: No route to host
connection to <your-cluster>.maas.<domain> (10.200.136.19) 6443 port [tcp/*] succeeded!

root@control-plane-1:/tmp# nc -vz <your-cluster>.maas.<domain> 6443
connection to <your-cluster>.maas.<domain> (10.200.136.19) 6443 port [tcp/*] succeeded!

root@control-plane-1:/tmp# nc -vz <your-cluster>.maas.<domain> 6443
c: connect to <your-cluster>.maas.<domain> (10.200.132.20) port 6443 (tcp) failed: No route to host
connection to <your-cluster>.maas.<domain> (10.200.130.12) 6443 port [tcp/*] succeeded!
```

**What's happening:**
- DNS returns multiple IPs: `10.200.136.19`, `10.200.132.20`, `10.200.130.12`
- `10.200.132.20` is on the PXE network — not routable from other clusters
- Client cycles through IPs, sometimes hitting the unreachable one

### Impact

- **Portworx DR/Metro replication fails** — Cluster peering requires reliable kubeconfig access
- **Cluster federation breaks** — Cross-cluster communication is unreliable
- **kubectl access intermittent** — Commands randomly fail with "No route to host"
- **Monitoring/alerting gaps** — Prometheus scraping fails intermittently

---

## Solutions

### Quick Reference: Which Fix to Use?

| Fix | What It SOLVES | What It DOES NOT SOLVE | When to Use |
|-----|----------------|------------------------|-------------|
| **Fix 1: Update MAAS DNS** | ✅ DNS returns wrong IPs | — | **Best fix.** Removes wrong IPs from DNS so all clients resolve correctly |
| **Fix 2: Verify advertise-address** | ✅ Internal components (kubelet) use correct IP | ❌ DNS still returns multiple IPs | Rarely needed — Palette sets this automatically |
| **Fix 2b: Cluster Profile** | ✅ Persists advertise-address through Palette | ❌ DNS still returns multiple IPs | Only if you need to override Palette's auto-configured value |
| **Fix 3: IP in kubeconfig** | ✅ THIS client bypasses DNS | ❌ Other clients still affected, ❌ DNS not fixed | Client-side workaround when you can't change DNS |
| **Fix 4: Add IP to SANs** | ✅ Certificate errors when using IP directly | ❌ DNS not fixed | Only if Fix 3 gives certificate errors |

> ⚠️ **Key insight:** The problem is that **MAAS DNS contains wrong IPs**. Only **Fix 1** actually fixes the DNS. Other fixes are workarounds or address different (rare) issues.

---

### Prevention: Configure `preferredSubnets` (New Clusters)

For **new clusters**, configure `preferredSubnets` BEFORE deployment to ensure only the correct IPs are registered in DNS.

See [Wrong IP Address in MAAS DNS Record](palette-maas-baremetal-vmo.md#wrong-ip-address-in-maas-dns-record-multi-nic) for configuration steps.

---

### Fix 1: Update MAAS DNS Record (Recommended)

> ✅ **What this fixes:** Removes the wrong IPs (PXE, BMC) from the MAAS DNS record so ALL clients resolve to the correct management IP(s). This is the **root cause fix**.
>
> ❌ **What this does NOT fix:** N/A — this is the correct solution for the multi-NIC DNS problem.

For **existing clusters**, manually update the MAAS DNS record to remove the incorrect IPs.

**Step 1: Identify correct IPs**

SSH to a control plane node of the affected cluster and find the management network IP:

```bash
# On a control plane node of the affected cluster

# Show all IPs
ip -4 addr show

# Find the management network interface (usually the one with default route)
ip route | grep default
# Example output: default via 10.200.136.1 dev ens3 proto static

# Get IP of that interface
ip -4 addr show dev ens3 | grep inet
# Example output: inet 10.200.136.19/24 brd 10.200.136.255 scope global ens3
```

**Step 2: Update MAAS DNS via CLI**

SSH to your MAAS server (or any machine with `maas` CLI installed and network access to MAAS):

```bash
# On the MAAS server or a machine with MAAS CLI access

# Set variables (replace with YOUR values)
MAAS_PROFILE="admin"                    # Your MAAS CLI profile name (from 'maas login')
MAAS_URL="http://10.200.130.5:5240/MAAS"  # Your MAAS server URL
MAAS_API_KEY="abc123:def456:ghi789..."    # Your MAAS API key
CLUSTER_NAME="my-cluster"                 # Part of your cluster name to search for

# Login to MAAS CLI (only needed once per session)
maas login $MAAS_PROFILE $MAAS_URL $MAAS_API_KEY

# List DNS resources for your cluster (shows ID, FQDN, and IPs)
maas $MAAS_PROFILE dnsresources read | jq -r --arg name "$CLUSTER_NAME" \
  '.[] | select(.fqdn | contains($name)) | "\(.id)\t\(.fqdn)\t\(if .ip_addresses | length > 0 then [.ip_addresses[].ip] | join(",") else "(none)" end)"'

# Example output:
# 14    my-cluster-a59f62.maas.example.com    192.168.15.22,10.200.132.20
# 15    my-cluster-2d12f8.maas.example.com    (none)

# Update the DNS record with the correct management IP(s)
# Replace 14 with your resource ID, and use your correct IP(s)
maas $MAAS_PROFILE dnsresource update 14 ip_addresses="10.200.136.19"

# Verify the change
maas $MAAS_PROFILE dnsresources read | jq -r --arg name "$CLUSTER_NAME" \
  '.[] | select(.fqdn | contains($name)) | "\(.id)\t\(.fqdn)\t\(if .ip_addresses | length > 0 then [.ip_addresses[].ip] | join(",") else "(none)" end)"'
```

> **Tip:** To get your MAAS API key:
> - **Via UI:** MAAS UI → your username (top right) → **API keys**
> - **Via CLI:** `sudo maas apikey --username=<your-maas-username>` (use your actual MAAS username, not necessarily "admin")

> ⚠️ **Note:** If you assign an IP that's **not in a MAAS-managed subnet**, MAAS will create an additional DNS record with the IP as the name (e.g., `192-168-222-222`). This is expected behavior. To avoid orphaned records, use IPs from MAAS-managed subnets, or delete the orphaned record:
> ```bash
> # Find and delete orphaned IP-based DNS record
> maas admin dnsresources read | jq '.[] | select(.fqdn | startswith("192-")) | {id: .id, fqdn: .fqdn}'
> maas admin dnsresource delete <id>
> ```

**Step 3: Update MAAS DNS via Web UI**

1. Go to MAAS UI → **DNS** tab
2. Find YOUR cluster's DNS record (search for your cluster name, e.g., `dr-cluster-xxx.maas.example.com`)
3. Edit the record
4. Remove the PXE/BMC network IP(s), keep only management network IPs
5. Save

**Step 4: Verify**

```bash
# Clear DNS cache if needed
systemd-resolve --flush-caches

# Test resolution (replace with YOUR cluster's FQDN)
dig +short <your-cluster-name>.maas.<your-domain>

# Example:
# dig +short dr-cluster-aee302.maas.example.com

# Test connectivity (should succeed consistently now - no more "No route to host")
for i in {1..10}; do nc -vz <your-cluster-fqdn> 6443; done

# Example:
# for i in {1..10}; do nc -vz dr-cluster-aee302.maas.example.com 6443; done
```

---

### Fix 2: Verify kube-apiserver advertise-address (Usually Already Set)

> ✅ **What this fixes:** Controls which IP internal Kubernetes components (kubelet, controller-manager, scheduler) use to communicate with the API server. Useful if internal components are trying to reach the apiserver on the wrong interface.
>
> ❌ **What this does NOT fix:** The MAAS DNS record. External clients (kubectl, Portworx DR peering, monitoring) will still see multiple IPs in DNS and cycle through them. **This does NOT solve the "No route to host" DNS cycling problem.**
>
> **If your DNS has multiple IPs causing connectivity issues, use Fix 1 instead.**

> ℹ️ **Note:** Palette/kubeadm already sets `--advertise-address` automatically. This section is mainly for **verification**.

The `--advertise-address` flag only affects what the apiserver tells internal components to use. It does **NOT** change the MAAS DNS record.

**To verify on a control-plane node:**

```bash
# Check current advertise-address
grep advertise /etc/kubernetes/manifests/kube-apiserver.yaml
```

**Expected output (already set by Palette):**
```
    kubeadm.kubernetes.io/kube-apiserver.advertise-address.endpoint: 192.168.15.22:6443
    - --advertise-address=192.168.15.22
```

If you need to change it manually (rare):

> ⚠️ **Manual vs Cluster Profile**
> 
> | Method | Triggers Repave? | Impact |
> |--------|-----------------|--------|
> | **Manual edit** (below) | ❌ NO | Only apiserver pod restarts |
> | **Cluster Profile edit** (`kubeadmconfig.apiServer.extraArgs`) | ✅ **YES** | All nodes repaved |

**Step 1: Edit kube-apiserver manifest**

```bash
vi /etc/kubernetes/manifests/kube-apiserver.yaml
```

**Step 2: Modify `--advertise-address`**

Find the `spec.containers[0].command` section and add:

```yaml
- --advertise-address=<MANAGEMENT_IP>
- --bind-address=0.0.0.0
```

**Example:**

```yaml
spec:
  containers:
  - command:
    - kube-apiserver
    - --advertise-address=10.200.136.19
    - --bind-address=0.0.0.0
    # ... other flags
```

| Flag | Purpose |
|------|---------|
| `--advertise-address` | Controls which IP other components use to reach the API server |
| `--bind-address=0.0.0.0` | Ensures API server listens on all interfaces (required for local access) |

**Step 3: Save and wait**

- kubelet automatically detects the manifest change
- kube-apiserver will restart automatically (may take 30-60 seconds)
- No redeployment required

**Step 4: Verify**

```bash
# Check apiserver is running with new config
ps aux | grep advertise-address

# Check API server is listening
ss -tlnp | grep 6443
```

> ⚠️ **Note:** This only affects how the API server advertises itself. It does NOT change the MAAS DNS record. External clients will still see multiple IPs in DNS, but internal components will prefer the advertised address.

---

### Fix 2b: Cluster Profile Method (Triggers Full Repave)

> ✅ **What this fixes:** Same as Fix 2 — controls which IP internal components use. The difference is this persists the setting through Palette, surviving future upgrades/repaves.
>
> ❌ **What this does NOT fix:** The MAAS DNS record. External clients will still cycle through multiple IPs. **This does NOT solve the Portworx DR peering or external kubectl access problem.**
>
> **Only use this if you specifically need to override the advertise-address Palette auto-configured, AND you can tolerate a full cluster repave.**

If you prefer to persist the change through Palette (and can tolerate a full repave), edit the K8s layer:

**In Palette UI:** Cluster → Profile → Kubernetes Layer → Edit values

Add under `kubeadmconfig.apiServer.extraArgs`:

```yaml
kubeadmconfig:
  apiServer:
    extraArgs:
      advertise-address: "10.200.136.19"  # Your management network IP
```

**What happens:**
1. Palette detects change to `kubeadmconfig.apiServer.extraArgs`
2. Repave notification is triggered (requires approval unless auto-approved)
3. **All control plane nodes** are replaced (rolling, one at a time)
4. **All worker nodes** are replaced (rolling)
5. Full repave can take 30-60+ minutes depending on cluster size

**Code reference:** The repave is triggered because `kubeadmconfig.apiServer.extraArgs` is in the list of K8s repave fields in `hubble/services/service/spectrocluster/internal/service/repave/spectroclusterrepave_detector.go`:

```go
repaveFields = append(repaveFields, "kubeadmconfig.apiServer.extraArgs")
```

---

### Fix 3: Use Specific IP in Kubeconfig

> ✅ **What this fixes:** THIS specific kubeconfig bypasses DNS entirely by connecting directly to the IP. Useful for Portworx DR peering or specific kubectl access when you can't modify MAAS DNS.
>
> ❌ **What this does NOT fix:** The MAAS DNS record. Other clients using DNS will still have issues. Every client that needs reliable access must have their kubeconfig modified individually.
>
> **Use this as a workaround when you cannot modify MAAS DNS (Fix 1).**

For immediate workaround without cluster changes, modify the kubeconfig to use a specific IP instead of the DNS name.

**Step 1: Get current kubeconfig**

```bash
# From Palette UI or kubectl
kubectl config view --raw > kubeconfig-production.yaml
```

**Step 2: Replace DNS with specific IP**

```bash
# Find the server line
grep server: kubeconfig-<your-cluster>.yaml
# Example output: server: https://<your-cluster>-xxx.maas.<domain>:6443

# Replace DNS name with specific IP (use YOUR cluster's DNS name and management IP)
sed -i 's|<your-cluster-fqdn>|<management-ip>|g' kubeconfig-<your-cluster>.yaml

# Example:
# sed -i 's|dr-cluster-aee302.maas.example.com|10.200.136.19|g' kubeconfig-dr-cluster.yaml
```

**Step 3: Verify**

```bash
KUBECONFIG=kubeconfig-production.yaml kubectl get nodes
```

> ⚠️ **Limitation:** This is a client-side workaround. Each client using the kubeconfig needs this change. Certificate validation may fail if the IP isn't in the API server's certificate SANs.

---

### Fix 4: Add IP to Certificate SANs (If Needed)

> ✅ **What this fixes:** Certificate validation errors like `x509: certificate is valid for <names>, not <ip>` when connecting via IP (after applying Fix 3).
>
> ❌ **What this does NOT fix:** The MAAS DNS record. This is only needed if you applied Fix 3 and the API server certificate doesn't include the IP as a Subject Alternative Name (SAN).
>
> **Only use this if Fix 3 gives you certificate errors.**

If using Fix 3 and getting certificate errors, the API server certificate may not include the IP address as a SAN.

**Check current certificate SANs:**

```bash
# On control plane node
openssl x509 -in /etc/kubernetes/pki/apiserver.crt -text -noout | grep -A1 "Subject Alternative Name"
```

**If IP is missing, regenerate certificates:**

```bash
# Backup existing certs
cp -r /etc/kubernetes/pki /etc/kubernetes/pki.backup

# Remove old apiserver certs
rm /etc/kubernetes/pki/apiserver.{crt,key}

# Regenerate with additional SANs
kubeadm init phase certs apiserver --apiserver-cert-extra-sans=10.200.136.19

# Restart apiserver
crictl pods --name kube-apiserver -q | xargs -I {} crictl stopp {}
```

---

## Prevention Checklist

For future MAAS deployments with multi-NIC nodes:

- [ ] **Configure `preferredSubnets`** in MAAS cloud account or PCG ConfigMap BEFORE deploying clusters
- [ ] **Document network topology** — which subnets are for management, data, PXE, BMC
- [ ] **Test DNS resolution** immediately after cluster creation
- [ ] **Verify API server accessibility** from external networks
- [ ] **Use static IPs** for control plane nodes when possible

---

## Related Issues

| Symptom | Cause | Actual Solution |
|---------|-------|-----------------|
| DNS returns multiple IPs, "No route to host" intermittent | MAAS DNS has wrong IPs (PXE/BMC) | **Fix 1** — Update MAAS DNS to remove wrong IPs |
| Portworx DR peering fails with "No route to host" | MAAS DNS has wrong IPs | **Fix 1** (best) or **Fix 3** (workaround) |
| kubectl works locally but fails from other networks | MAAS DNS has wrong IPs | **Fix 1** (best) or **Fix 3** (workaround) |
| Certificate errors `x509: certificate is valid for...` | Using IP directly (Fix 3) but IP not in cert SANs | **Fix 4** — Add IP to certificate SANs |
| Internal components (kubelet) fail to reach apiserver | `--advertise-address` wrong (rare, Palette auto-sets this) | **Fix 2** — Verify/change advertise-address |
| New clusters get wrong IPs in DNS | No `preferredSubnets` configured | **Prevention** — Configure preferredSubnets BEFORE deploy |

---

## References

- [MAAS DNS Documentation](https://maas.io/docs/how-to-manage-dns)
- [Kubernetes API Server Flags](https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/)
- [Portworx DR Configuration](https://docs.portworx.com/portworx-enterprise/operations/operate-kubernetes/disaster-recovery)
- [Palette MAAS Guide](palette-maas-baremetal-vmo.md)
