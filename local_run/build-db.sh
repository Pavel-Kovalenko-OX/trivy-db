#!/bin/bash
set -euo pipefail

# Self-hosted Trivy DB Builder
# This script builds the Trivy vulnerability database from vuln-list repositories
# 
# Required environment variables:
#   GITLAB_TOKEN     - GitLab personal access token with repo access
#   GITLAB_BASE_URL  - GitLab base URL (e.g., https://gitlab.example.com)
#   GITLAB_GROUP     - GitLab group/namespace (e.g., security/vulnerability-data)
#   OUTPUT_DIR       - Directory to store the built database (default: /output)

CACHE_DIR="${CACHE_DIR:-/cache}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
GITLAB_TOKEN="${GITLAB_TOKEN:?GITLAB_TOKEN is required}"
GITLAB_BASE_URL="${GITLAB_BASE_URL:?GITLAB_BASE_URL is required}"
GITLAB_GROUP="${GITLAB_GROUP:?GITLAB_GROUP is required}"
UPDATE_INTERVAL="${UPDATE_INTERVAL:-24h}"

echo "=== Trivy Database Builder ==="
echo "Cache directory: ${CACHE_DIR}"
echo "Output directory: ${OUTPUT_DIR}"
echo "GitLab URL: ${GITLAB_BASE_URL}"
echo "Update interval: ${UPDATE_INTERVAL}"
echo ""

# Create directories
mkdir -p "${CACHE_DIR}"
mkdir -p "${OUTPUT_DIR}"

# Function to download from GitLab
download_gitlab_repo() {
    local repo_name=$1
    local target_dir="${CACHE_DIR}/${repo_name}"
    local git_url="${GITLAB_BASE_URL}/${GITLAB_GROUP}/${repo_name}.git"
    local auth_url="${git_url/\/\//\/\/oauth2:${GITLAB_TOKEN}@}"
    
    echo "[$(date +%T)] Fetching ${repo_name} from GitLab..."
    
    if [ -d "${target_dir}/.git" ]; then
        echo "  Repository exists, pulling latest..."
        cd "${target_dir}"
        git pull origin main || git pull origin master || true
    else
        echo "  Cloning repository..."
        git clone --depth 1 "${auth_url}" "${target_dir}"
    fi
}

# Function to download from GitHub (for upstream sources)
download_github_repo() {
    local repo_url=$1
    local target_dir=$2
    
    echo "[$(date +%T)] Downloading ${repo_url}..."
    mkdir -p "${target_dir}"
    wget -qO - "${repo_url}" | tar xz -C "${target_dir}" --strip-components=1
}

# Step 1: Fetch vuln-list repositories from GitLab
echo ""
echo "=========================================="
echo "Step 1: Fetching vuln-list repositories"
echo "=========================================="

download_gitlab_repo "vuln-list"
download_gitlab_repo "vuln-list-redhat"
download_gitlab_repo "vuln-list-debian"
download_gitlab_repo "vuln-list-nvd"

# Optional: vuln-list-aqua (if you have it)
if curl -sf -H "Authorization: Bearer ${GITLAB_TOKEN}" \
    "${GITLAB_BASE_URL}/api/v4/projects/${GITLAB_GROUP}%2Fvuln-list-aqua" > /dev/null 2>&1; then
    download_gitlab_repo "vuln-list-aqua"
    echo "  ✓ vuln-list-aqua found and downloaded"
else
    echo "  ℹ vuln-list-aqua not found (optional)"
fi

# Step 2: Fetch language-specific advisory databases
echo ""
echo "=========================================="
echo "Step 2: Fetching language advisory databases"
echo "=========================================="

# Ruby
download_github_repo \
    "https://github.com/rubysec/ruby-advisory-db/archive/master.tar.gz" \
    "${CACHE_DIR}/ruby-advisory-db"

# PHP
download_github_repo \
    "https://github.com/FriendsOfPHP/security-advisories/archive/master.tar.gz" \
    "${CACHE_DIR}/php-security-advisories"

# Node.js
download_github_repo \
    "https://github.com/nodejs/security-wg/archive/main.tar.gz" \
    "${CACHE_DIR}/nodejs-security-wg"

# Bitnami
download_github_repo \
    "https://github.com/bitnami/vulndb/archive/main.tar.gz" \
    "${CACHE_DIR}/bitnami-vulndb"

# GHSA (GitHub Security Advisories)
download_github_repo \
    "https://github.com/github/advisory-database/archive/refs/heads/main.tar.gz" \
    "${CACHE_DIR}/ghsa"

