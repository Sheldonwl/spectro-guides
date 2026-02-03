# Kubernetes RBAC with Palette OIDC and ADFS Integration

This guide demonstrates how to implement Role-Based Access Control (RBAC) in a Palette-provisioned Kubernetes cluster using OIDC authentication with ADFS as the identity provider.

## Architecture Overview

```
┌──────────────┐     ┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│    User      │────▶│   Palette    │────▶│     ADFS     │────▶│  Kubernetes  │
│  (kubectl)   │     │  (OIDC IdP)  │     │  (SSO/IdP)   │     │   Cluster    │
└──────────────┘     └──────────────┘     └──────────────┘     └──────────────┘
                           │                     │                     │
                           │                     │                     │
                     Issues OIDC         Authenticates           Validates token
                     tokens for K8s      users & groups         applies RBAC rules
```

**Flow Summary:**
1. User runs kubectl command with OIDC-enabled kubeconfig
2. kubectl redirects to Palette for authentication
3. Palette redirects to ADFS (configured as SSO)
4. User authenticates with ADFS credentials
5. Palette receives ADFS groups, maps them to Teams, issues OIDC token
6. Kubernetes validates token and applies RBAC based on group claims

---

## Prerequisites

- [x] Palette instance with ADFS configured as SSO provider
- [x] ADFS groups mapped to Palette Teams
- [x] Palette-provisioned Kubernetes cluster with OIDC enabled (Palette as IdP)
- [x] OIDC-enabled kubeconfig downloaded from Palette

---

## Example Users and Groups

The following users and groups have been pre-created in ADFS and mapped to Palette Teams:

| User | Email | ADFS Group | Palette Team | Intended Access |
|------|-------|------------|--------------|-----------------|
| Alice Admin | alice@example.com | Platform-Admins | `platform-admins` | Full cluster access |
| Bob Developer | bob@example.com | Developers | `developers` | Dev namespace - full access |
| Carol DevOps | carol@example.com | DevOps-Team | `devops` | Staging + Production - deploy only |

---

## Step 1: Create Namespaces

First, create the namespaces that will be used for different teams.

```yaml
# namespaces.yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: development
  labels:
    environment: development
    team: developers
---
apiVersion: v1
kind: Namespace
metadata:
  name: staging
  labels:
    environment: staging
    team: devops
---
apiVersion: v1
kind: Namespace
metadata:
  name: production
  labels:
    environment: production
    team: devops
```

Apply the namespaces:

```bash
kubectl apply -f namespaces.yaml
```

---

## Step 2: Create Roles

Roles define what actions (verbs) can be performed on which resources within a namespace.

### Developer Role (Full Namespace Access)

```yaml
# role-developer.yaml
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: development
  name: developer-full-access
rules:
  # Full access to workloads
  - apiGroups: ["", "apps", "batch"]
    resources: ["pods", "deployments", "deployments/scale", "replicasets", "statefulsets", "daemonsets", "jobs", "cronjobs"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  
  # Full access to services and networking
  - apiGroups: ["", "networking.k8s.io"]
    resources: ["services", "endpoints", "ingresses"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  
  # Full access to config and secrets
  - apiGroups: [""]
    resources: ["configmaps", "secrets"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  
  # Pod logs and exec
  - apiGroups: [""]
    resources: ["pods/log", "pods/exec", "pods/portforward"]
    verbs: ["get", "create"]
  
  # PVCs
  - apiGroups: [""]
    resources: ["persistentvolumeclaims"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
```

### DevOps Role (Deploy and Monitor)

```yaml
# role-devops.yaml
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: staging
  name: devops-deploy-access
rules:
  # Read and update deployments (for CI/CD)
  - apiGroups: ["apps"]
    resources: ["deployments", "deployments/scale", "replicasets", "statefulsets"]
    verbs: ["get", "list", "watch", "update", "patch"]
  
  # Read-only for pods and services
  - apiGroups: [""]
    resources: ["pods", "services", "endpoints"]
    verbs: ["get", "list", "watch"]
  
  # Pod logs (no exec in staging/prod)
  - apiGroups: [""]
    resources: ["pods/log"]
    verbs: ["get"]
  
  # Read configmaps, manage deployment-related ones
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get", "list", "watch", "update", "patch"]
  
  # Read secrets (needed for deployments)
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "list"]
---
# Same role for production namespace
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: production
  name: devops-deploy-access
rules:
  - apiGroups: ["apps"]
    resources: ["deployments", "deployments/scale", "replicasets", "statefulsets"]
    verbs: ["get", "list", "watch", "update", "patch"]
  - apiGroups: [""]
    resources: ["pods", "services", "endpoints"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["pods/log"]
    verbs: ["get"]
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get", "list", "watch", "update", "patch"]
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "list"]
```

