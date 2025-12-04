#!/bin/bash
#
# Cronus Server Recovery Script
# Restores a full server backup created by Cronus
#
# Usage: ./restore.sh <backup.tar.gz> [options]
#
# Options:
#   --skip-networks     Do not create Docker networks
#   --skip-databases    Skip database restoration
#   --skip-compose      Do not run docker-compose up
#   --skip-portainer    Skip Portainer restoration
#   --dry-run           Show what would be done without executing
#   --container NAME    Restore only specific container
#   -h, --help          Show this help message
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source library functions
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/docker.sh"
source "$SCRIPT_DIR/lib/network.sh"
source "$SCRIPT_DIR/lib/volume.sh"
source "$SCRIPT_DIR/lib/database.sh"
source "$SCRIPT_DIR/lib/portainer.sh"

# Default options
SKIP_NETWORKS=false
SKIP_DATABASES=false
SKIP_COMPOSE=false
SKIP_PORTAINER=false
DRY_RUN=false
CONTAINER_FILTER=""

# Parse arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --skip-networks)
                SKIP_NETWORKS=true
                shift
                ;;
            --skip-databases)
                SKIP_DATABASES=true
                shift
                ;;
            --skip-compose)
                SKIP_COMPOSE=true
                shift
                ;;
            --skip-portainer)
                SKIP_PORTAINER=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --container)
                CONTAINER_FILTER="$2"
                shift 2
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            -*)
                error "Unknown option: $1"
                show_help
                exit 1
                ;;
            *)
                BACKUP_FILE="$1"
                shift
                ;;
        esac
    done
}

show_help() {
    echo "Cronus Server Recovery Script"
    echo ""
    echo "Usage: ./restore.sh <backup.tar.gz> [options]"
    echo ""
    echo "Options:"
    echo "  --skip-networks     Do not create Docker networks"
    echo "  --skip-databases    Skip database restoration"
    echo "  --skip-compose      Do not run docker-compose up"
    echo "  --skip-portainer    Skip Portainer restoration"
    echo "  --dry-run           Show what would be done without executing"
    echo "  --container NAME    Restore only specific container"
    echo "  -h, --help          Show this help message"
    echo ""
    echo "Example:"
    echo "  ./restore.sh server_backup_20241201_143052.tar.gz"
    echo "  ./restore.sh backup.tar.gz --skip-databases"
    echo "  ./restore.sh backup.tar.gz --container postgres"
}

