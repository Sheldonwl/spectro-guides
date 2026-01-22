# Palette API Usage Guide

A practical guide to using the Palette REST API, including authentication, common operations, and debugging techniques.

## Table of Contents

- [Authentication](#authentication)
- [Finding Resource IDs](#finding-resource-ids)
- [Common Endpoints](#common-endpoints)
- [Debugging API Issues](#debugging-api-issues)
- [Common Errors](#common-errors)
- [Examples](#examples)
  - [Example 1: Clear Stuck On-Demand OS Patch](#example-1-clear-stuck-on-demand-os-patch)
  - [Example 2: Get Cluster Status and Details](#example-2-get-cluster-status-and-details)
  - [Example 3: List All Clusters Across All Projects](#example-3-list-all-clusters-across-all-projects)
  - [Example 4: Debug API Key Permissions](#example-4-debug-api-key-permissions)
  - [Example 5: Download Kubeconfig by Cluster Name](#example-5-download-kubeconfig-by-cluster-name)
- [Quick Reference](#quick-reference)

---

## Authentication

### API Key Setup

1. Navigate to **Tenant Settings** → **API Keys** in the Palette UI
2. Create a new API key with appropriate permissions
3. Copy the raw API key value

### Request Headers

The API key must be passed in a specific header format:

```bash
# CORRECT
-H "ApiKey: your-api-key-here"

# WRONG - will fail with "UnAuthorizedAccess"
-H "Authorization: your-api-key-here"
-H "Authorization: Bearer your-api-key-here"
```

### Project Scope

For project-scoped resources (clusters, cloud accounts, etc.), you **must** include the `ProjectUid` header:

```bash
# CORRECT - includes project scope
curl -s "$PALETTE_URL/v1/spectroclusters/$CLUSTER_UID" \
  -H "ApiKey: $API_KEY" \
  -H "ProjectUid: $PROJECT_UID"

# WRONG - missing project scope, returns "OperationForbidden"
curl -s "$PALETTE_URL/v1/spectroclusters/$CLUSTER_UID" \
  -H "ApiKey: $API_KEY"

# WRONG - query parameter doesn't work for authentication
curl -s "$PALETTE_URL/v1/spectroclusters/$CLUSTER_UID?projectUid=$PROJECT_UID" \
  -H "ApiKey: $API_KEY"
```

### Base Configuration

Set up your environment variables:

```bash
# Your Palette instance URL (no trailing slash)
PALETTE_URL="https://your-palette.console.spectrocloud.com"

# API key from Tenant Settings → API Keys
API_KEY="your-api-key"

# Project UID and Cluster UID - BOTH come from the SAME URL
# When viewing a cluster, copy both from the URL:
# https://palette.example.com/admin/project/PROJECT_UID/clusters/CLUSTER_UID/overview
PROJECT_UID="your-project-uid"
CLUSTER_UID="your-cluster-uid"
```

> **Important:** Always set `PROJECT_UID` and `CLUSTER_UID` together from the same cluster URL. If you change one, you likely need to change the other. A cluster only exists in one project.

---

## Finding Resource IDs

### From the Palette URL

When viewing resources in the Palette UI, the URL contains the IDs you need:

```
https://palette.example.com/admin/project/abc123def456abc123def456/clusters/xyz789abc123xyz789abc123/overview
                                         └──────────────────────────┘        └──────────────────────────┘
                                                  Project UID                         Cluster UID
```

### URL Patterns

| Resource | URL Pattern | ID Location |
|----------|-------------|-------------|
| Cluster | `/admin/project/{projectUid}/clusters/{clusterUid}/...` | Both in path |
| Cloud Account | `/admin/project/{projectUid}/cloudaccounts/{accountUid}` | Both in path |
| Cluster Profile | `/admin/project/{projectUid}/profiles/cluster/{profileUid}/...` | Both in path |
| Tenant-level resource | `/admin/tenant/{tenantUid}/...` | Tenant in path |

---

## Common Endpoints

### Identity and Permissions

**Check who you are (API key identity):**
```bash
curl -s "$PALETTE_URL/v1/users/me" \
  -H "ApiKey: $API_KEY" | python3 -m json.tool
```

This returns your user info including all permissions across projects.

**List all projects you have access to:**
```bash
curl -s "$PALETTE_URL/v1/projects" \
  -H "ApiKey: $API_KEY" | python3 -m json.tool
```

### Clusters

**List clusters in a project (full details):**
```bash
# WARNING: Returns FULL cluster objects with all details - can be very large (1MB+)
curl -s "$PALETTE_URL/v1/spectroclusters" \
  -H "ApiKey: $API_KEY" \
  -H "ProjectUid: $PROJECT_UID"
```

**List clusters with useful info (name, cloud, state, health):**
```bash
curl -s "$PALETTE_URL/v1/spectroclusters" \
  -H "ApiKey: $API_KEY" \
  -H "ProjectUid: $PROJECT_UID" | \
  python3 -c "
import sys, json
data = json.load(sys.stdin)
print(f'{\"NAME\":30} | {\"CLOUD\":12} | {\"STATE\":15} | HEALTH')
print('-' * 75)
for c in data.get('items', []):
    m = c.get('metadata', {})
    s = c.get('status', {})
    sp = c.get('spec', {})
    health = s.get('health', {}).get('state', 'N/A')
    print(f'{m.get(\"name\",\"\"):30} | {sp.get(\"cloudType\",\"\"):12} | {s.get(\"state\",\"\"):15} | {health}')
"
```

**Alternative using jq:**
```bash
curl -s "$PALETTE_URL/v1/spectroclusters" \
  -H "ApiKey: $API_KEY" \
  -H "ProjectUid: $PROJECT_UID" | \
  jq -r '.items[] | "\(.metadata.name) | \(.spec.cloudType) | \(.status.state)"'
```

**Example output:**
```
NAME                           | CLOUD        | STATE           | HEALTH
---------------------------------------------------------------------------
prod-cluster-01                | maas         | Running         | Healthy
dev-cluster-02                 | maas         | Running         | N/A
edge-cluster-03                | edge-native  | Running         | Healthy
```

**Get a specific cluster:**
```bash
curl -s "$PALETTE_URL/v1/spectroclusters/$CLUSTER_UID" \
  -H "ApiKey: $API_KEY" \
  -H "ProjectUid: $PROJECT_UID"
```

**Update cluster OS patch config:**
```bash
curl -X PATCH "$PALETTE_URL/v1/spectroclusters/$CLUSTER_UID/clusterConfig/osPatch" \
  -H "ApiKey: $API_KEY" \
  -H "ProjectUid: $PROJECT_UID" \
  -H "Content-Type: application/json" \
  -d '{"onDemandPatchAfter":""}'
```

### HTTP Methods by Endpoint

Different endpoints support different HTTP methods. If you use the wrong method, you'll get a helpful error:

```bash
# Example: trying PUT on an endpoint that only accepts PATCH
{"code":405,"message":"method PUT is not allowed, but [PATCH] are"}
```

Common patterns:

| Endpoint Pattern | GET | POST | PUT | PATCH | DELETE |
|-----------------|-----|------|-----|-------|--------|
| `/v1/spectroclusters` | ✓ (list) | ✓ (create) | - | - | - |
| `/v1/spectroclusters/{uid}` | ✓ | - | - | - | ✓ |
| `/v1/spectroclusters/{uid}/clusterConfig/osPatch` | - | - | - | ✓ | - |
| `/v1/projects` | ✓ (list) | ✓ (create) | - | - | - |
| `/v1/users/me` | ✓ | - | - | - | - |

---

## Debugging API Issues

### Step 1: Verify API Key Works

Test with a simple endpoint that doesn't require project scope:

```bash
# Should return your user info
curl -s "$PALETTE_URL/v1/users/me" \
  -H "ApiKey: $API_KEY" | head -100
```

If this fails with `UnAuthorizedAccess`, your API key is invalid or the header format is wrong.

### Step 2: Verify Project Access

List projects to see what you have access to:

```bash
curl -s "$PALETTE_URL/v1/projects" \
  -H "ApiKey: $API_KEY" | python3 -m json.tool
```

Check if your target project UID appears in the list.

### Step 3: Verify Cluster Access

List clusters in the project:

```bash
curl -s "$PALETTE_URL/v1/spectroclusters" \
  -H "ApiKey: $API_KEY" \
  -H "ProjectUid: $PROJECT_UID" | \
  python3 -c "
import sys, json
data = json.load(sys.stdin)
for c in data.get('items', []):
    m = c.get('metadata', {})
    s = c.get('status', {})
    print(f'{m.get(\"name\"):30} {m.get(\"uid\")} ({s.get(\"state\")})')
"
```

**Example output:**
```
prod-cluster-01                abc123def456abc123def456 (Running)
dev-cluster-02                 xyz789abc123xyz789abc123 (Running)
```

Check if your target cluster UID appears in the list.

### Step 4: Check Specific Permissions

Look at your user info for permissions on the specific project:

```bash
# Get full user info
curl -s "$PALETTE_URL/v1/users/me" -H "ApiKey: $API_KEY" > /tmp/me.json

# Check for specific permission
grep -E "cluster\.(get|update)" /tmp/me.json

# Check for your project UID
grep "$PROJECT_UID" /tmp/me.json
```

### Step 5: Test with Verbose Output

Use curl's verbose mode to see the full request/response:

```bash
curl -v "$PALETTE_URL/v1/spectroclusters/$CLUSTER_UID" \
  -H "ApiKey: $API_KEY" \
  -H "ProjectUid: $PROJECT_UID" 2>&1
```

---

## Common Errors

### UnAuthorizedAccess

```json
{"code":"UnAuthorizedAccess","message":"..."}
```

**Causes:**
- Wrong header format (using `Authorization:` instead of `ApiKey:`)
- Invalid or expired API key
- API key not yet active

**Fix:**
```bash
# Use the correct header
-H "ApiKey: $API_KEY"
```

### OperationForbidden - cluster.get

```json
{"code":"OperationForbidden","message":"Operation 'cluster.get' is forbidden. Verify the user has 'cluster.get' permission"}
```

**Causes:**
- Missing `ProjectUid` header
- **Cluster is in a different project** than the one specified (most common)
- API key doesn't have access to this project
- API key doesn't have cluster.get permission

**Fix:**

First, verify the cluster is in the project you're querying:
```bash
# List clusters in the current project
curl -s "$PALETTE_URL/v1/spectroclusters" \
  -H "ApiKey: $API_KEY" \
  -H "ProjectUid: $PROJECT_UID" | \
  jq -r '.items[] | "\(.metadata.name) - \(.metadata.uid)"'
```

If your cluster isn't in the list, either:
1. Change `PROJECT_UID` to match the cluster's project, or
2. Change `CLUSTER_UID` to a cluster in the current project

> **Important:** The `CLUSTER_UID` and `PROJECT_UID` must match - the cluster must exist in the specified project.

### OperationForbidden - cluster.update

```json
{"code":"OperationForbidden","message":"Operation 'cluster.update' is forbidden..."}
```

**Causes:**
- API key has read-only access
- User role doesn't include cluster.update permission

**Fix:**
- Create a new API key with Cluster Admin or higher role
- Or use an API key from a user with appropriate permissions

### Method Not Allowed

```json
{"code":405,"message":"method PUT is not allowed, but [PATCH] are"}
```

**Cause:** Using the wrong HTTP method for the endpoint

**Fix:** Use the method specified in the error message

### Path Not Found

```json
{"code":404,"message":"path /v1/spectroclusters/{uid}/config/machineManagement was not found"}
```

**Cause:** The endpoint path doesn't exist

**Fix:** Check the API documentation or try variations of the path

---

## Examples

### Example 1: Clear Stuck On-Demand OS Patch

When On-Demand Update won't trigger because the timestamp is stuck:

```bash
PALETTE_URL="https://your-palette.console.spectrocloud.com"
API_KEY="your-api-key"
PROJECT_UID="abc123"  # From URL
CLUSTER_UID="def456"  # From URL

# Clear the onDemandPatchAfter field
curl -X PATCH "$PALETTE_URL/v1/spectroclusters/$CLUSTER_UID/clusterConfig/osPatch" \
  -H "ApiKey: $API_KEY" \
  -H "ProjectUid: $PROJECT_UID" \
  -H "Content-Type: application/json" \
  -d '{"onDemandPatchAfter":""}'

# Verify it's cleared (should show zero time or empty)
curl -s "$PALETTE_URL/v1/spectroclusters/$CLUSTER_UID" \
  -H "ApiKey: $API_KEY" \
  -H "ProjectUid: $PROJECT_UID" | grep -o '"onDemandPatchAfter":"[^"]*"'
```

**Example output after clearing:**
```
"onDemandPatchAfter":"0001-01-01T00:00:00.000Z"
```

The zero time (`0001-01-01T00:00:00.000Z`) indicates the field has been cleared. You can now trigger a new On-Demand Update from the UI.

### Example 2: Get Cluster Status and Details

```bash
PALETTE_URL="https://your-palette.console.spectrocloud.com"
API_KEY="your-api-key"
PROJECT_UID="abc123"
CLUSTER_UID="def456"

# Get useful cluster info at a glance
curl -s "$PALETTE_URL/v1/spectroclusters/$CLUSTER_UID" \
  -H "ApiKey: $API_KEY" \
  -H "ProjectUid: $PROJECT_UID" | \
  python3 -c "
import sys, json
data = json.load(sys.stdin)
meta = data.get('metadata', {})
spec = data.get('spec', {})
status = data.get('status', {})
osp = spec.get('clusterConfig', {}).get('machineManagementConfig', {}).get('osPatchConfig', {})

print('=== Cluster Info ===')
print(f'Name:        {meta.get(\"name\")}')
print(f'UID:         {meta.get(\"uid\")}')
print(f'Cloud Type:  {spec.get(\"cloudType\")}')
print(f'Created:     {meta.get(\"creationTimestamp\")}')
print(f'Modified:    {meta.get(\"lastModifiedTimestamp\")}')

print('\n=== Status ===')
print(f'State:       {status.get(\"state\")}')
print(f'Health:      {status.get(\"health\", {}).get(\"state\", \"N/A\")}')

print('\n=== OS Patch Config ===')
print(f'onDemandPatchAfter: {osp.get(\"onDemandPatchAfter\")}')
print(f'patchOnBoot:        {osp.get(\"patchOnBoot\")}')
print(f'rebootIfRequired:   {osp.get(\"rebootIfRequired\")}')

print('\n=== Conditions ===')
for c in status.get('conditions', [])[:8]:
    print(f'{c.get(\"type\"):30} {c.get(\"status\")}')
"
```

**Example output:**
```
=== Cluster Info ===
Name:        prod-cluster-01
UID:         abc123def456abc123def456
Cloud Type:  maas
Created:     2025-09-08T15:57:21.212Z
Modified:    2025-12-15T17:04:55.457Z

=== Status ===
State:       Running
Health:      Healthy

=== OS Patch Config ===
onDemandPatchAfter: 0001-01-01T00:00:00.000Z
patchOnBoot:        False
rebootIfRequired:   False

=== Conditions ===
ImageResolutionDone            True
BootstrappingDone              True
KubeConfigReady                True
CloudInfrastructureReady       True
ControlPlaneNodeAdditionDone   True
ControlPlaneNodeDeletionDone   True
WorkerNodeAdditionDone         True
WorkerNodeDeletionDone         True
```

### Example 3: List All Clusters Across All Projects

```bash
# Uses your existing environment variables: $PALETTE_URL and $API_KEY
python3 << EOF
import subprocess, json, os

PALETTE_URL = "$PALETTE_URL"
API_KEY = "$API_KEY"

def api_get(path, project_uid=None):
    cmd = ["curl", "-s", f"{PALETTE_URL}{path}", "-H", f"ApiKey: {API_KEY}"]
    if project_uid:
        cmd.extend(["-H", f"ProjectUid: {project_uid}"])
    return json.loads(subprocess.check_output(cmd))

# Get projects
projects = api_get("/v1/projects").get("items", [])

for proj in projects:
    name = proj["metadata"]["name"]
    uid = proj["metadata"]["uid"]
    print(f"\n=== {name} ===")
    
    try:
        clusters = api_get("/v1/spectroclusters", uid).get("items", []) or []
    except:
        clusters = []
    if not clusters:
        print("  (no clusters)")
    for c in clusters:
        cname = c["metadata"]["name"]
        state = c["status"].get("state", "?")
        print(f"  {cname:30} {state}")
EOF
```

> **Note:** This uses `<< EOF` (not `<< 'EOF'`) so shell variables like `$PALETTE_URL` and `$API_KEY` are expanded before passing to Python.

**Example output:**
```
=== Production ===
  prod-cluster-01                Running
  prod-cluster-02                Running

=== Development ===
  dev-cluster-01                 Running
  dev-cluster-02                 Provisioning

=== Edge ===
  (no clusters)

=== Virtual Machines ===
  vm-cluster-01                  Running
```

### Example 4: Debug API Key Permissions

```bash
PALETTE_URL="https://your-palette.console.spectrocloud.com"
API_KEY="your-api-key"

# Check what permissions the API key has
echo "=== User Identity ==="
curl -s "$PALETTE_URL/v1/users/me" -H "ApiKey: $API_KEY" | \
  python3 -c "import sys,json; u=json.load(sys.stdin)['spec']; print(f'Name: {u.get(\"firstName\",\"\")} {u.get(\"lastName\",\"\")}\nEmail: {u.get(\"emailId\",\"\")}')"

echo -e "\n=== Cluster Permissions ==="
curl -s "$PALETTE_URL/v1/users/me" -H "ApiKey: $API_KEY" | \
  grep -o '"cluster\.[^"]*"' | sort -u | head -10

echo -e "\n=== Projects with Access ==="
curl -s "$PALETTE_URL/v1/projects" -H "ApiKey: $API_KEY" | \
  python3 -c "import sys,json; [print(f'{p[\"metadata\"][\"name\"]} - {p[\"metadata\"][\"uid\"]}') for p in json.load(sys.stdin).get('items',[])]"
```

**Example output:**
```
=== User Identity ===
Name: John Smith
Email: john.smith@example.com

=== Cluster Permissions ===
"cluster.create"
"cluster.delete"
"cluster.get"
"cluster.import"
"cluster.list"
"cluster.update"

=== Projects with Access ===
Production - abc123def456abc123def456
Development - def456abc123def456abc123
Edge - ghi789xyz012ghi789xyz012
Virtual Machines - jkl012mno345jkl012mno345
```

### Example 5: Download Kubeconfig by Cluster Name

```bash
#!/bin/bash
# Usage: ./get-kubeconfig.sh <cluster-name> [--admin] [output-file]
# Downloads kubeconfig for a cluster by its human-readable name
#
# Options:
#   --admin    Download admin kubeconfig (with embedded certs, no OIDC)
#   Default is OIDC kubeconfig (requires browser login)

CLUSTER_NAME="${1:?Usage: $0 <cluster-name> [--admin] [output-file]}"

# Check for --admin flag
ADMIN_FLAG=""
if [[ "$2" == "--admin" ]]; then
    ADMIN_FLAG="admin"
    OUTPUT_FILE="${3:-${CLUSTER_NAME}-admin.kubeconfig}"
else
    OUTPUT_FILE="${2:-${CLUSTER_NAME}.kubeconfig}"
fi

# These must be set in your environment
: "${PALETTE_URL:?Set PALETTE_URL environment variable}"
: "${API_KEY:?Set API_KEY environment variable}"

echo "Searching for cluster: $CLUSTER_NAME"

# Search all projects for the cluster
RESULT=$(python3 << EOF
import subprocess, json, sys

def api_get(path, project_uid=None):
    cmd = ["curl", "-s", f"$PALETTE_URL{path}", "-H", f"ApiKey: $API_KEY"]
    if project_uid:
        cmd.extend(["-H", f"ProjectUid: {project_uid}"])
    try:
        return json.loads(subprocess.check_output(cmd, stderr=subprocess.DEVNULL))
    except:
        return {}

# Get all projects
projects = api_get("/v1/projects").get("items", [])

for proj in projects:
    puid = proj["metadata"]["uid"]
    clusters = api_get("/v1/spectroclusters", puid).get("items", []) or []
    for c in clusters:
        if c["metadata"]["name"] == "$CLUSTER_NAME":
            print(f"{puid}|{c['metadata']['uid']}")
            sys.exit(0)

sys.exit(1)
EOF
)

if [ -z "$RESULT" ]; then
    echo "Error: Cluster '$CLUSTER_NAME' not found in any project"
    exit 1
fi

PROJECT_UID=$(echo "$RESULT" | cut -d'|' -f1)
CLUSTER_UID=$(echo "$RESULT" | cut -d'|' -f2)

echo "Found cluster in project: $PROJECT_UID"
echo "Cluster UID: $CLUSTER_UID"
echo "Downloading kubeconfig to: $OUTPUT_FILE"

# Use admin endpoint if --admin flag was passed
if [ -n "$ADMIN_FLAG" ]; then
    ENDPOINT="adminKubeconfig"
    echo "Using admin kubeconfig (embedded certs)"
else
    ENDPOINT="kubeconfig"
    echo "Using OIDC kubeconfig"
fi

curl -s "$PALETTE_URL/v1/spectroclusters/$CLUSTER_UID/assets/$ENDPOINT" \
  -H "ApiKey: $API_KEY" \
  -H "ProjectUid: $PROJECT_UID" > "$OUTPUT_FILE"

if grep -q "apiVersion" "$OUTPUT_FILE"; then
    echo "Success! Kubeconfig saved to: $OUTPUT_FILE"
    echo "Use with: export KUBECONFIG=$OUTPUT_FILE"
else
    echo "Error downloading kubeconfig:"
    cat "$OUTPUT_FILE"
    rm -f "$OUTPUT_FILE"
    exit 1
fi
```

**Quick one-liner version** (if you know the project):

```bash
# Set these first
export PALETTE_URL="https://your-palette.console.spectrocloud.com"
export API_KEY="your-api-key"
export PROJECT_UID="your-project-uid"

# Download kubeconfig by name
CLUSTER_NAME="my-cluster"
CLUSTER_UID=$(curl -s "$PALETTE_URL/v1/spectroclusters" \
  -H "ApiKey: $API_KEY" \
  -H "ProjectUid: $PROJECT_UID" | \
  jq -r ".items[] | select(.metadata.name==\"$CLUSTER_NAME\") | .metadata.uid")

# OIDC kubeconfig (requires browser login)
curl -s "$PALETTE_URL/v1/spectroclusters/$CLUSTER_UID/assets/kubeconfig" \
  -H "ApiKey: $API_KEY" \
  -H "ProjectUid: $PROJECT_UID" > "${CLUSTER_NAME}.kubeconfig"

# OR Admin kubeconfig (embedded certs, no login needed)
curl -s "$PALETTE_URL/v1/spectroclusters/$CLUSTER_UID/assets/adminKubeconfig" \
  -H "ApiKey: $API_KEY" \
  -H "ProjectUid: $PROJECT_UID" > "${CLUSTER_NAME}-admin.kubeconfig"
```

**Example output:**
```
Searching for cluster: prod-cluster-01
Found cluster in project: abc123def456abc123def456
Cluster UID: xyz789abc123xyz789abc123
Downloading kubeconfig to: prod-cluster-01.kubeconfig
Success! Kubeconfig saved to: prod-cluster-01.kubeconfig
Use with: export KUBECONFIG=prod-cluster-01.kubeconfig
```

---

## Quick Reference

### Headers Cheat Sheet

```bash
# Always required
-H "ApiKey: $API_KEY"

# Required for project-scoped resources
-H "ProjectUid: $PROJECT_UID"

# Required for write operations
-H "Content-Type: application/json"
```

### Endpoint Quick Reference

| Action | Method | Endpoint |
|--------|--------|----------|
| Who am I | GET | `/v1/users/me` |
| List projects | GET | `/v1/projects` |
| List clusters | GET | `/v1/spectroclusters` (+ ProjectUid header) |
| Get cluster | GET | `/v1/spectroclusters/{uid}` (+ ProjectUid header) |
| Download kubeconfig (OIDC) | GET | `/v1/spectroclusters/{uid}/assets/kubeconfig` (+ ProjectUid header) |
| Download kubeconfig (Admin) | GET | `/v1/spectroclusters/{uid}/assets/adminKubeconfig` (+ ProjectUid header) |
| Update OS patch config | PATCH | `/v1/spectroclusters/{uid}/clusterConfig/osPatch` |

### Error Quick Reference

| Error | Likely Cause | Fix |
|-------|--------------|-----|
| `UnAuthorizedAccess` | Wrong header format | Use `ApiKey:` not `Authorization:` |
| `OperationForbidden` + `cluster.get` | Missing ProjectUid | Add `ProjectUid:` header |
| `OperationForbidden` + `cluster.update` | Insufficient permissions | Use API key with higher role |
| `405 Method Not Allowed` | Wrong HTTP method | Use method from error message |
| `404 Path Not Found` | Wrong endpoint | Check API docs |