Apply the roles:

```bash
kubectl apply -f role-developer.yaml
kubectl apply -f role-devops.yaml
```

---

## Step 3: Create ClusterRoles

ClusterRoles are for cluster-wide permissions or permissions across all namespaces.

### Platform Admin ClusterRole (Full Access)

```yaml
# clusterrole-platform-admin.yaml
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: platform-admin
rules:
  # Full access to everything
  - apiGroups: ["*"]
    resources: ["*"]
    verbs: ["*"]
  # Non-resource URLs (API discovery, health checks)
  - nonResourceURLs: ["*"]
    verbs: ["*"]
```

### Read-Only Viewer ClusterRole

```yaml
# clusterrole-viewer.yaml
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: cluster-viewer
rules:
  # Read-only access to common resources
  - apiGroups: ["", "apps", "batch", "networking.k8s.io"]
    resources: ["*"]
    verbs: ["get", "list", "watch"]
  # Read nodes and namespaces
  - apiGroups: [""]
    resources: ["nodes", "namespaces"]
    verbs: ["get", "list", "watch"]
```

Apply the cluster roles:

```bash
kubectl apply -f clusterrole-platform-admin.yaml
kubectl apply -f clusterrole-viewer.yaml
```

---

## Step 4: Create RoleBindings

RoleBindings bind Roles to users or groups within a namespace. The group names must match the Palette Team names (which appear in the OIDC token).

### Bind Developers to Development Namespace

```yaml
# rolebinding-developers.yaml
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: developers-development-access
  namespace: development
subjects:
  - kind: Group
    name: developers          # Must match Palette Team name
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: developer-full-access
  apiGroup: rbac.authorization.k8s.io
```

### Bind DevOps to Staging and Production

```yaml
# rolebinding-devops.yaml
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: devops-staging-access
  namespace: staging
subjects:
  - kind: Group
    name: devops              # Must match Palette Team name
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: devops-deploy-access
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: devops-production-access
  namespace: production
subjects:
  - kind: Group
    name: devops              # Must match Palette Team name
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: devops-deploy-access
  apiGroup: rbac.authorization.k8s.io
```

Apply the role bindings:

```bash
kubectl apply -f rolebinding-developers.yaml
kubectl apply -f rolebinding-devops.yaml
```

---

## Step 5: Create ClusterRoleBindings

ClusterRoleBindings bind ClusterRoles to users or groups at the cluster level.

### Bind Platform Admins to Full Cluster Access

```yaml
# clusterrolebinding-platform-admins.yaml
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: platform-admins-full-access
subjects:
  - kind: Group
    name: platform-admins     # Must match Palette Team name
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: platform-admin
  apiGroup: rbac.authorization.k8s.io
```

### Give All Teams Basic Cluster Viewing (Optional)

```yaml
# clusterrolebinding-all-teams-viewer.yaml
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: all-teams-cluster-viewer
subjects:
  - kind: Group
    name: developers
    apiGroup: rbac.authorization.k8s.io
  - kind: Group
    name: devops
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: cluster-viewer
  apiGroup: rbac.authorization.k8s.io
```

Apply the cluster role bindings:

```bash
kubectl apply -f clusterrolebinding-platform-admins.yaml
kubectl apply -f clusterrolebinding-all-teams-viewer.yaml
```

---

## Step 6: Download OIDC-Enabled Kubeconfig

1. Log into Palette
2. Navigate to your cluster
3. Go to **Overview** → **Kubeconfig**
4. Download the **OIDC-enabled kubeconfig** file
5. Save it (e.g., `~/.kube/config-oidc`)

Set it as your kubeconfig:

```bash
export KUBECONFIG=~/.kube/config-oidc
```

---

## Step 7: Test Authentication and RBAC

### Test 1: Authenticate and Verify Identity

```bash
# This will trigger the OIDC login flow
kubectl get pods -A

# You'll be redirected to:
# 1. Palette OIDC endpoint
# 2. ADFS login page (if not already authenticated)
# 3. After successful login, back to terminal with results
```

