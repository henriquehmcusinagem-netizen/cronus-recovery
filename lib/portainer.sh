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

# Get Portainer JWT token
portainer_authenticate() {
    local portainer_url=$1
    local username=$2
    local password=$3

    local response=$(curl -sk -X POST "${portainer_url}/api/auth" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"${username}\",\"password\":\"${password}\"}" 2>/dev/null)

    echo "$response" | jq -r '.jwt // empty' 2>/dev/null
}

# Get endpoint ID (usually 1 for local Docker)
portainer_get_endpoint_id() {
    local portainer_url=$1
    local token=$2

    local response=$(curl -sk -X GET "${portainer_url}/api/endpoints" \
        -H "Authorization: Bearer ${token}" 2>/dev/null)

    echo "$response" | jq -r '.[0].Id // empty' 2>/dev/null
}

# List all stacks
portainer_list_stacks() {
    local portainer_url=$1
    local token=$2

    curl -sk -X GET "${portainer_url}/api/stacks" \
        -H "Authorization: Bearer ${token}" 2>/dev/null
}

# Redeploy a single stack
portainer_redeploy_stack() {
    local portainer_url=$1
    local token=$2
    local stack_id=$3
    local endpoint_id=$4

    # Get stack details first
    local stack_info=$(curl -sk -X GET "${portainer_url}/api/stacks/${stack_id}" \
        -H "Authorization: Bearer ${token}" 2>/dev/null)

    local stack_name=$(echo "$stack_info" | jq -r '.Name // empty')
    local env_vars=$(echo "$stack_info" | jq -c '.Env // []')

    # Get stack file content
    local stack_file=$(curl -sk -X GET "${portainer_url}/api/stacks/${stack_id}/file" \
        -H "Authorization: Bearer ${token}" 2>/dev/null | jq -r '.StackFileContent // empty')

    if [[ -z "$stack_file" ]]; then
        warn "Could not get stack file for stack $stack_id"
        return 1
    fi

    # Redeploy stack
    local response=$(curl -sk -X PUT "${portainer_url}/api/stacks/${stack_id}?endpointId=${endpoint_id}" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        -d "{\"stackFileContent\":$(echo "$stack_file" | jq -Rs .),\"env\":${env_vars},\"prune\":false}" 2>/dev/null)

    local error=$(echo "$response" | jq -r '.message // empty' 2>/dev/null)
    if [[ -n "$error" ]]; then
        warn "Failed to redeploy $stack_name: $error"
        return 1
    fi

    return 0
}

# Create networks for a stack before deploying
create_stack_networks() {
    local portainer_url=$1
    local token=$2
    local stack_id=$3
    local stack_name=$4

    # Get stack file content
    local stack_file=$(curl -sk -X GET "${portainer_url}/api/stacks/${stack_id}/file" \
        -H "Authorization: Bearer ${token}" 2>/dev/null | jq -r '.StackFileContent // empty')

    if [[ -z "$stack_file" ]]; then
        return 0
    fi

    # Extract network names from the stack file
    local networks=$(echo "$stack_file" | grep -E "^\s+[a-zA-Z0-9_-]+-network:" | sed 's/://g' | awk '{print $1}')

    for network in $networks; do
        local full_network_name="${stack_name}_${network}"

        # Check if network exists
        if ! docker network inspect "$full_network_name" &>/dev/null; then
            log "  Creating network: $full_network_name"
            docker network create \
                --label "com.docker.compose.network=${network}" \
                --label "com.docker.compose.project=${stack_name}" \
                --label "com.docker.compose.version=2.21.0" \
                "$full_network_name" &>/dev/null || true
        fi
    done
}

# Create all required networks before deployment
create_all_stack_networks() {
    local portainer_url=$1
    local token=$2
    local stacks=$3

    log "Pre-creating Docker networks for all stacks..."
    echo ""

    for stack_id in $(echo "$stacks" | jq -r '.[].Id'); do
        local stack_name=$(echo "$stacks" | jq -r ".[] | select(.Id==$stack_id) | .Name")
        create_stack_networks "$portainer_url" "$token" "$stack_id" "$stack_name"
    done

    success "Networks created"
    echo ""
}

