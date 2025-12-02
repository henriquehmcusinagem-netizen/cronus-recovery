#!/bin/bash
#
# Docker utility functions for Cronus recovery
#

# Check if a Docker network exists
network_exists() {
    docker network inspect "$1" &> /dev/null
}

# Check if a Docker volume exists
volume_exists() {
    docker volume inspect "$1" &> /dev/null
}

# Check if a Docker container exists
container_exists() {
    docker container inspect "$1" &> /dev/null
}

# Check if a Docker container is running
container_running() {
    local status=$(docker inspect --format='{{.State.Running}}' "$1" 2>/dev/null)
    [[ "$status" == "true" ]]
}

# Get container ID by name
get_container_id() {
    docker ps -aq --filter "name=^${1}$" 2>/dev/null | head -n1
}

# Stop a container gracefully
stop_container() {
    local name=$1
    local timeout=${2:-30}

    if container_running "$name"; then
        log "Stopping container: $name"
        docker stop -t "$timeout" "$name" &> /dev/null
    fi
}

# Start a container
start_container() {
    local name=$1

    if container_exists "$name"; then
        log "Starting container: $name"
        docker start "$name" &> /dev/null
    fi
}

# Execute command in container
exec_in_container() {
    local container=$1
    shift
    docker exec "$container" "$@"
}

# Run a temporary container for volume operations
run_volume_helper() {
    local volumes="$1"
    local command="$2"

    docker run --rm \
        $volumes \
        alpine \
        sh -c "$command"
}
