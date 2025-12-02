#!/bin/bash
#
# Database restoration functions for Cronus recovery
#

# Restore PostgreSQL database
restore_postgres() {
    local container_name=$1
    local dump_file=$2
    local database=${3:-postgres}

    log "Restoring PostgreSQL database in $container_name..."

    # Copy dump file to container
    docker cp "$dump_file" "$container_name:/tmp/restore.dump"

    # Restore using pg_restore
    docker exec "$container_name" pg_restore \
        -U postgres \
        -d "$database" \
        -c \
        --if-exists \
        /tmp/restore.dump 2>&1 || {
            warn "pg_restore returned warnings (this is often normal)"
        }

    # Cleanup
    docker exec "$container_name" rm -f /tmp/restore.dump

    success "PostgreSQL restored in $container_name"
}

# Restore MySQL/MariaDB database
restore_mysql() {
    local container_name=$1
    local dump_file=$2
    local database=${3:-mysql}
    local is_mariadb=${4:-false}

    log "Restoring MySQL/MariaDB database in $container_name..."

    # Check if dump is compressed
    if [[ "$dump_file" == *.gz ]]; then
        # Decompress and restore
        gunzip -c "$dump_file" | docker exec -i "$container_name" mysql -u root "$database"
    else
        docker exec -i "$container_name" mysql -u root "$database" < "$dump_file"
    fi

    success "MySQL/MariaDB restored in $container_name"
}

# Restore MongoDB database
restore_mongodb() {
    local container_name=$1
    local dump_file=$2

    log "Restoring MongoDB database in $container_name..."

    # Copy archive to container
    docker cp "$dump_file" "$container_name:/tmp/restore.archive"

    # Restore using mongorestore
    docker exec "$container_name" mongorestore \
        --archive=/tmp/restore.archive \
        --gzip \
        --drop 2>&1

    # Cleanup
    docker exec "$container_name" rm -f /tmp/restore.archive

    success "MongoDB restored in $container_name"
}

# Restore databases from manifest
restore_databases_from_manifest() {
    local manifest_file=$1
    local data_dir=$2
    local container_filter=$3

    local containers=$(jq -r '.containers[] | @base64' "$manifest_file")
    local restored=0

    for container_b64 in $containers; do
        local container=$(echo "$container_b64" | base64 -d)
        local name=$(echo "$container" | jq -r '.container_name')
        local db_type=$(echo "$container" | jq -r '.db_type // empty')
        local db_dump_file=$(echo "$container" | jq -r '.db_dump_file // empty')
        local status=$(echo "$container" | jq -r '.status')

        # Skip if filtering by container and doesn't match
        if [[ -n "$container_filter" && "$name" != "$container_filter" ]]; then
            continue
        fi

        # Skip if no database or failed
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

        # Additional wait for database to be ready
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
            *)
                warn "Unknown database type: $db_type for $name"
                ;;
        esac
    done

    if [[ $restored -gt 0 ]]; then
        success "Restored $restored database(s)"
    else
        log "No databases to restore"
    fi
}