# Wait for PostgreSQL container to be healthy
wait_for_postgres_healthy() {
    local container_name=$1
    local max_wait=${2:-120}
    local waited=0

    log "Waiting for PostgreSQL ($container_name) to be healthy..."

    while [[ $waited -lt $max_wait ]]; do
        local health=$(docker inspect --format='{{.State.Health.Status}}' "$container_name" 2>/dev/null)

        if [[ "$health" == "healthy" ]]; then
            success "PostgreSQL is healthy!"
            return 0
        fi

        # Also check if it can accept connections
        if docker exec "$container_name" pg_isready -U postgres &>/dev/null; then
            success "PostgreSQL is ready (pg_isready)!"
            return 0
        fi

        sleep 3
        waited=$((waited + 3))
        echo -n "."
    done

    echo ""
    warn "Timeout waiting for PostgreSQL to be healthy"
    return 1
}

# Deploy stacks by name list
deploy_stacks_by_names() {
    local portainer_url=$1
    local token=$2
    local endpoint_id=$3
    local stacks=$4
    shift 4
    local stack_names=("$@")

    local deployed=0

    for name in "${stack_names[@]}"; do
        local stack_id=$(echo "$stacks" | jq -r ".[] | select(.Name==\"$name\") | .Id")

        if [[ -z "$stack_id" ]]; then
            warn "Stack not found: $name"
            continue
        fi

        # Create networks first
        create_stack_networks "$portainer_url" "$token" "$stack_id" "$name"

        log "Deploying: $name..."
        if portainer_redeploy_stack "$portainer_url" "$token" "$stack_id" "$endpoint_id"; then
            success "  $name deployed"
            deployed=$((deployed + 1))
        else
            error "  Failed to deploy $name"
        fi

        sleep 3
    done

    return $deployed
}

# Deploy remaining stacks (excluding already deployed ones)
deploy_remaining_stacks() {
    local portainer_url=$1
    local token=$2
    local endpoint_id=$3
    local stacks=$4
    shift 4
    local exclude_names=("$@")

    local deployed=0

    for stack_id in $(echo "$stacks" | jq -r '.[].Id'); do
        local stack_name=$(echo "$stacks" | jq -r ".[] | select(.Id==$stack_id) | .Name")

        # Skip if in exclude list
        local skip=false
        for exclude in "${exclude_names[@]}"; do
            if [[ "$stack_name" == "$exclude" ]]; then
                skip=true
                break
            fi
        done

        if [[ "$skip" == "true" ]]; then
            continue
        fi

        # Create networks first
        create_stack_networks "$portainer_url" "$token" "$stack_id" "$stack_name"

        log "Deploying: $stack_name..."
        if portainer_redeploy_stack "$portainer_url" "$token" "$stack_id" "$endpoint_id"; then
            success "  $stack_name deployed"
            deployed=$((deployed + 1))
        fi

        sleep 3
    done

    return $deployed
}