### Test 2: Verify Your Permissions (as Bob - Developer)

```bash
# Check what you CAN do in development namespace
kubectl auth can-i create deployments -n development
# Expected: yes

kubectl auth can-i delete pods -n development
# Expected: yes

kubectl auth can-i get secrets -n development
# Expected: yes

# Check what you CANNOT do in other namespaces
kubectl auth can-i create deployments -n production
# Expected: no

kubectl auth can-i delete pods -n staging
# Expected: no (can only view)
```

### Test 3: Verify Permissions (as Carol - DevOps)

```bash
# Check staging/production permissions
kubectl auth can-i update deployments -n staging
# Expected: yes

kubectl auth can-i update deployments -n production
# Expected: yes

kubectl auth can-i delete pods -n production
# Expected: no (deploy only, no delete)

kubectl auth can-i exec pods -n production
# Expected: no (no exec in staging/prod)

# Check development namespace (should be limited)
kubectl auth can-i create deployments -n development
# Expected: no (that's for developers)
```

### Test 4: List All Your Permissions

As a regular user, list what you can do in a namespace:

```bash
# List all your permissions in development namespace
kubectl auth can-i --list -n development

# List all your permissions in staging namespace
kubectl auth can-i --list -n staging

# List all your permissions in production namespace
kubectl auth can-i --list -n production
```

### Test 5: Impersonation (Admin Only)

> **Note**: Impersonation requires cluster-admin privileges. Regular users cannot use `--as` or `--as-group`.

Cluster admins can test permissions for any group without logging in as that user:

```bash
# Test developer permissions in development namespace
kubectl auth can-i --list --as=anyuser --as-group=developers -n development

# Test devops permissions in staging namespace
kubectl auth can-i --list --as=anyuser --as-group=devops -n staging

# Test devops permissions in production namespace
kubectl auth can-i --list --as=anyuser --as-group=devops -n production

# Test admin permissions (cluster-wide)
kubectl auth can-i --list --as=anyuser --as-group=platform-admins
```

Sample output for developers in development namespace:
```
Resources                                       Non-Resource URLs   Resource Names   Verbs
pods                                            []                  []               [get list watch create update patch delete]
deployments.apps                                []                  []               [get list watch create update patch delete]
configmaps                                      []                  []               [get list watch create update patch delete]
secrets                                         []                  []               [get list watch create update patch delete]
...
```

Sample output for devops in staging namespace (more limited):
```
Resources                                       Non-Resource URLs   Resource Names   Verbs
deployments.apps                                []                  []               [get list watch update patch]
configmaps                                      []                  []               [get list watch update patch]
pods                                            []                  []               [get list watch]
secrets                                         []                  []               [get list]
pods/log                                        []                  []               [get]
...
```

---

## Step 8: Create Sample Workloads for Testing

Deploy test applications in all namespaces to verify access works correctly.

```bash
# Create test deployments in all namespaces (run as admin)
kubectl create deployment nginx-test --image=nginx:alpine -n development
kubectl create deployment nginx-test --image=nginx:alpine -n staging
kubectl create deployment nginx-test --image=nginx:alpine -n production
```

Now test your permissions:

```bash
# As a developer - should work in development
kubectl get pods -n development
kubectl exec -it deploy/nginx-test -n development -- echo "I have exec access"
kubectl delete pod -l app=nginx-test -n development

# As a developer - should be limited in production (view only)
kubectl get pods -n production
kubectl delete pod -l app=nginx-test -n production  # Should fail

# As devops - can update deployments in staging/production
kubectl scale deployment nginx-test --replicas=2 -n staging
kubectl scale deployment nginx-test --replicas=2 -n production

# As devops - cannot delete in staging/production
kubectl delete pod -l app=nginx-test -n production  # Should fail
```

---

## Quick Reference: RBAC Matrix

| Team | Namespace | Permissions |
|------|-----------|-------------|
| platform-admins | All | Full cluster admin |
| developers | development | Create, update, delete all workloads |
| developers | staging, production | View only (cluster-viewer) |
| devops | staging | Update deployments, view pods/services |
| devops | production | Update deployments, view pods/services |
| devops | development | View only (cluster-viewer) |

---

## Troubleshooting

### Token Issues

