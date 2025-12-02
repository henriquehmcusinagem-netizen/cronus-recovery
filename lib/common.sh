#!/bin/bash
#
# Common utility functions for Cronus recovery
#

# Logging functions
log() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

# Check if a command exists
command_exists() {
    command -v "$1" &> /dev/null
}

# Check prerequisites
check_prerequisites() {
    log "Checking prerequisites..."

    # Check Docker
    if ! command_exists docker; then
        error "Docker is not installed"
        echo "Please install Docker: https://docs.docker.com/get-docker/"
        exit 1
    fi

    # Check Docker is running
    if ! docker info &> /dev/null; then
        error "Docker daemon is not running"
        echo "Please start the Docker daemon"
        exit 1
    fi

    # Check docker-compose
    if ! command_exists docker-compose && ! docker compose version &> /dev/null; then
        error "docker-compose is not installed"
        echo "Please install docker-compose: https://docs.docker.com/compose/install/"
        exit 1
    fi

    # Check jq for JSON parsing
    if ! command_exists jq; then
        error "jq is not installed"
        echo "Please install jq: apt-get install jq / brew install jq"
        exit 1
    fi

    success "All prerequisites satisfied"
}

# Retry a command with exponential backoff
retry_command() {
    local max_attempts=$1
    local delay=$2
    local command="${@:3}"

    local attempt=1
    while [[ $attempt -le $max_attempts ]]; do
        if $command; then
            return 0
        fi

        if [[ $attempt -lt $max_attempts ]]; then
            warn "Command failed, retrying in ${delay}s (attempt $attempt/$max_attempts)"
            sleep $delay
            delay=$((delay * 2))
        fi

        attempt=$((attempt + 1))
    done

    return 1
}

# Wait for a container to be healthy
wait_for_container() {
    local container_name=$1
    local max_wait=${2:-60}
    local waited=0

    log "Waiting for $container_name to be healthy..."

    while [[ $waited -lt $max_wait ]]; do
        local status=$(docker inspect --format='{{.State.Health.Status}}' "$container_name" 2>/dev/null || echo "unknown")

        case $status in
            "healthy")
                success "$container_name is healthy"
                return 0
                ;;
            "unhealthy")
                warn "$container_name is unhealthy"
                return 1
                ;;
            "starting"|"unknown")
                # Also check if container is at least running
                if docker inspect --format='{{.State.Running}}' "$container_name" 2>/dev/null | grep -q "true"; then
                    if [[ "$status" == "unknown" ]]; then
                        # No healthcheck defined, assume ready after brief wait
                        sleep 3
                        success "$container_name is running (no healthcheck)"
                        return 0
                    fi
                fi
                ;;
        esac

        sleep 2
        waited=$((waited + 2))
    done

    warn "$container_name did not become healthy within ${max_wait}s"
    return 1
}