# NEW PHASED DEPLOYMENT FLOW
# Phase 1: Deploy alexandria + ducks-ecosystem
# Phase 2: Wait for PostgreSQL healthy
# Phase 3: Restore database dumps
# Phase 4: Deploy argos via Ducks API
# Phase 5: Deploy remaining stacks
phased_redeploy() {
    local portainer_url=${1:-"https://localhost:9443"}
    local manifest_file=$2
    local data_dir=$3

    echo ""
    log "============================================"
    log "   PHASED STACK DEPLOYMENT"
    log "============================================"
    echo ""
    log "Phase 1: Deploy infrastructure (alexandria, ducks-ecosystem)"
    log "Phase 2: Wait for databases to be healthy"
    log "Phase 3: Restore database dumps"
    log "Phase 4: Deploy argos via Ducks API"
    log "Phase 5: Deploy remaining stacks"
    echo ""

    # Ask for credentials
    read -p "Portainer username: " PORTAINER_USER
    read -sp "Portainer password: " PORTAINER_PASS
    echo ""

    if [[ -z "$PORTAINER_USER" ]] || [[ -z "$PORTAINER_PASS" ]]; then
        warn "No credentials provided, aborting"
        return 1
    fi

    # Authenticate
    log "Authenticating with Portainer..."
    local token=$(portainer_authenticate "$portainer_url" "$PORTAINER_USER" "$PORTAINER_PASS")

    if [[ -z "$token" ]]; then
        error "Authentication failed. Check your credentials."
        return 1
    fi

    success "Authenticated successfully"

    # Get endpoint ID
    local endpoint_id=$(portainer_get_endpoint_id "$portainer_url" "$token")
    if [[ -z "$endpoint_id" ]]; then
        error "Could not get endpoint ID"
        return 1
    fi

    # List stacks
    log "Fetching stacks..."
    local stacks=$(portainer_list_stacks "$portainer_url" "$token")
    local stack_count=$(echo "$stacks" | jq 'length' 2>/dev/null)

    if [[ -z "$stack_count" ]] || [[ "$stack_count" == "0" ]]; then
        warn "No stacks found"
        return 0
    fi

    log "Found $stack_count stack(s)"
    echo ""

    # ============================================
    # PHASE 1: Deploy alexandria + ducks-ecosystem
    # ============================================
    echo ""
    log "============================================"
    log "   PHASE 1: Infrastructure Stacks"
    log "============================================"
    echo ""

    deploy_stacks_by_names "$portainer_url" "$token" "$endpoint_id" "$stacks" "alexandria" "ducks-ecosystem"

    # Wait for containers to start
    sleep 10

    # ============================================
    # PHASE 2: Wait for PostgreSQL to be healthy
    # ============================================
    echo ""
    log "============================================"
    log "   PHASE 2: Wait for Databases"
    log "============================================"
    echo ""

    # Find postgres container from ducks-ecosystem
    local pg_container=$(docker ps --format '{{.Names}}' | grep -E 'ducks-ecosystem.*postgres' | head -1)

    if [[ -n "$pg_container" ]]; then
        wait_for_postgres_healthy "$pg_container" 120
    else
        warn "PostgreSQL container not found, waiting 30s..."
        sleep 30
    fi

    # ============================================
    # PHASE 3: Restore database dumps
    # ============================================
    echo ""
    log "============================================"
    log "   PHASE 3: Restore Database Dumps"
    log "============================================"
    echo ""

    if [[ -n "$manifest_file" ]] && [[ -n "$data_dir" ]]; then
        restore_databases_from_manifest "$manifest_file" "$data_dir" ""
    else
        warn "No manifest/data provided, skipping database restore"
    fi

    # ============================================
    # PHASE 4: Deploy argos via Ducks API
    # ============================================
    echo ""
    log "============================================"
    log "   PHASE 4: Deploy Argos"
    log "============================================"
    echo ""

    # Try via Ducks API first (if ducks-ecosystem is running)
    local ducks_api="http://localhost:8700"

    # Check if Ducks API is available
    if curl -s "${ducks_api}/health" &>/dev/null; then
        log "Ducks API is available, deploying argos via API..."

        # Get argos project ID
        local argos_project=$(curl -s "${ducks_api}/api/projects" 2>/dev/null | jq -r '.[] | select(.name=="argos") | .id // empty')

        if [[ -n "$argos_project" ]]; then
            log "Found argos project: $argos_project"
            # Trigger deploy via Ducks API
            curl -s -X POST "${ducks_api}/api/projects/${argos_project}/deploy" &>/dev/null || true
            success "Argos deploy triggered via Ducks API"
        else
            warn "Argos project not found in Ducks, deploying via Portainer..."
            deploy_stacks_by_names "$portainer_url" "$token" "$endpoint_id" "$stacks" "argos"
        fi
    else
        log "Ducks API not available, deploying argos via Portainer..."
        deploy_stacks_by_names "$portainer_url" "$token" "$endpoint_id" "$stacks" "argos"
    fi

    sleep 10

    # ============================================
    # PHASE 5: Deploy remaining stacks
    # ============================================
    echo ""
    log "============================================"
    log "   PHASE 5: Remaining Stacks"
    log "============================================"
    echo ""

    deploy_remaining_stacks "$portainer_url" "$token" "$endpoint_id" "$stacks" "alexandria" "ducks-ecosystem" "argos"

    # Final summary
    echo ""
    log "============================================"
    success "   DEPLOYMENT COMPLETE!"
    log "============================================"
    echo ""

    return 0
}

# Keep old function for backwards compatibility
redeploy_portainer_stacks() {
    local portainer_url=${1:-"https://localhost:9443"}
    local manifest_file=$2
    local data_dir=$3

    # Use new phased deployment
    phased_redeploy "$portainer_url" "$manifest_file" "$data_dir"
}
