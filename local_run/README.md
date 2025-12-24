# Self-Hosted Trivy Database Builder

This directory contains scripts and configurations to build Trivy vulnerability database independently, suitable for Kubernetes CronJob deployment.

## Overview

The self-hosted solution builds Trivy database from:
- **GitLab vuln-list repositories** (your own copies)
- **Upstream sources** (GitHub advisory databases)

Components:
- **Shell script** (`build-db.sh`) - Builds the database
- **Dockerfile** - Containerizes the builder
- **Kubernetes manifests** - CronJob for automated builds + HTTP server

## Prerequisites

### 1. GitLab Repositories

Ensure these repositories exist and are updated regularly:
- `vuln-list`
- `vuln-list-nvd`
- `vuln-list-debian`
- `vuln-list-redhat`
- `vuln-list-aqua` (optional)

### 2. GitLab Access Token

Same token as vuln-list-updater (read access sufficient).

## Local Testing

### Using Docker

```bash
# Build the image
docker build -f local_run/Dockerfile -t trivy-db-builder:latest .

# Run the build
docker run -it --rm \
  -e GITLAB_TOKEN="your-token" \
  -e GITLAB_BASE_URL="https://gitlab.example.com" \
  -e GITLAB_GROUP="security/vulnerability-data" \
  -v $(pwd)/output:/output \
  -v $(pwd)/cache:/cache \
  trivy-db-builder:latest

# Check output
ls -lh output/db/
# Should contain: trivy.db, trivy.db.tar.gz, metadata.json, *.sha256
```

### Using Script Directly

```bash
# Export environment variables
export GITLAB_TOKEN="your-token"
export GITLAB_BASE_URL="https://gitlab.example.com"
export GITLAB_GROUP="security/vulnerability-data"
export CACHE_DIR="/tmp/trivy-cache"
export OUTPUT_DIR="/tmp/trivy-output"
export UPDATE_INTERVAL="24h"

# Run the build script
bash local_run/build-db.sh
```

## Kubernetes Deployment

### 1. Update Configuration

Edit `k8s-cronjob.yaml`:

```yaml
# ConfigMap
data:
  GITLAB_BASE_URL: "https://gitlab.example.com"
  GITLAB_GROUP: "security/vulnerability-data"
  UPDATE_INTERVAL: "24h"  # Database validity period

# Secret
stringData:
  GITLAB_TOKEN: "your-gitlab-token"
```

### 2. Create Namespace and Resources

```bash
# Create namespace
kubectl create namespace security

# Create PVCs (adjust storage class as needed)
kubectl apply -f local_run/k8s-cronjob.yaml

# Verify PVCs
kubectl get pvc -n security
```

### 3. Build and Push Image

```bash
# Build
docker build -f local_run/Dockerfile -t your-registry/trivy-db-builder:latest .

# Push
docker push your-registry/trivy-db-builder:latest
```

### 4. Deploy CronJob

```bash
# Deploy
kubectl apply -f local_run/k8s-cronjob.yaml

# Verify
kubectl get cronjob -n security
kubectl describe cronjob trivy-db-builder -n security
```

### 5. Manual Build Trigger

```bash
# Trigger manual build
kubectl create job --from=cronjob/trivy-db-builder trivy-db-builder-manual-$(date +%s) -n security

# Watch logs
kubectl logs -f job/trivy-db-builder-manual-XXXXX -n security

# Check output
kubectl exec -it <pod-name> -n security -- ls -lh /output/db/
```

## Database Distribution

### Option 1: HTTP Server (Included)

The manifest includes an nginx-based HTTP server:

```bash
# Access internally
curl http://trivy-db-server.security.svc.cluster.local:8080/

# Download database
curl -O http://trivy-db-server.security.svc.cluster.local:8080/trivy.db.tar.gz

# Configure Trivy clients
trivy image \
  --db-repository http://trivy-db-server.security.svc.cluster.local:8080 \
  your-image:tag
```

### Option 2: External Access via Ingress

Update the Ingress section in `k8s-cronjob.yaml`:

```yaml
spec:
  rules:
  - host: trivy-db.your-domain.com  # Your domain
```

Then configure Trivy:
```bash
trivy image \
  --db-repository https://trivy-db.your-domain.com \
  your-image:tag
```

### Option 3: S3-Compatible Storage

Add an init container to upload to S3:

```yaml
- name: upload-to-s3
  image: amazon/aws-cli
  command:
  - sh
  - -c
  - |
    aws s3 cp /output/db/trivy.db.tar.gz s3://your-bucket/trivy/db/
    aws s3 cp /output/db/metadata.json s3://your-bucket/trivy/db/
  env:
  - name: AWS_ACCESS_KEY_ID
    valueFrom:
      secretKeyRef:
        name: s3-credentials
        key: access-key
  - name: AWS_SECRET_ACCESS_KEY
    valueFrom:
      secretKeyRef:
        name: s3-credentials
        key: secret-key
  volumeMounts:
  - name: output
    mountPath: /output
```

## Schedule Configuration

**Recommended Schedule:**
- **vuln-list-updater**: Every 6 hours (`0 */6 * * *`)
- **trivy-db-builder**: Daily at 4 AM (`0 4 * * *`)

This ensures database builds use the latest vulnerability data.

Modify in `k8s-cronjob.yaml`:
```yaml
schedule: "0 4 * * *"  # Daily at 4 AM
# schedule: "0 */12 * * *"  # Every 12 hours
# schedule: "0 2 * * 0"  # Weekly on Sunday at 2 AM
```

