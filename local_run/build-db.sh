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

# Lock file to prevent multiple instances
LOCK_FILE="/tmp/build-db.lock"

# Cleanup function to remove lock file
cleanup() {
    local exit_code=$?
    if [ -f "${LOCK_FILE}" ]; then
        rm -f "${LOCK_FILE}"
        echo ""
        echo "[$(date +%T)] Lock file removed"
    fi
    exit ${exit_code}
}

# Set trap to ensure cleanup on exit
trap cleanup EXIT INT TERM

# Check if another instance is running
if [ -f "${LOCK_FILE}" ]; then
    echo "[$(date +%T)] ✗ ERROR: Another instance is already running (lock file exists: ${LOCK_FILE})" >&2
    echo "  If no other instance is running, remove the lock file manually: rm ${LOCK_FILE}" >&2
    exit 1
fi

# Create lock file
echo "$$" > "${LOCK_FILE}"
echo "[$(date +%T)] Lock acquired (PID: $$)"

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

# Function to clone or update a git repository from GitLab
git_clone_or_update_gitlab() {
    local repo_name=$1
    local target_dir="${CACHE_DIR}/${repo_name}"
    local branch="${2:-main}"
    local git_url="${GITLAB_BASE_URL}/${GITLAB_GROUP}/${repo_name}.git"
    local auth_url="${git_url/\/\//\/\/oauth2:${GITLAB_TOKEN}@}"
    
    echo "[$(date +%T)] Processing ${repo_name}..."
    
    if [ -d "${target_dir}/.git" ]; then
        echo "  Repository exists at ${target_dir}"
        echo "  Updating repository..."
        cd "${target_dir}"
        git fetch origin
        git reset --hard "origin/${branch}" || git reset --hard "origin/master" || true
        cd - > /dev/null
        echo "  ✓ Updated"
    else
        echo "  Cloning repository..."
        git clone --depth 1 -b "${branch}" "${auth_url}" "${target_dir}" 2>/dev/null || \
        git clone --depth 1 "${auth_url}" "${target_dir}"
        echo "  ✓ Cloned"
    fi
}

# Function to clone or update a git repository from GitHub
git_clone_or_update() {
    local repo_url=$1
    local target_dir=$2
    local branch="${3:-main}"
    
    local repo_name=$(basename "${target_dir}")
    
    echo "[$(date +%T)] Processing ${repo_name}..."
    
    if [ -d "${target_dir}/.git" ]; then
        echo "  Repository exists at ${target_dir}"
        echo "  Updating repository..."
        cd "${target_dir}"
        git fetch origin
        git reset --hard "origin/${branch}" || git reset --hard "origin/master" || true
        cd - > /dev/null
        echo "  ✓ Updated"
    else
        echo "  Cloning repository..."
        git clone --depth 1 -b "${branch}" "${repo_url}" "${target_dir}" 2>/dev/null || \
        git clone --depth 1 "${repo_url}" "${target_dir}"
        echo "  ✓ Cloned"
    fi
}

# Step 1: Fetch vuln-list repositories from GitLab
echo ""
echo "=========================================="
echo "Step 1: Fetching vuln-list repositories"
echo "=========================================="

git_clone_or_update_gitlab "vuln-list" "main"
git_clone_or_update_gitlab "vuln-list-redhat" "main"
git_clone_or_update_gitlab "vuln-list-debian" "main"
git_clone_or_update_gitlab "vuln-list-nvd" "main"

# Optional: vuln-list-aqua (if you have it)
echo "[$(date +%T)] Checking for vuln-list-aqua..."
if curl -sf -H "Authorization: Bearer ${GITLAB_TOKEN}" \
    "${GITLAB_BASE_URL}/api/v4/projects/${GITLAB_GROUP}%2Fvuln-list-aqua" > /dev/null 2>&1; then
    git_clone_or_update_gitlab "vuln-list-aqua" "main"
    echo "  ✓ vuln-list-aqua found and processed"
else
    echo "  ℹ vuln-list-aqua not found (optional)"
fi

# Step 2: Fetch language-specific advisory databases
echo ""
echo "=========================================="
echo "Step 2: Fetching language advisory databases"
echo "=========================================="

# Ruby
git_clone_or_update \
    "https://github.com/rubysec/ruby-advisory-db.git" \
    "${CACHE_DIR}/ruby-advisory-db" \
    "master"

# PHP
git_clone_or_update \
    "https://github.com/FriendsOfPHP/security-advisories.git" \
    "${CACHE_DIR}/php-security-advisories" \
    "master"

# Node.js
git_clone_or_update \
    "https://github.com/nodejs/security-wg.git" \
    "${CACHE_DIR}/nodejs-security-wg" \
    "main"

# Bitnami
git_clone_or_update \
    "https://github.com/bitnami/vulndb.git" \
    "${CACHE_DIR}/bitnami-vulndb" \
    "main"

# GHSA (GitHub Security Advisories)
git_clone_or_update \
    "https://github.com/github/advisory-database.git" \
    "${CACHE_DIR}/ghsa" \
    "main"

# Go vulnerability database
git_clone_or_update \
    "https://github.com/golang/vulndb.git" \
    "${CACHE_DIR}/govulndb" \
    "master"

