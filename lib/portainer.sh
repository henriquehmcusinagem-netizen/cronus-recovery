#!/bin/bash
#
# Portainer restore functions for Cronus recovery
#

PORTAINER_IMAGE="portainer/portainer-ce:latest"
PORTAINER_VOLUME="portainer_data"
PORTAINER_CONTAINER="portainer"

# Check if Portainer backup exists in extracted backup
portainer_backup_exists() {
    local backup_dir=$1
    [[ -f "$backup_dir/portainer-backup.tar.gz" ]]
}

# Stop and remove existing Portainer container
stop_existing_portainer() {
    if docker ps -a --format '{{.Names}}' | grep -q "^${PORTAINER_CONTAINER}$"; then
        log "Stopping existing Portainer container..."
        docker stop "$PORTAINER_CONTAINER" &>/dev/null || true
        docker rm "$PORTAINER_CONTAINER" &>/dev/null || true
    fi
}

# Restore Portainer from backup
restore_portainer() {
    local backup_dir=$1
    local portainer_backup="$backup_dir/portainer-backup.tar.gz"

    if [[ ! -f "$portainer_backup" ]]; then
        warn "No Portainer backup found, skipping Portainer restore"
        return 1
    fi

    log "Found Portainer backup, starting automatic restore..."

    # Step 1: Stop existing Portainer
    stop_existing_portainer

    # Step 2: Remove old volume if exists and create new one
    log "Preparing Portainer volume..."
    if docker volume inspect "$PORTAINER_VOLUME" &>/dev/null; then
        warn "Removing existing Portainer volume..."
        docker volume rm "$PORTAINER_VOLUME" &>/dev/null || true
    fi
    docker volume create "$PORTAINER_VOLUME"

    # Step 3: Extract backup directly into volume
    log "Extracting Portainer backup into volume..."
    docker run --rm \
        -v "$PORTAINER_VOLUME":/data \
        -v "$portainer_backup":/backup.tar.gz:ro \
        alpine sh -c "cd /data && tar -xzf /backup.tar.gz --strip-components=0 2>/dev/null || tar -xzf /backup.tar.gz"

    if [[ $? -ne 0 ]]; then
        error "Failed to extract Portainer backup"
        return 1
    fi

    success "Portainer data restored to volume"

    # Step 4: Start Portainer container
    log "Starting Portainer container..."
    docker run -d \
        --name "$PORTAINER_CONTAINER" \
        --restart=always \
        -p 9443:9443 \
        -p 9000:9000 \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v "$PORTAINER_VOLUME":/data \
        "$PORTAINER_IMAGE"

    if [[ $? -ne 0 ]]; then
        error "Failed to start Portainer container"
        return 1
    fi

    # Step 5: Wait for Portainer to be ready
    log "Waiting for Portainer to be ready..."
    local max_wait=60
    local waited=0

    while [[ $waited -lt $max_wait ]]; do
        if curl -sk https://localhost:9443/api/status &>/dev/null || \
           curl -s http://localhost:9000/api/status &>/dev/null; then
            success "Portainer is ready!"
            echo ""
            log "Access Portainer at: https://localhost:9443"
            log "All your stacks and configurations have been restored."
            echo ""
            return 0
        fi
        sleep 2
        waited=$((waited + 2))
    done

    warn "Portainer may not be fully ready yet, but container is running"
    log "Access Portainer at: https://localhost:9443"
    return 0
}

# Redeploy all stacks in Portainer (via API)
redeploy_portainer_stacks() {
    local portainer_url=${1:-"https://localhost:9443"}

    warn "Stack redeploy via API requires authentication"
    log "Please manually redeploy stacks via Portainer UI at: $portainer_url"
    log "Go to Stacks -> Select each stack -> Update the stack"
}