# Main restore function
main() {
    parse_args "$@"

    # Validate backup file
    if [[ -z "$BACKUP_FILE" ]]; then
        error "No backup file specified"
        show_help
        exit 1
    fi

    if [[ ! -f "$BACKUP_FILE" ]]; then
        error "Backup file not found: $BACKUP_FILE"
        exit 1
    fi

    log "Starting Cronus Server Recovery"
    log "Backup file: $BACKUP_FILE"

    # Check prerequisites
    check_prerequisites

    # Create temp directory
    TEMP_DIR=$(mktemp -d)
    trap "rm -rf $TEMP_DIR" EXIT

    log "Extracting backup to $TEMP_DIR..."
    tar -xzf "$BACKUP_FILE" -C "$TEMP_DIR"

    # Read manifest
    MANIFEST_FILE="$TEMP_DIR/manifest.json"
    if [[ ! -f "$MANIFEST_FILE" ]]; then
        error "manifest.json not found in backup"
        exit 1
    fi

    log "Reading manifest..."
    BACKUP_ID=$(jq -r '.id' "$MANIFEST_FILE")
    BACKUP_NAME=$(jq -r '.name // "Unnamed"' "$MANIFEST_FILE")
    TOTAL_CONTAINERS=$(jq -r '.summary.total_containers' "$MANIFEST_FILE")
    PORTAINER_INCLUDED=$(jq -r '.portainer_backup_included // false' "$MANIFEST_FILE")

    log "Backup ID: $BACKUP_ID"
    log "Backup Name: $BACKUP_NAME"
    log "Total Containers: $TOTAL_CONTAINERS"
    log "Portainer Backup: $PORTAINER_INCLUDED"

    if [[ "$DRY_RUN" == "true" ]]; then
        warn "[DRY RUN] Would restore the following:"
        echo ""
        if [[ "$PORTAINER_INCLUDED" == "true" ]]; then
            echo "Portainer: Will be restored automatically"
        fi
        echo ""
        echo "Containers:"
        jq -r '.containers[] | "  \(.container_name) (\(.image))"' "$MANIFEST_FILE" 2>/dev/null || true
        echo ""
        exit 0
    fi

    # Step 1: Restore Portainer (if backup exists)
    if [[ "$SKIP_PORTAINER" != "true" ]]; then
        if portainer_backup_exists "$TEMP_DIR"; then
            echo ""
            log "============================================"
            log "   RESTORING PORTAINER"
            log "============================================"
            restore_portainer "$TEMP_DIR"
            echo ""
        else
            warn "No Portainer backup found in archive"
        fi
    else
        warn "Skipping Portainer restoration"
    fi

    # Step 2: Create networks
    if [[ "$SKIP_NETWORKS" != "true" ]]; then
        log "Creating Docker networks..."
        create_networks_from_manifest "$MANIFEST_FILE" 2>/dev/null || true
    else
        warn "Skipping network creation"
    fi

    # Step 3: Create volumes and restore data
    log "Restoring volumes..."
    restore_volumes_from_manifest "$MANIFEST_FILE" "$TEMP_DIR/data" "$CONTAINER_FILTER"

    # Step 4: Start containers
    if [[ "$SKIP_COMPOSE" != "true" ]]; then
        if [[ "$PORTAINER_INCLUDED" == "true" ]] && [[ "$SKIP_PORTAINER" != "true" ]]; then
            echo ""
            log "============================================"
            log "   REDEPLOY STACKS IN PORTAINER"
            log "============================================"
            echo ""
            log "Portainer has been restored with all your stacks."
            log "Please go to Portainer UI and redeploy each stack:"
            echo ""
            echo "  1. Access https://localhost:9443 (or your server IP)"
            echo "  2. Go to Stacks menu"
            echo "  3. For each stack: click Update the stack"
            echo ""
            echo "This will start all containers using the restored volumes."
            echo ""
            read -p "Press Enter after you have redeployed all stacks..."
        else
            COMPOSE_FILE="$TEMP_DIR/docker-compose.yml"
            if [[ -f "$COMPOSE_FILE" ]]; then
                log "Starting containers with docker-compose..."
                cd "$TEMP_DIR"
                if docker compose version &> /dev/null; then
                    docker compose up -d
                else
                    docker-compose up -d
                fi
                cd - > /dev/null
            else
                warn "docker-compose.yml not found, skipping container startup"
            fi
        fi
    else
        warn "Skipping docker-compose up"
    fi

    # Step 5: Wait for database containers and restore
    if [[ "$SKIP_DATABASES" != "true" ]]; then
        log "Waiting for database containers to be ready..."
        sleep 10

        log "Restoring databases..."
        restore_databases_from_manifest "$MANIFEST_FILE" "$TEMP_DIR/data" "$CONTAINER_FILTER"
    else
        warn "Skipping database restoration"
    fi

    # Final summary
    echo ""
    log "============================================"
    success "   RECOVERY COMPLETE!"
    log "============================================"
    echo ""
    log "Next steps:"
    echo "  1. Verify all containers are running: docker ps"
    echo "  2. Check container logs: docker logs <container>"
    echo "  3. Test your applications"
    echo "  4. Update any external DNS/IP configurations"
    echo ""
    if [[ "$PORTAINER_INCLUDED" == "true" ]]; then
        log "Portainer UI: https://localhost:9443"
    fi
}

# Run main function
main "$@"