```bash
# View the current token claims (use jq for proper base64 decoding)
cat ~/.kube/cache/oidc-login/* 2>/dev/null | jq -r '.id_token | split(".")[1] | gsub("-";"+") | gsub("_";"/") | . + "==" | @base64d | fromjson'

# Just get the groups
cat ~/.kube/cache/oidc-login/* 2>/dev/null | jq -r '.id_token | split(".")[1] | gsub("-";"+") | gsub("_";"/") | . + "==" | @base64d | fromjson | .groups'

# If token expired, delete cached tokens and re-login
rm -rf ~/.kube/cache/oidc-login/
kubectl get pods  # triggers new login
```

### Permission Denied Errors

```bash
# Check what groups are in your token
cat ~/.kube/cache/oidc-login/* 2>/dev/null | jq -r '.id_token | split(".")[1] | gsub("-";"+") | gsub("_";"/") | . + "==" | @base64d | fromjson | .groups'

# The groups claim must match the RoleBinding subjects
```

**Admin-only commands** (to verify RBAC is configured correctly):

```bash
# Verify the RoleBinding exists (requires admin)
kubectl get rolebindings -n development

# Describe to see subjects (requires admin)
kubectl describe rolebinding developers-development-access -n development
```

### Verify OIDC is Working

```bash
# Test that OIDC login works by triggering authentication
rm -rf ~/.kube/cache/oidc-login/
kubectl get pods  # Should open browser for login

# Verify your token was received
cat ~/.kube/cache/oidc-login/* 2>/dev/null | jq -r '.id_token | split(".")[1] | gsub("-";"+") | gsub("_";"/") | . + "==" | @base64d | fromjson | {email, groups}'
```

> **Note**: API server logs (`kubectl logs -n kube-system -l component=kube-apiserver`) are not accessible in managed clusters where the control plane is hosted by the provider.

---

## Complete YAML Files

For convenience, here's a single file with all RBAC resources:

<details>
<summary>Click to expand: all-rbac-resources.yaml</summary>

```yaml
# all-rbac-resources.yaml
# Complete RBAC setup for OIDC with Palette and ADFS

# ============ NAMESPACES ============
---
apiVersion: v1
kind: Namespace
metadata:
  name: development
  labels:
    environment: development
    team: developers
---
apiVersion: v1
kind: Namespace
metadata:
  name: staging
  labels:
    environment: staging
    team: devops
---
apiVersion: v1
kind: Namespace
metadata:
  name: production
  labels:
    environment: production
    team: devops

# ============ CLUSTER ROLES ============
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: platform-admin
rules:
  - apiGroups: ["*"]
    resources: ["*"]
    verbs: ["*"]
  - nonResourceURLs: ["*"]
    verbs: ["*"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: cluster-viewer
rules:
  - apiGroups: ["", "apps", "batch", "networking.k8s.io"]
    resources: ["*"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["nodes", "namespaces"]
    verbs: ["get", "list", "watch"]

# ============ ROLES ============
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: development
  name: developer-full-access
rules:
  - apiGroups: ["", "apps", "batch"]
    resources: ["pods", "deployments", "deployments/scale", "replicasets", "statefulsets", "daemonsets", "jobs", "cronjobs"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["", "networking.k8s.io"]
    resources: ["services", "endpoints", "ingresses"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: [""]
    resources: ["configmaps", "secrets"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: [""]
    resources: ["pods/log", "pods/exec", "pods/portforward"]
    verbs: ["get", "create"]
  - apiGroups: [""]
    resources: ["persistentvolumeclaims"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: staging
  name: devops-deploy-access
rules:
  - apiGroups: ["apps"]
    resources: ["deployments", "deployments/scale", "replicasets", "statefulsets"]
    verbs: ["get", "list", "watch", "update", "patch"]
  - apiGroups: [""]
    resources: ["pods", "services", "endpoints"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["pods/log"]
    verbs: ["get"]
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get", "list", "watch", "update", "patch"]
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: production
  name: devops-deploy-access
rules:
  - apiGroups: ["apps"]
    resources: ["deployments", "deployments/scale", "replicasets", "statefulsets"]
    verbs: ["get", "list", "watch", "update", "patch"]
  - apiGroups: [""]
    resources: ["pods", "services", "endpoints"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["pods/log"]
    verbs: ["get"]
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get", "list", "watch", "update", "patch"]
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "list"]

# ============ CLUSTER ROLE BINDINGS ============
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: platform-admins-full-access
subjects:
  - kind: Group
    name: platform-admins
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: platform-admin
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: all-teams-cluster-viewer
subjects:
  - kind: Group
    name: developers
    apiGroup: rbac.authorization.k8s.io
  - kind: Group
    name: devops
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: cluster-viewer
  apiGroup: rbac.authorization.k8s.io

# ============ ROLE BINDINGS ============
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: developers-development-access
  namespace: development
subjects:
  - kind: Group
    name: developers
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: developer-full-access
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: devops-staging-access
  namespace: staging
subjects:
  - kind: Group
    name: devops
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: devops-deploy-access
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: devops-production-access
  namespace: production
subjects:
  - kind: Group
    name: devops
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: devops-deploy-access
  apiGroup: rbac.authorization.k8s.io
```

