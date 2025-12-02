#!/bin/bash
#
# Network management functions for Cronus recovery
#

# Create a Docker network
create_network() {
    local name=$1
    local driver=${2:-bridge}

    if network_exists "$name"; then
        warn "Network already exists: $name"
        return 0
    fi

    log "Creating network: $name (driver: $driver)"
    docker network create --driver "$driver" "$name"
}

# Create networks from manifest
create_networks_from_manifest() {
    local manifest_file=$1

    local networks=$(jq -r '.networks[]? | @base64' "$manifest_file")

    if [[ -z "$networks" ]]; then
        log "No custom networks to create"
        return 0
    fi

    for network_b64 in $networks; do
        local network=$(echo "$network_b64" | base64 -d)
        local name=$(echo "$network" | jq -r '.name')
        local driver=$(echo "$network" | jq -r '.driver // "bridge"')
        local external=$(echo "$network" | jq -r '.external // false')

        # Skip external networks (they should already exist or be created manually)
        if [[ "$external" == "true" ]]; then
            if ! network_exists "$name"; then
                warn "External network '$name' does not exist. Creating it..."
                create_network "$name" "$driver"
            else
                log "External network exists: $name"
            fi
            continue
        fi

        create_network "$name" "$driver"
    done

    success "Networks created"
}
