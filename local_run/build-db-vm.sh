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

# Lock file to prevent multiple instances
LOCK_FILE="/tmp/build-db-vm.lock"

# Cleanup function to remove lock file and tmp directory
cleanup() {
    local exit_code=$?
    
    # Clean up temporary output directory if it exists
    if [ -n "${TMP_OUTPUT_DIR:-}" ] && [ -d "${TMP_OUTPUT_DIR}" ]; then
        echo ""
        echo "[$(date +%T)] Cleaning up temporary directory..."
        rm -rf "${TMP_OUTPUT_DIR}"
    fi
    
    # Remove lock file
    if [ -f "${LOCK_FILE}" ]; then
        rm -f "${LOCK_FILE}"
        echo "[$(date +%T)] Lock file removed"
    fi
    
    # Display build time and status on exit
    if [ -n "${BUILD_START_TIME:-}" ]; then
        BUILD_END_TIME=$(date +%s)
        BUILD_DURATION=$((BUILD_END_TIME - BUILD_START_TIME))
        
        if [ $exit_code -ne 0 ]; then
            echo ""
            if [ $exit_code -eq 130 ] || [ $exit_code -eq 143 ]; then
                # 130 = SIGINT (Ctrl+C), 143 = SIGTERM (kill)
                echo "⚠ Build interrupted after ${BUILD_DURATION} seconds"
            else
                echo "✗ Build failed after ${BUILD_DURATION} seconds (exit code: $exit_code)"
            fi
        elif [ "${BUILD_SUCCESS}" != "true" ]; then
            echo ""
            echo "⚠ Build incomplete after ${BUILD_DURATION} seconds"
        fi
    fi
    
    exit ${exit_code}
}

# Set trap to ensure cleanup on exit
trap cleanup INT TERM

# Check if another instance is running
if [ -f "${LOCK_FILE}" ]; then
    echo "[$(date +%T)] ✗ ERROR: Another instance is already running (lock file exists: ${LOCK_FILE})" >&2
    echo "  If no other instance is running, remove the lock file manually: rm ${LOCK_FILE}" >&2
    exit 1
fi

# Create lock file
echo "$$" > "${LOCK_FILE}"
echo "[$(date +%T)] Lock acquired (PID: $$)"

# Record build start time
BUILD_START_TIME=$(date +%s)

# Flag to track successful completion
BUILD_SUCCESS=false

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

# Create temporary output directory for atomic deployment
TMP_OUTPUT_DIR="${OUTPUT_DIR}.tmp.$$"
mkdir -p "${TMP_OUTPUT_DIR}"
echo "Temporary build directory: ${TMP_OUTPUT_DIR}"
echo ""

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
echo "  Temp output dir: ${TMP_OUTPUT_DIR}"
echo "  Update interval: ${UPDATE_INTERVAL}"
echo ""

./trivy-db build \
    --cache-dir "${CACHE_DIR}" \
    --output-dir "${TMP_OUTPUT_DIR}" \
    --update-interval "${UPDATE_INTERVAL}"

# Step 4: Verify and compress
echo ""
echo "=========================================="
echo "Step 4: Post-processing"
echo "=========================================="