</details>

Apply everything at once:

```bash
kubectl apply -f all-rbac-resources.yaml
```

---

## Installing kubelogin (OIDC Plugin)

The `kubelogin` plugin (also known as `kubectl-oidc_login`) is required for OIDC authentication with kubectl. It handles the browser-based login flow and token management.

### Ubuntu / Debian / Linux

**Option 1: Using Krew (kubectl plugin manager) - Recommended**

```bash
# Install Krew first if you don't have it
(
  set -x; cd "$(mktemp -d)" &&
  OS="$(uname | tr '[:upper:]' '[:lower:]')" &&
  ARCH="$(uname -m | sed -e 's/x86_64/amd64/' -e 's/\(arm\)\(64\)\?.*/\1\2/' -e 's/aarch64$/arm64/')" &&
  KREW="krew-${OS}_${ARCH}" &&
  curl -fsSLO "https://github.com/kubernetes-sigs/krew/releases/latest/download/${KREW}.tar.gz" &&
  tar zxvf "${KREW}.tar.gz" &&
  ./"${KREW}" install krew
)

# Add to your shell profile (~/.bashrc or ~/.zshrc)
export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"

# Reload shell or source the profile
source ~/.bashrc  # or source ~/.zshrc

# Install kubelogin via Krew
kubectl krew install oidc-login
```

**Option 2: Direct binary download**

```bash
# Download the latest release
curl -LO "https://github.com/int128/kubelogin/releases/latest/download/kubelogin_linux_amd64.zip"

# Extract
unzip kubelogin_linux_amd64.zip

# Move to PATH and rename
sudo mv kubelogin /usr/local/bin/kubectl-oidc_login

# Make executable
sudo chmod +x /usr/local/bin/kubectl-oidc_login

# Verify installation
kubectl oidc-login --version
```

### Windows

**Option 1: Using Krew (Recommended)**

```powershell
# Install Krew for Windows (run in PowerShell as Administrator)
# Download from: https://github.com/kubernetes-sigs/krew/releases

# After Krew is installed, add to PATH
$env:PATH += ";$env:USERPROFILE\.krew\bin"

# Install kubelogin
kubectl krew install oidc-login
```

**Option 2: Using Chocolatey**

```powershell
# Install via Chocolatey
choco install kubelogin
```

**Option 3: Using winget**

```powershell
# Install via winget
winget install int128.kubelogin
```

**Option 4: Direct binary download**

```powershell
# Download from GitHub releases
# https://github.com/int128/kubelogin/releases/latest

# Extract kubelogin_windows_amd64.zip
# Rename kubelogin.exe to kubectl-oidc_login.exe
# Move to a directory in your PATH (e.g., C:\Windows\System32 or your kubectl directory)
```

### Verify Installation

```bash
# Both platforms - verify the plugin is recognized
kubectl oidc-login --version

# Or
kubectl oidc-login --help
```

---

## Clearing OIDC Token Cache (Force Re-login)

The kubelogin plugin caches tokens to avoid requiring login for every kubectl command. To force a new login (e.g., after group membership changes or to switch users), you need to clear this cache.

### Ubuntu / Linux

```bash
# Clear the OIDC token cache
rm -rf ~/.kube/cache/oidc-login/

# Alternative location (depending on kubelogin version)
rm -rf ~/.config/kubelogin/

# Verify cache is cleared
ls ~/.kube/cache/oidc-login/
# Should show: No such file or directory

# Next kubectl command will trigger fresh login
kubectl get pods
```

