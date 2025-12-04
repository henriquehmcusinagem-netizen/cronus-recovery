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

# Redeploy all stacks in Portainer (via API)
redeploy_portainer_stacks() {
    local portainer_url=${1:-"https://localhost:9443"}

    echo ""
    log "============================================"
    log "   AUTO-REDEPLOY STACKS"
    log "============================================"
    echo ""
    log "To automatically redeploy all stacks, enter your Portainer credentials."
    echo ""

    # Ask for credentials
    read -p "Portainer username: " PORTAINER_USER
    read -sp "Portainer password: " PORTAINER_PASS
    echo ""

    if [[ -z "$PORTAINER_USER" ]] || [[ -z "$PORTAINER_PASS" ]]; then
        warn "No credentials provided, skipping auto-redeploy"
        log "You can manually redeploy stacks at: $portainer_url"
        return 1
    fi

    # Authenticate
    log "Authenticating with Portainer..."
    local token=$(portainer_authenticate "$portainer_url" "$PORTAINER_USER" "$PORTAINER_PASS")

    if [[ -z "$token" ]]; then
        error "Authentication failed. Check your credentials."
        log "You can manually redeploy stacks at: $portainer_url"
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
        warn "No stacks found to redeploy"
        return 0
    fi

    log "Found $stack_count stack(s) to redeploy"
    echo ""

    # Redeploy each stack
    local success_count=0
    local fail_count=0

    for stack_id in $(echo "$stacks" | jq -r '.[].Id'); do
        local stack_name=$(echo "$stacks" | jq -r ".[] | select(.Id==$stack_id) | .Name")
        log "Redeploying: $stack_name..."

        if portainer_redeploy_stack "$portainer_url" "$token" "$stack_id" "$endpoint_id"; then
            success "  $stack_name redeployed"
            ((success_count++))
        else
            ((fail_count++))
        fi

        # Small delay between deployments
        sleep 2
    done

    echo ""
    log "Redeploy complete: $success_count succeeded, $fail_count failed"

    if [[ $fail_count -gt 0 ]]; then
        warn "Some stacks failed. Check Portainer UI: $portainer_url"
    fi

    return 0
}