if [ -f "${TMP_OUTPUT_DIR}/trivy.db" ]; then
    DB_SIZE_BEFORE=$(du -h "${TMP_OUTPUT_DIR}/trivy.db" | cut -f1)
    echo "[$(date +%T)] ✓ Database created successfully"
    echo "  Location: ${TMP_OUTPUT_DIR}/trivy.db"
    echo "  Size (before compaction): ${DB_SIZE_BEFORE}"
    
    # Compact the database
    echo "[$(date +%T)] Compacting database..."
    if command -v bbolt >/dev/null 2>&1; then
        TEMP_DB="${TMP_OUTPUT_DIR}/trivy.db.tmp"
        bbolt compact -o "${TEMP_DB}" "${TMP_OUTPUT_DIR}/trivy.db"
        mv "${TEMP_DB}" "${TMP_OUTPUT_DIR}/trivy.db"
        DB_SIZE=$(du -h "${TMP_OUTPUT_DIR}/trivy.db" | cut -f1)
        echo "[$(date +%T)] ✓ Database compacted"
        echo "  Size (after compaction): ${DB_SIZE}"
    else
        echo "[$(date +%T)] ⚠ Warning: bbolt not found, skipping compaction"
        echo "  To enable compaction: go install go.etcd.io/bbolt/cmd/bbolt@latest"
        DB_SIZE="${DB_SIZE_BEFORE}"
    fi
    
    # Create metadata file
    cat > "${TMP_OUTPUT_DIR}/metadata.json" <<EOF
{
  "version": 2,
  "nextUpdate": "$(date -u -d "+1 day" +%Y-%m-%dT%H:%M:%SZ)",
  "updatedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "downloadedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
    
    # Compress the database
    echo "[$(date +%T)] Compressing database..."
    cd "${TMP_OUTPUT_DIR}"
    tar czf trivy.db.tar.gz trivy.db metadata.json
    
    COMPRESSED_SIZE=$(du -h trivy.db.tar.gz | cut -f1)
    echo "[$(date +%T)] ✓ Database compressed"
    echo "  Location: ${TMP_OUTPUT_DIR}/trivy.db.tar.gz"
    echo "  Size: ${COMPRESSED_SIZE}"
    
    # Calculate checksums
    echo "[$(date +%T)] Generating checksums..."
    sha256sum trivy.db > trivy.db.sha256
    sha256sum trivy.db.tar.gz > trivy.db.tar.gz.sha256
    
    # Step 5: Atomic deployment
    echo ""
    echo "=========================================="
    echo "Step 5: Deploying database"
    echo "=========================================="
    
    echo "[$(date +%T)] Moving build to final location..."
    
    # Backup existing database if it exists
    if [ -d "${OUTPUT_DIR}" ] && [ -f "${OUTPUT_DIR}/trivy.db" ]; then
        BACKUP_DIR="${OUTPUT_DIR}.backup.$(date +%s)"
        echo "  Creating backup: ${BACKUP_DIR}"
        mv "${OUTPUT_DIR}" "${BACKUP_DIR}"
        
        # Keep only the last 2 backups
        ls -dt "${OUTPUT_DIR}".backup.* 2>/dev/null | tail -n +3 | xargs rm -rf 2>/dev/null || true
    fi
    
    # Move new build to final location
    mv "${TMP_OUTPUT_DIR}" "${OUTPUT_DIR}"
    echo "[$(date +%T)] ✓ Database deployed successfully"
    
    # Calculate and display build time
    BUILD_END_TIME=$(date +%s)
    BUILD_DURATION=$((BUILD_END_TIME - BUILD_START_TIME))
    BUILD_HOURS=$((BUILD_DURATION / 3600))
    BUILD_MINUTES=$(((BUILD_DURATION % 3600) / 60))
    BUILD_SECONDS=$((BUILD_DURATION % 60))
    
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
    # Mark build as successful
    BUILD_SUCCESS=true
    
    printf "Build time: "
    if [ $BUILD_HOURS -gt 0 ]; then
        printf "%dh %dm %ds\n" $BUILD_HOURS $BUILD_MINUTES $BUILD_SECONDS
    elif [ $BUILD_MINUTES -gt 0 ]; then
        printf "%dm %ds\n" $BUILD_MINUTES $BUILD_SECONDS
    else
        printf "%ds\n" $BUILD_SECONDS
    fi
    echo ""
    echo "✓ Build completed successfully at $(date)"
    
else
    echo "[$(date +%T)] ✗ ERROR: Database file not found"
    # Clean up temporary directory
    rm -rf "${TMP_OUTPUT_DIR}"
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

cleanup
exit 0