### Windows

**PowerShell:**

```powershell
# Clear the OIDC token cache
Remove-Item -Recurse -Force "$env:USERPROFILE\.kube\cache\oidc-login\" -ErrorAction SilentlyContinue

# Alternative location
Remove-Item -Recurse -Force "$env:USERPROFILE\.config\kubelogin\" -ErrorAction SilentlyContinue

# Or using Command Prompt
rmdir /s /q "%USERPROFILE%\.kube\cache\oidc-login"
rmdir /s /q "%USERPROFILE%\.config\kubelogin"

# Verify cache is cleared
dir "$env:USERPROFILE\.kube\cache\oidc-login"
# Should show: Path does not exist

# Next kubectl command will trigger fresh login
kubectl get pods
```

### Quick Reference Commands

| Platform | Cache Clear Command |
|----------|---------------------|
| Linux/macOS | `rm -rf ~/.kube/cache/oidc-login/` |
| Windows (PowerShell) | `Remove-Item -Recurse -Force "$env:USERPROFILE\.kube\cache\oidc-login\"` |
| Windows (CMD) | `rmdir /s /q "%USERPROFILE%\.kube\cache\oidc-login"` |

---

## Debugging OIDC Tokens

When troubleshooting RBAC issues, it's essential to inspect the JWT token to verify the claims (especially groups) match your RoleBindings.

### Decode the Current Token

**Linux/macOS:**

```bash
# Find the cached token file (hash-named file, no extension)
find ~/.kube/cache/oidc-login -type f ! -name "*.lock"

# Decode the cached token (handles base64 padding for macOS)
cat ~/.kube/cache/oidc-login/* 2>/dev/null | jq -r '.id_token' | \
  cut -d. -f2 | { read p; l=$((${#p} % 4)); \
  [ $l -eq 2 ] && p="${p}=="; [ $l -eq 3 ] && p="${p}="; \
  echo "$p" | base64 -d | jq .; }

# Or use this decode function (add to ~/.bashrc or ~/.zshrc)
decode_jwt() {
  local payload=$(echo "$1" | cut -d. -f2)
  local len=$((${#payload} % 4))
  [ $len -eq 2 ] && payload="${payload}=="
  [ $len -eq 3 ] && payload="${payload}="
  echo "$payload" | base64 -d | jq .
}
# Usage: decode_jwt "eyJhbGciOiJS..."
```

**Windows (PowerShell):**

```powershell
# Find cached token files (hash-named, no extension, exclude .lock files)
Get-ChildItem "$env:USERPROFILE\.kube\cache\oidc-login" | Where-Object { $_.Extension -eq "" -and $_.Name -notlike "*.lock" }

# Decode JWT token (PowerShell function)
function Decode-JWT {
    param([string]$Token)
    $parts = $Token.Split('.')
    $payload = $parts[1]
    # Add padding if needed
    $padding = 4 - ($payload.Length % 4)
    if ($padding -ne 4) { $payload += '=' * $padding }
    [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($payload)) | ConvertFrom-Json | ConvertTo-Json -Depth 10
}

# Read and decode from cache
$tokenFile = Get-ChildItem "$env:USERPROFILE\.kube\cache\oidc-login" | Where-Object { $_.Extension -eq "" -and $_.Name -notlike "*.lock" } | Select-Object -First 1
$tokenData = Get-Content $tokenFile.FullName | ConvertFrom-Json
Decode-JWT $tokenData.id_token
```

### Example Token Output

```json
{
  "iss": "https://palette.example.com/v1/oidc",
  "sub": "bob@example.com",
  "aud": "kubernetes",
  "exp": 1738540800,
  "iat": 1738537200,
  "email": "bob@example.com",
  "email_verified": true,
  "groups": [
    "developers"
  ],
  "name": "Bob Developer",
  "preferred_username": "bob@example.com"
}
```

### Key Claims to Verify

| Claim | Description | What to Check |
|-------|-------------|---------------|
| `iss` | Issuer URL | Must match K8s API server's `--oidc-issuer-url` |
| `aud` | Audience | Must match `--oidc-client-id` on API server |
| `sub` | Subject (user ID) | Unique user identifier |
| `email` | User's email | Used for username if `--oidc-username-claim=email` |
| `groups` | Group memberships | **Critical**: Must match RoleBinding subjects |
| `exp` | Expiration time | Unix timestamp - check if token is expired |

