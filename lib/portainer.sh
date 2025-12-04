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

# Wait for Ducks API to be available
wait_for_ducks_api() {
    local max_wait=${1:-120}
    local waited=0
    local ducks_api="http://localhost:8700"

    log "Waiting for Ducks API to be available..."

    while [[ $waited -lt $max_wait ]]; do
        if curl -s "${ducks_api}/health" &>/dev/null; then
            success "Ducks API is available!"
            return 0
        fi

        sleep 3
        waited=$((waited + 3))
        echo -n "."
    done

    echo ""
    warn "Timeout waiting for Ducks API"
    return 1
}

# Deploy a single stack by name via Portainer
deploy_stack_by_name() {
    local portainer_url=$1
    local token=$2
    local endpoint_id=$3
    local stacks=$4
    local stack_name=$5

    local stack_id=$(echo "$stacks" | jq -r ".[] | select(.Name==\"$stack_name\") | .Id")

    if [[ -z "$stack_id" ]]; then
        warn "Stack not found: $stack_name"
        return 1
    fi

    # Create networks first
    create_stack_networks "$portainer_url" "$token" "$stack_id" "$stack_name"

    log "Deploying: $stack_name..."
    if portainer_redeploy_stack "$portainer_url" "$token" "$stack_id" "$endpoint_id"; then
        success "  $stack_name deployed"
        return 0
    else
        error "  Failed to deploy $stack_name"
        return 1
    fi
}

# Deploy project via Ducks API
deploy_via_ducks_api() {
    local project_name=$1
    local ducks_api="http://localhost:8700"

    log "Deploying $project_name via Ducks API..."

    # Get project ID
    local project_id=$(curl -s "${ducks_api}/api/projects" 2>/dev/null | jq -r ".[] | select(.name==\"$project_name\") | .id // empty")

    if [[ -z "$project_id" ]]; then
        warn "Project $project_name not found in Ducks API"
        return 1
    fi

    # Trigger deploy
    local response=$(curl -s -X POST "${ducks_api}/api/projects/${project_id}/deploy" 2>/dev/null)
    local error=$(echo "$response" | jq -r '.error // empty' 2>/dev/null)

    if [[ -n "$error" ]]; then
        warn "Failed to deploy $project_name: $error"
        return 1
    fi

    success "  $project_name deploy triggered"
    return 0
}

# Get all project names from Ducks API
get_ducks_projects() {
    local ducks_api="http://localhost:8700"
    curl -s "${ducks_api}/api/projects" 2>/dev/null | jq -r '.[].name' 2>/dev/null
}

# Restore database for a specific container
restore_single_database() {
    local manifest_file=$1
    local data_dir=$2
    local target_container=$3

    local containers=$(jq -r '.containers[] | @base64' "$manifest_file")

    for container_b64 in $containers; do
        local container=$(echo "$container_b64" | base64 -d)
        local name=$(echo "$container" | jq -r '.container_name')

        # Skip if not the target container
        if [[ "$name" != *"$target_container"* ]]; then
            continue
        fi

        local db_type=$(echo "$container" | jq -r '.db_type // empty')
        local db_dump_file=$(echo "$container" | jq -r '.db_dump_file // empty')
        local status=$(echo "$container" | jq -r '.status')

        if [[ -z "$db_type" || -z "$db_dump_file" || "$status" != "success" ]]; then
            continue
        fi

        local dump_path="$data_dir/$name/$db_dump_file"

        if [[ ! -f "$dump_path" ]]; then
            warn "Database dump not found: $dump_path"
            continue
        fi

        # Wait for container to be ready
        if ! wait_for_container "$name" 60; then
            warn "Container $name not ready, skipping database restore"
            continue
        fi

        sleep 5

        case $db_type in
            postgres)
                restore_postgres "$name" "$dump_path"
                ;;
            mysql)
                restore_mysql "$name" "$dump_path"
                ;;
            mariadb)
                restore_mysql "$name" "$dump_path" "mysql" true
                ;;
            mongodb)
                restore_mongodb "$name" "$dump_path"
                ;;
        esac

        return 0
    done

    warn "No database found for container matching: $target_container"
    return 1
}

# Restore all databases EXCEPT the ones already restored
restore_remaining_databases() {
    local manifest_file=$1
    local data_dir=$2
    shift 2
    local exclude_patterns=("$@")

    local containers=$(jq -r '.containers[] | @base64' "$manifest_file")
    local restored=0

    for container_b64 in $containers; do
        local container=$(echo "$container_b64" | base64 -d)
        local name=$(echo "$container" | jq -r '.container_name')
        local db_type=$(echo "$container" | jq -r '.db_type // empty')
        local db_dump_file=$(echo "$container" | jq -r '.db_dump_file // empty')
        local status=$(echo "$container" | jq -r '.status')

        # Skip if no database or failed
        if [[ -z "$db_type" || -z "$db_dump_file" || "$status" != "success" ]]; then
            continue
        fi

        # Skip if matches any exclude pattern
        local skip=false
        for pattern in "${exclude_patterns[@]}"; do
            if [[ "$name" == *"$pattern"* ]]; then
                skip=true
                break
            fi
        done

        if [[ "$skip" == "true" ]]; then
            log "Skipping already restored: $name"
            continue
        fi

        local dump_path="$data_dir/$name/$db_dump_file"

        if [[ ! -f "$dump_path" ]]; then
            warn "Database dump not found: $dump_path"
            continue
        fi

        # Wait for container to be ready
        if ! wait_for_container "$name" 60; then
            warn "Container $name not ready, skipping database restore"
            continue
        fi

        sleep 5

        case $db_type in
            postgres)
                restore_postgres "$name" "$dump_path"
                restored=$((restored + 1))
                ;;
            mysql)
                restore_mysql "$name" "$dump_path"
                restored=$((restored + 1))
                ;;
            mariadb)
                restore_mysql "$name" "$dump_path" "mysql" true
                restored=$((restored + 1))
                ;;
            mongodb)
                restore_mongodb "$name" "$dump_path"
                restored=$((restored + 1))
                ;;
        esac
    done

    if [[ $restored -gt 0 ]]; then
        success "Restored $restored remaining database(s)"
    else
        log "No remaining databases to restore"
    fi
}