# Go vulnerability database
download_github_repo \
    "https://github.com/golang/vulndb/archive/refs/heads/master.tar.gz" \
    "${CACHE_DIR}/govulndb"

# CocoaPods (for Swift package mapping)
echo "[$(date +%T)] Downloading CocoaPods specs (this may take a while)..."
download_github_repo \
    "https://github.com/CocoaPods/Specs/archive/master.tar.gz" \
    "${CACHE_DIR}/cocoapods-specs"

# Kubernetes CVE feed
download_github_repo \
    "https://github.com/kubernetes-sigs/cve-feed-osv/archive/main.tar.gz" \
    "${CACHE_DIR}/k8s-cve-feed"

# Julia
download_github_repo \
    "https://github.com/JuliaLang/SecurityAdvisories.jl/archive/refs/heads/generated/osv.tar.gz" \
    "${CACHE_DIR}/julia"

# Step 3: Build the database
echo ""
echo "=========================================="
echo "Step 3: Building Trivy database"
echo "=========================================="

cd /app

# Check if trivy-db binary exists (Docker multi-stage build scenario)
if [ -f "./trivy-db" ] && [ -x "./trivy-db" ]; then
    echo "[$(date +%T)] Using existing trivy-db binary"
else
    echo "[$(date +%T)] Binary not found, attempting to build..."
    if command -v go >/dev/null 2>&1; then
        echo "[$(date +%T)] Building trivy-db binary..."
        go build -o trivy-db ./cmd/trivy-db
        echo "[$(date +%T)] ✓ Build completed"
    else
        echo "[$(date +%T)] ✗ ERROR: trivy-db binary not found and Go compiler not available" >&2
        echo "  Either run this script in the Docker container or install Go locally" >&2
        exit 1
    fi
fi

echo "[$(date +%T)] Starting database build..."
echo "  Cache dir: ${CACHE_DIR}"
echo "  Output dir: ${OUTPUT_DIR}"
echo "  Update interval: ${UPDATE_INTERVAL}"
echo ""

./trivy-db build \
    --cache-dir "${CACHE_DIR}" \
    --output-dir "${OUTPUT_DIR}" \
    --update-interval "${UPDATE_INTERVAL}"

# Step 4: Verify and compress
echo ""
echo "=========================================="
echo "Step 4: Post-processing"
echo "=========================================="

if [ -f "${OUTPUT_DIR}/db/trivy.db" ]; then
    DB_SIZE=$(du -h "${OUTPUT_DIR}/db/trivy.db" | cut -f1)
    echo "[$(date +%T)] ✓ Database created successfully"
    echo "  Location: ${OUTPUT_DIR}/db/trivy.db"
    echo "  Size: ${DB_SIZE}"
    
    # Create metadata file
    cat > "${OUTPUT_DIR}/db/metadata.json" <<EOF
{
  "version": 2,
  "nextUpdate": "$(date -u -d "+${UPDATE_INTERVAL}" +%Y-%m-%dT%H:%M:%SZ)",
  "updatedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "downloadedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
    
    # Compress the database
    echo "[$(date +%T)] Compressing database..."
    cd "${OUTPUT_DIR}/db"
    tar czf trivy.db.tar.gz trivy.db metadata.json
    
    COMPRESSED_SIZE=$(du -h trivy.db.tar.gz | cut -f1)
    echo "[$(date +%T)] ✓ Database compressed"
    echo "  Location: ${OUTPUT_DIR}/db/trivy.db.tar.gz"
    echo "  Size: ${COMPRESSED_SIZE}"
    
    # Calculate checksums
    echo "[$(date +%T)] Generating checksums..."
    sha256sum trivy.db > trivy.db.sha256
    sha256sum trivy.db.tar.gz > trivy.db.tar.gz.sha256
    
    echo ""
    echo "=========================================="
    echo "Build Summary"
    echo "=========================================="
    echo "Database: ${OUTPUT_DIR}/db/trivy.db (${DB_SIZE})"
    echo "Compressed: ${OUTPUT_DIR}/db/trivy.db.tar.gz (${COMPRESSED_SIZE})"
    echo "Metadata: ${OUTPUT_DIR}/db/metadata.json"
    echo "Checksums: ${OUTPUT_DIR}/db/*.sha256"
    echo ""
    echo "✓ Build completed successfully at $(date)"
    
else
    echo "[$(date +%T)] ✗ ERROR: Database file not found"
    exit 1
fi

# Optional: Clean up cache to save space (comment out if you want to keep cache)
# echo "[$(date +%T)] Cleaning up cache..."
# rm -rf "${CACHE_DIR}"/*

exit 0