### Common Debugging Scenarios

**1. Check if groups claim matches RoleBinding:**

```bash
# Decode token and extract groups
cat ~/.kube/cache/oidc-login/* 2>/dev/null | jq -r '.id_token' | \
  cut -d. -f2 | { read p; l=$((${#p} % 4)); \
  [ $l -eq 2 ] && p="${p}=="; [ $l -eq 3 ] && p="${p}="; \
  echo "$p" | base64 -d | jq -r '.groups[]'; }

# Compare with RoleBinding subjects (requires admin)
# kubectl get rolebinding -n development -o jsonpath='{.items[*].subjects[*].name}'

# Your token groups should match the group names in your RoleBindings
```

**2. Check token expiration:**

```bash
# Get expiration timestamp and convert to human-readable
cat ~/.kube/cache/oidc-login/* 2>/dev/null | jq -r '.id_token' | \
  cut -d. -f2 | { read p; l=$((${#p} % 4)); \
  [ $l -eq 2 ] && p="${p}=="; [ $l -eq 3 ] && p="${p}="; \
  echo "$p" | base64 -d | jq -r '.exp'; } | \
  xargs -I{} date -r {}  # Use 'date -d @{}' on Linux

# If expired, clear cache and re-login
rm -rf ~/.kube/cache/oidc-login/
kubectl get pods  # triggers fresh login
```

**3. Verbose kubelogin output:**

```bash
# Run kubelogin manually with debug output
kubectl oidc-login get-token \
  --oidc-issuer-url=https://palette.example.com/v1/oidc \
  --oidc-client-id=kubernetes \
  --v=5

# This shows the full OIDC flow for debugging
```

**4. Test token directly with API server:**

```bash
# Extract the raw token (for API calls)
TOKEN=$(cat ~/.kube/cache/oidc-login/* 2>/dev/null | jq -r '.id_token')

# Call API server directly
curl -k -H "Authorization: Bearer $TOKEN" \
  https://<cluster-api-server>:6443/api/v1/namespaces/development/pods
```

### Online JWT Debugger

For quick visual inspection, you can paste your token (without sensitive data, or use a test token) into:

- **jwt.io** - https://jwt.io (paste token to decode)
- **jwt.ms** - https://jwt.ms (Microsoft's JWT decoder)

> ⚠️ **Security Warning**: Only use online decoders for test tokens. Production tokens contain sensitive information and should be decoded locally.

### Debugging Helper Script (Linux/macOS)

Save this as `debug-oidc.sh`:

```bash
#!/bin/bash
# debug-oidc.sh - Debug OIDC token for kubectl

echo "=== OIDC Token Debug Info ==="
echo ""

# Find token cache (hash-named file, no extension)
CACHE_DIR="$HOME/.kube/cache/oidc-login"
TOKEN_FILE=$(find "$CACHE_DIR" -type f ! -name "*.lock" 2>/dev/null | head -1)

if [ -z "$TOKEN_FILE" ]; then
    echo "No cached token found. Run a kubectl command first to trigger login."
    exit 1
fi

echo "Token cache file: $TOKEN_FILE"
echo ""

# Extract token and decode with proper base64 padding
ID_TOKEN=$(cat "$TOKEN_FILE" | jq -r '.id_token')
PAYLOAD_B64=$(echo "$ID_TOKEN" | cut -d. -f2)

# Add base64 padding if needed (JWT doesn't include padding)
PAD_LEN=$((${#PAYLOAD_B64} % 4))
[ $PAD_LEN -eq 2 ] && PAYLOAD_B64="${PAYLOAD_B64}=="
[ $PAD_LEN -eq 3 ] && PAYLOAD_B64="${PAYLOAD_B64}="

PAYLOAD=$(echo "$PAYLOAD_B64" | base64 -d)

echo "=== Token Claims ==="
echo "$PAYLOAD" | jq .
echo ""

echo "=== Key Information ==="
echo "User (sub):    $(echo "$PAYLOAD" | jq -r '.sub')"
echo "Email:         $(echo "$PAYLOAD" | jq -r '.email')"
echo "Groups:        $(echo "$PAYLOAD" | jq -r '.groups | join(", ")')"
echo ""

# Check expiration
EXP=$(echo "$PAYLOAD" | jq -r '.exp')
NOW=$(date +%s)
if [ "$EXP" -lt "$NOW" ]; then
    echo "Token EXPIRED at: $(date -r $EXP)"  # Use 'date -d @$EXP' on Linux
    echo "Run: rm -rf ~/.kube/cache/oidc-login/ && kubectl get pods"
else
    echo "Token valid until: $(date -r $EXP)"  # Use 'date -d @$EXP' on Linux
    REMAINING=$(( ($EXP - $NOW) / 60 ))
    echo "Time remaining: ${REMAINING} minutes"
fi
```