# ============================================
# MAIN PHASED DEPLOYMENT FLOW
# ============================================
# 1. Portainer (already done before this)
# 2. Volumes (already done, skips databases)
# 3. Deploy alexandria
# 4. Deploy ducks-ecosystem
# 5. pg_restore ONLY ducks-ecosystem
# 6. Via Ducks API: deploy argos
# 7. Via Ducks API: deploy remaining projects
# 8. pg_restore ALL remaining databases
# ============================================

phased_redeploy() {
    local portainer_url=${1:-"https://localhost:9443"}
    local manifest_file=$2
    local data_dir=$3

    echo ""
    log "============================================"
    log "   PHASED STACK DEPLOYMENT"
    log "============================================"
    echo ""
    log "Flow:"
    log "  1. Deploy alexandria (via Portainer)"
    log "  2. Deploy ducks-ecosystem (via Portainer)"
    log "  3. pg_restore ducks-ecosystem database"
    log "  4. Deploy argos (via Ducks API)"
    log "  5. Deploy remaining projects (via Ducks API)"
    log "  6. pg_restore all remaining databases"
    echo ""

    # Ask for Portainer credentials
    read -p "Portainer username: " PORTAINER_USER
    read -sp "Portainer password: " PORTAINER_PASS
    echo ""

    if [[ -z "$PORTAINER_USER" ]] || [[ -z "$PORTAINER_PASS" ]]; then
        warn "No credentials provided, aborting"
        return 1
    fi

    # Authenticate with Portainer
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

    # ============================================
    # PHASE 1: Deploy alexandria
    # ============================================
    echo ""
    log "============================================"
    log "   PHASE 1: Deploy Alexandria"
    log "============================================"
    echo ""

    deploy_stack_by_name "$portainer_url" "$token" "$endpoint_id" "$stacks" "alexandria"
    sleep 5

    # ============================================
    # PHASE 2: Deploy ducks-ecosystem
    # ============================================
    echo ""
    log "============================================"
    log "   PHASE 2: Deploy Ducks-Ecosystem"
    log "============================================"
    echo ""

    deploy_stack_by_name "$portainer_url" "$token" "$endpoint_id" "$stacks" "ducks-ecosystem"
    sleep 10

    # Wait for PostgreSQL to be healthy
    local pg_container=$(docker ps --format '{{.Names}}' | grep -E 'ducks-ecosystem.*postgres' | head -1)
    if [[ -n "$pg_container" ]]; then
        wait_for_postgres_healthy "$pg_container" 120
    else
        warn "PostgreSQL container not found, waiting 30s..."
        sleep 30
    fi

    # ============================================
    # PHASE 3: pg_restore ONLY ducks-ecosystem
    # ============================================
    echo ""
    log "============================================"
    log "   PHASE 3: Restore Ducks-Ecosystem Database"
    log "============================================"
    echo ""

    if [[ -n "$manifest_file" ]] && [[ -n "$data_dir" ]]; then
        restore_single_database "$manifest_file" "$data_dir" "ducks-ecosystem"
    else
        warn "No manifest/data provided, skipping database restore"
    fi

    # Wait for Ducks API to come up
    wait_for_ducks_api 120

    # ============================================
    # PHASE 4: Deploy argos via Ducks API
    # ============================================
    echo ""
    log "============================================"
    log "   PHASE 4: Deploy Argos (via Ducks API)"
    log "============================================"
    echo ""

    deploy_via_ducks_api "argos"
    sleep 15

    # ============================================
    # PHASE 5: Deploy remaining projects via Ducks API
    # ============================================
    echo ""
    log "============================================"
    log "   PHASE 5: Deploy Remaining Projects"
    log "============================================"
    echo ""

    # Get all projects from Ducks and deploy them
    local projects=$(get_ducks_projects)
    local skip_projects=("alexandria" "ducks-ecosystem" "argos")

    for project in $projects; do
        # Skip already deployed
        local skip=false
        for skip_name in "${skip_projects[@]}"; do
            if [[ "$project" == "$skip_name" ]]; then
                skip=true
                break
            fi
        done

        if [[ "$skip" == "true" ]]; then
            continue
        fi

        deploy_via_ducks_api "$project"
        sleep 5
    done

    # Wait for containers to start
    log "Waiting for all containers to start..."
    sleep 20

    # ============================================
    # PHASE 6: pg_restore ALL remaining databases
    # ============================================
    echo ""
    log "============================================"
    log "   PHASE 6: Restore Remaining Databases"
    log "============================================"
    echo ""

    if [[ -n "$manifest_file" ]] && [[ -n "$data_dir" ]]; then
        restore_remaining_databases "$manifest_file" "$data_dir" "ducks-ecosystem"
    fi

    # ============================================
    # DONE
    # ============================================
    echo ""
    log "============================================"
    success "   DEPLOYMENT COMPLETE!"
    log "============================================"
    echo ""

    return 0
}

# Backwards compatibility
redeploy_portainer_stacks() {
    local portainer_url=${1:-"https://localhost:9443"}
    local manifest_file=$2
    local data_dir=$3

    phased_redeploy "$portainer_url" "$manifest_file" "$data_dir"
}