## Resource Requirements

| Component | Disk | Memory | CPU | Build Time |
|-----------|------|--------|-----|------------|
| Cache | 40-50 GB | - | - | - |
| Build process | - | 4-8 GB | 2-4 cores | 2-4 hours |
| Output DB | 5-10 GB | - | - | - |

**Notes:**
- First build is slowest (downloading all data)
- Subsequent builds use cached data (faster)
- Build time depends on CPU and network speed

## Monitoring

### Check Build Status

```bash
# List recent jobs
kubectl get jobs -n security -l app=trivy-db-builder

# View logs
kubectl logs -n security -l app=trivy-db-builder --tail=100

# Check last successful build
kubectl exec -it deployment/trivy-db-server -n security -- \
  cat /usr/share/nginx/html/db/metadata.json
```

### Verify Database

```bash
# Download and test
curl -O http://trivy-db-server.security.svc.cluster.local:8080/trivy.db.tar.gz
tar xzf trivy.db.tar.gz

# Check with Trivy
trivy image --skip-db-update --cache-dir . alpine:latest
```

### Alerts

Configure alerts for:
- Build failures (job status)
- Build time > 8 hours
- No successful build in 48 hours
- Database file size anomalies

## Troubleshooting

### Build Fails with OOM

Increase memory limits:
```yaml
resources:
  limits:
    memory: "16Gi"  # Increase from 8Gi
```

### Slow Builds

1. **Use faster storage**: Change PVC `storageClassName` to SSD
2. **Keep cache**: Don't clean up cache between builds
3. **Increase CPU**: More cores = faster processing

### GitLab Authentication Issues

```bash
# Test token
curl -H "Authorization: Bearer ${GITLAB_TOKEN}" \
  ${GITLAB_BASE_URL}/api/v4/user

# Verify repo access
curl -H "Authorization: Bearer ${GITLAB_TOKEN}" \
  ${GITLAB_BASE_URL}/api/v4/projects/${GITLAB_GROUP}%2Fvuln-list
```

### Database Corruption

```bash
# Delete cache and rebuild
kubectl delete pvc trivy-db-cache -n security
kubectl apply -f local_run/k8s-cronjob.yaml
```

## Integration with Trivy

### Configure Trivy CLI

```bash
# Use custom DB repository
trivy image \
  --db-repository http://trivy-db-server.security.svc.cluster.local:8080 \
  alpine:latest

# Or set environment variable
export TRIVY_DB_REPOSITORY=http://trivy-db-server.security.svc.cluster.local:8080
trivy image alpine:latest
```

### Configure Trivy in K8s

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: trivy-config
data:
  TRIVY_DB_REPOSITORY: "http://trivy-db-server.security.svc.cluster.local:8080"
  TRIVY_SKIP_DB_UPDATE: "false"
```

### CI/CD Integration

```yaml
# GitLab CI example
scan:
  image: aquasec/trivy:latest
  variables:
    TRIVY_DB_REPOSITORY: "https://trivy-db.your-domain.com"
  script:
    - trivy image --exit-code 1 $CI_REGISTRY_IMAGE:$CI_COMMIT_SHA
```

## Adding Custom Signatures

To add custom vulnerability signatures:

1. **Create custom vuln-list entries** in your GitLab repos:
   ```bash
   # Add to vuln-list-aqua or create custom repo
   mkdir -p custom/my-product/CVE-2025-12345
   cat > custom/my-product/CVE-2025-12345/metadata.json <<EOF
   {
     "id": "CVE-2025-12345",
     "severity": "HIGH",
     "description": "Custom vulnerability",
     ...
   }
   EOF
   ```

2. **Modify build script** to include custom sources
3. **Rebuild database** - custom vulns will be included

## Performance Optimization

### Cache Strategy

**Keep cache persistent:**
- Faster builds (skip re-download)
- Uses more storage (40-50 GB)

**Clean cache:**
- Slower builds (re-download everything)
- Uses less storage
- Uncomment cleanup in `build-db.sh`:
  ```bash
  rm -rf "${CACHE_DIR}"/*
  ```

### Parallel Processing

The build process already uses parallelization internally. To speed up:
1. Use fast CPU (more cores)
2. Use fast storage (NVMe SSD)
3. Use fast network (for downloads)

## Security Considerations

1. **GitLab Token**: Rotate regularly, use read-only access
2. **Network Policies**: Restrict egress to required domains
3. **RBAC**: Limit service account permissions
4. **Database Signing**: Consider signing DB files for integrity

## Backup and DR

```bash
# Backup database
kubectl exec -it deployment/trivy-db-server -n security -- \
  tar czf /tmp/backup.tar.gz /usr/share/nginx/html/db/

# Copy to local
kubectl cp security/<pod-name>:/tmp/backup.tar.gz ./trivy-db-backup.tar.gz

# Restore
kubectl cp ./trivy-db-backup.tar.gz security/<pod-name>:/tmp/
kubectl exec -it deployment/trivy-db-server -n security -- \
  tar xzf /tmp/backup.tar.gz -C /
```

## Cost Optimization

- **Storage**: Use lifecycle policies to delete old builds
- **Compute**: Use spot/preemptible instances for builds
- **Network**: Cache upstream sources to reduce bandwidth

## License

This follows the same license as trivy-db (Apache 2.0).