Make it executable and run:

```bash
chmod +x debug-oidc.sh
./debug-oidc.sh
```

---

## Network Policies for Namespace Isolation

Network policies provide network-level isolation between namespaces, complementing RBAC. Even if someone has RBAC access to a namespace, network policies can restrict what network traffic is allowed.

> **Note**: These are standard Kubernetes NetworkPolicies that work with Cilium and other CNI plugins.

### Default Deny All Traffic

Start by denying all ingress and egress traffic to each namespace, then allow only what's needed.

```yaml
# network-policies.yaml
---
# Development namespace - default deny
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: development
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
---
# Staging namespace - default deny
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: staging
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
---
# Production namespace - default deny
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: production
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
```

### Allow Intra-Namespace Traffic

Allow pods within the same namespace to communicate with each other.

```yaml
---
# Development - allow intra-namespace traffic
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-same-namespace
  namespace: development
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - podSelector: {}
  egress:
    - to:
        - podSelector: {}
---
# Staging - allow intra-namespace traffic
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-same-namespace
  namespace: staging
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - podSelector: {}
  egress:
    - to:
        - podSelector: {}
---
# Production - allow intra-namespace traffic
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-same-namespace
  namespace: production
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - podSelector: {}
  egress:
    - to:
        - podSelector: {}
```

### Allow DNS Resolution

Pods need to reach kube-dns/CoreDNS for name resolution.

```yaml
---
# Development - allow DNS
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns
  namespace: development
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
---
# Staging - allow DNS
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns
  namespace: staging
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
---
# Production - allow DNS
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns
  namespace: production
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
```

### Allow External Traffic (Optional)

If pods need to reach external services (APIs, databases outside cluster).

```yaml
---
# Production - allow egress to external (internet)
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-external-egress
  namespace: production
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              - 10.0.0.0/8      # Block internal ranges
              - 172.16.0.0/12
              - 192.168.0.0/16
```

### Allow Cross-Namespace Traffic (Optional)

If staging needs to reach production (e.g., for integration testing), allow specific traffic.

```yaml
---
# Allow staging to reach production on specific ports
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-from-staging
  namespace: production
spec:
  podSelector:
    matchLabels:
      allow-staging-access: "true"  # Only pods with this label
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              environment: staging
      ports:
        - protocol: TCP
          port: 8080
```

### Apply Network Policies

```bash
kubectl apply -f network-policies.yaml
```

### Verify Network Policies

```bash
# List policies in each namespace
kubectl get networkpolicies -n development
kubectl get networkpolicies -n staging
kubectl get networkpolicies -n production

# Test connectivity (from a pod in development)
kubectl exec -it deploy/nginx-test -n development -- curl -m 5 nginx-test.staging.svc.cluster.local
# Expected: timeout (blocked by network policy)

kubectl exec -it deploy/nginx-test -n development -- curl -m 5 nginx-test.development.svc.cluster.local
# Expected: success (same namespace allowed)
```

### Quick Reference: Network Policy Matrix

| Source Namespace | Destination Namespace | Allowed? |
|------------------|----------------------|----------|
| development | development | Yes (same namespace) |
| development | staging | No (isolated) |
| development | production | No (isolated) |
| staging | staging | Yes (same namespace) |
| staging | production | No (unless explicitly allowed) |
| production | production | Yes (same namespace) |
| Any | kube-system (DNS) | Yes (port 53 only) |

---

## Next Steps

1. **Customize for your environment**: Replace example group names with your actual Palette Team names
2. **Add more namespaces**: Create additional namespaces and roles as needed
3. **Fine-tune permissions**: Adjust the verbs and resources based on your security requirements
4. **Implement audit logging**: Enable Kubernetes audit logging to track access
5. **Add ingress rules**: Configure NetworkPolicies to allow traffic from ingress controllers
