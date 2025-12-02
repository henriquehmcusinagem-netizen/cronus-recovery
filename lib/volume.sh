#!/bin/bash
#
# Volume management functions for Cronus recovery
#

# Create a Docker volume
create_volume() {
    local name=$1

    if volume_exists "$name"; then
        warn "Volume already exists: $name"
        return 0
    fi

    log "Creating volume: $name"
    docker volume create "$name"
}

# Restore data to a volume from tar.gz
restore_volume() {
    local volume_name=$1
    local archive_path=$2

    if [[ ! -f "$archive_path" ]]; then
        error "Archive not found: $archive_path"
        return 1
    fi

    # Create volume if it doesn't exist
    create_volume "$volume_name"

    log "Restoring volume: $volume_name from $(basename "$archive_path")"

    # Get absolute path
    local abs_archive=$(cd "$(dirname "$archive_path")" && pwd)/$(basename "$archive_path")
    local archive_dir=$(dirname "$abs_archive")
    local archive_file=$(basename "$abs_archive")

    # Use Alpine to extract directly to volume
    docker run --rm \
        -v "$volume_name":/restore_target \
        -v "$archive_dir":/backup:ro \
        alpine \
        sh -c "cd /restore_target && rm -rf * && tar -xzf /backup/$archive_file"

    if [[ $? -eq 0 ]]; then
        success "Volume restored: $volume_name"
    else
        error "Failed to restore volume: $volume_name"
        return 1
    fi
}

# Restore volumes from manifest
restore_volumes_from_manifest() {
    local manifest_file=$1
    local data_dir=$2
    local container_filter=$3

    local containers=$(jq -r '.containers[] | @base64' "$manifest_file")

    for container_b64 in $containers; do
        local container=$(echo "$container_b64" | base64 -d)
        local name=$(echo "$container" | jq -r '.container_name')
        local status=$(echo "$container" | jq -r '.status')

        # Skip if filtering by container and doesn't match
        if [[ -n "$container_filter" && "$name" != "$container_filter" ]]; then
            continue
        fi

        # Skip failed containers
        if [[ "$status" != "success" ]]; then
            warn "Skipping failed container: $name"
            continue
        fi

        log "Processing container: $name"

        # Get volume files
        local volume_files=$(echo "$container" | jq -r '.volume_files[]? // empty')

        for volume_file in $volume_files; do
            local archive_path="$data_dir/$name/$volume_file"

            if [[ -f "$archive_path" ]]; then
                # Extract volume name from filename (remove .tar.gz)
                local volume_name="${volume_file%.tar.gz}"

                restore_volume "$volume_name" "$archive_path"
            else
                warn "Volume archive not found: $archive_path"
            fi
        done
    done

    success "Volume restoration complete"
}