# CocoaPods (for Swift/Objective-C package mapping)
echo "[$(date +%T)] Processing CocoaPods specs..."
echo "  (Note: This is a large repository, initial clone may take time)"
git_clone_or_update \
    "https://github.com/CocoaPods/Specs.git" \
    "${CACHE_DIR}/cocoapods-specs" \
    "master"

# Kubernetes CVE feed
git_clone_or_update \
    "https://github.com/kubernetes-sigs/cve-feed-osv.git" \
    "${CACHE_DIR}/k8s-cve-feed" \
    "main"

# Julia
echo "[$(date +%T)] Processing Julia security advisories..."
if git ls-remote --exit-code https://github.com/JuliaLang/SecurityAdvisories.jl.git generated/osv > /dev/null 2>&1; then
    git_clone_or_update \
        "https://github.com/JuliaLang/SecurityAdvisories.jl.git" \
        "${CACHE_DIR}/julia" \
        "generated/osv"
else
    # Fallback to main branch if generated/osv doesn't exist
    git_clone_or_update \
        "https://github.com/JuliaLang/SecurityAdvisories.jl.git" \
        "${CACHE_DIR}/julia" \
        "main"
fi

# Step 3: Build the database
echo ""
echo "=========================================="
echo "Step 3: Building Trivy database"
echo "=========================================="

TRIVY_DB_DIR="${TRIVY_DB_DIR:-/app}"
cd "${TRIVY_DB_DIR}"

# Check if trivy-db binary exists
if [ -f "./trivy-db" ] && [ -x "./trivy-db" ]; then
    echo "[$(date +%T)] Using existing trivy-db binary"
else
    echo "[$(date +%T)] Binary not found, building..."
    if command -v go >/dev/null 2>&1; then
        echo "[$(date +%T)] Building trivy-db binary..."
        go build -o trivy-db ./cmd/trivy-db
        echo "[$(date +%T)] ✓ Build completed"
    else
        echo "[$(date +%T)] ✗ ERROR: trivy-db binary not found and Go compiler not available" >&2
        echo "  Please install Go or build the binary separately" >&2
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

if [ -f "${OUTPUT_DIR}/trivy.db" ]; then
    DB_SIZE_BEFORE=$(du -h "${OUTPUT_DIR}/trivy.db" | cut -f1)
    echo "[$(date +%T)] ✓ Database created successfully"
    echo "  Location: ${OUTPUT_DIR}/trivy.db"
    echo "  Size (before compaction): ${DB_SIZE_BEFORE}"
    
    # Compact the database
    echo "[$(date +%T)] Compacting database..."
    if command -v bbolt >/dev/null 2>&1; then
        TEMP_DB="${OUTPUT_DIR}/trivy.db.tmp"
        bbolt compact -o "${TEMP_DB}" "${OUTPUT_DIR}/trivy.db"
        mv "${TEMP_DB}" "${OUTPUT_DIR}/trivy.db"
        DB_SIZE=$(du -h "${OUTPUT_DIR}/trivy.db" | cut -f1)
        echo "[$(date +%T)] ✓ Database compacted"
        echo "  Size (after compaction): ${DB_SIZE}"
    else
        echo "[$(date +%T)] ⚠ Warning: bbolt not found, skipping compaction"
        echo "  To enable compaction: go install go.etcd.io/bbolt/cmd/bbolt@latest"
        DB_SIZE="${DB_SIZE_BEFORE}"
    fi
    
    # Create metadata file
    cat > "${OUTPUT_DIR}/metadata.json" <<EOF
{
  "version": 2,
  "nextUpdate": "$(date -u -d "+1 day" +%Y-%m-%dT%H:%M:%SZ)",
  "updatedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "downloadedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
    
    # Compress the database
    echo "[$(date +%T)] Compressing database..."
    cd "${OUTPUT_DIR}"
    tar czf trivy.db.tar.gz trivy.db metadata.json
    
    COMPRESSED_SIZE=$(du -h trivy.db.tar.gz | cut -f1)
    echo "[$(date +%T)] ✓ Database compressed"
    echo "  Location: ${OUTPUT_DIR}/trivy.db.tar.gz"
    echo "  Size: ${COMPRESSED_SIZE}"
    
    # Calculate checksums
    echo "[$(date +%T)] Generating checksums..."
    sha256sum trivy.db > trivy.db.sha256
    sha256sum trivy.db.tar.gz > trivy.db.tar.gz.sha256
    
    echo ""
    echo "=========================================="
    echo "Build Summary"
    echo "=========================================="
    echo "Database: ${OUTPUT_DIR}/trivy.db (${DB_SIZE})"
    echo "Compressed: ${OUTPUT_DIR}/trivy.db.tar.gz (${COMPRESSED_SIZE})"
    echo "Metadata: ${OUTPUT_DIR}/metadata.json"
    echo "Checksums: ${OUTPUT_DIR}/*.sha256"
    echo ""
    echo "Repository cache: ${CACHE_DIR}"
    echo "  (Repositories are preserved for future updates)"
    echo ""
    echo "✓ Build completed successfully at $(date)"
    
else
    echo "[$(date +%T)] ✗ ERROR: Database file not found"
    exit 1
fi

echo ""
echo "=========================================="
echo "Next Steps"
echo "=========================================="
echo "To update the database later, simply run this script again."
echo "Repositories will be updated automatically (git pull)."
echo ""

exit 0
