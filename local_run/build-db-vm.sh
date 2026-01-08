#!/bin/bash
set -euo pipefail

# VM-based Trivy DB Builder
# This script builds the Trivy vulnerability database using Aquasecurity's original repos
# Optimized for VMs with persistent storage - repos are cloned once, then updated
#
# Optional environment variables:
#   CACHE_DIR        - Directory to store cloned repositories (default: ./cache)
#   OUTPUT_DIR       - Directory to store the built database (default: ./output)
#   UPDATE_INTERVAL  - Database update interval (default: 3h)
#   SKIP_UPDATE      - Skip git pull operations (default: false)
#   TRIVY_DB_DIR     - Trivy-db repository directory (default: .. - parent directory)

CACHE_DIR="${CACHE_DIR:-./cache}"
OUTPUT_DIR="${OUTPUT_DIR:-./output}"
UPDATE_INTERVAL="${UPDATE_INTERVAL:-3h}"
SKIP_UPDATE="${SKIP_UPDATE:-false}"
TRIVY_DB_DIR="${TRIVY_DB_DIR:-..}"

# Convert to absolute paths (important since we change directories during execution)
CACHE_DIR="$(cd "$(dirname "${CACHE_DIR}")" 2>/dev/null && pwd)/$(basename "${CACHE_DIR}")" || CACHE_DIR="$(realpath -m "${CACHE_DIR}")"
OUTPUT_DIR="$(cd "$(dirname "${OUTPUT_DIR}")" 2>/dev/null && pwd)/$(basename "${OUTPUT_DIR}")" || OUTPUT_DIR="$(realpath -m "${OUTPUT_DIR}")"
TRIVY_DB_DIR="$(cd "${TRIVY_DB_DIR}" 2>/dev/null && pwd)" || TRIVY_DB_DIR="$(realpath -m "${TRIVY_DB_DIR}")"

echo "=== Trivy Database Builder (VM Edition) ==="
echo "Trivy-db directory: ${TRIVY_DB_DIR}"
echo "Cache directory: ${CACHE_DIR}"
echo "Output directory: ${OUTPUT_DIR}"
echo "Update interval: ${UPDATE_INTERVAL}"
echo "Skip updates: ${SKIP_UPDATE}"
echo ""

# Create directories
mkdir -p "${CACHE_DIR}"
mkdir -p "${OUTPUT_DIR}"

# Function to clone or update a git repository
git_clone_or_update() {
    local repo_url=$1
    local target_dir=$2
    local branch="${3:-main}"
    
    local repo_name=$(basename "${target_dir}")
    
    echo "[$(date +%T)] Processing ${repo_name}..."
    
    if [ -d "${target_dir}/.git" ]; then
        echo "  Repository exists at ${target_dir}"
        if [ "${SKIP_UPDATE}" = "false" ]; then
            echo "  Updating repository..."
            cd "${target_dir}"
            git fetch origin
            git reset --hard "origin/${branch}" || git reset --hard "origin/master" || true
            cd - > /dev/null
            echo "  ✓ Updated"
        else
            echo "  ℹ Skipping update (SKIP_UPDATE=true)"
        fi
    else
        echo "  Cloning repository..."
        git clone --depth 1 -b "${branch}" "${repo_url}" "${target_dir}" 2>/dev/null || \
        git clone --depth 1 "${repo_url}" "${target_dir}"
        echo "  ✓ Cloned"
    fi
}

# Step 1: Fetch Aquasecurity vuln-list repositories
echo ""
echo "=========================================="
echo "Step 1: Fetching Aquasecurity vuln-list repositories"
echo "=========================================="

git_clone_or_update \
    "https://github.com/aquasecurity/vuln-list.git" \
    "${CACHE_DIR}/vuln-list" \
    "main"

git_clone_or_update \
    "https://github.com/aquasecurity/vuln-list-redhat.git" \
    "${CACHE_DIR}/vuln-list-redhat" \
    "main"

git_clone_or_update \
    "https://github.com/aquasecurity/vuln-list-debian.git" \
    "${CACHE_DIR}/vuln-list-debian" \
    "main"

git_clone_or_update \
    "https://github.com/aquasecurity/vuln-list-nvd.git" \
    "${CACHE_DIR}/vuln-list-nvd" \
    "main"

# Check if vuln-list-aqua exists
echo "[$(date +%T)] Checking for vuln-list-aqua..."
if git ls-remote --exit-code https://github.com/aquasecurity/vuln-list-aqua.git HEAD > /dev/null 2>&1; then
    git_clone_or_update \
        "https://github.com/aquasecurity/vuln-list-aqua.git" \
        "${CACHE_DIR}/vuln-list-aqua" \
        "main"
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

if [ -f "${OUTPUT_DIR}/db/trivy.db" ]; then
    DB_SIZE=$(du -h "${OUTPUT_DIR}/db/trivy.db" | cut -f1)
    echo "[$(date +%T)] ✓ Database created successfully"
    echo "  Location: ${OUTPUT_DIR}/db/trivy.db"
    echo "  Size: ${DB_SIZE}"
    
    # Create metadata file
    cat > "${OUTPUT_DIR}/db/metadata.json" <<EOF
{
  "version": 2,
  "nextUpdate": "$(date -u -d "+1 day" +%Y-%m-%dT%H:%M:%SZ)",
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
echo "To skip repository updates and just rebuild from cache:"
echo "  SKIP_UPDATE=true $0"
echo ""

exit 0
