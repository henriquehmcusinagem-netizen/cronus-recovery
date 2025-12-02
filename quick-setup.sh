#!/bin/bash
#
# Cronus Recovery - Quick Setup Script
#
# Este script prepara uma máquina Linux limpa para restaurar um backup do Cronus.
# Instala Docker, dependências e clona o repositório de recovery.
#
# Uso:
#   curl -fsSL https://raw.githubusercontent.com/henriquehmcusinagem-netizen/cronus-recovery/main/quick-setup.sh | bash
#
# Ou:
#   wget -qO- https://raw.githubusercontent.com/henriquehmcusinagem-netizen/cronus-recovery/main/quick-setup.sh | bash
#

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}"
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║                                                               ║"
echo "║              CRONUS RECOVERY - QUICK SETUP                    ║"
echo "║                                                               ║"
echo "║     Preparando máquina para restauração de backup             ║"
echo "║                                                               ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# Detect OS
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VERSION=$VERSION_ID
    elif [ -f /etc/debian_version ]; then
        OS="debian"
    elif [ -f /etc/redhat-release ]; then
        OS="rhel"
    else
        OS="unknown"
    fi
    echo -e "${BLUE}[INFO]${NC} Sistema detectado: $OS $VERSION"
}

# Check if running as root
check_sudo() {
    if [ "$EUID" -eq 0 ]; then
        SUDO=""
    else
        SUDO="sudo"
        echo -e "${YELLOW}[WARN]${NC} Executando com sudo. Pode pedir senha."
    fi
}

# Install Docker
install_docker() {
    echo ""
    echo -e "${BLUE}[1/4]${NC} Verificando Docker..."

    if command -v docker &> /dev/null; then
        echo -e "${GREEN}[OK]${NC} Docker já está instalado: $(docker --version)"
    else
        echo -e "${BLUE}[INFO]${NC} Instalando Docker..."
        curl -fsSL https://get.docker.com | $SUDO sh

        # Add current user to docker group
        if [ "$EUID" -ne 0 ]; then
            $SUDO usermod -aG docker $USER
            echo -e "${YELLOW}[WARN]${NC} Usuário adicionado ao grupo docker."
            echo -e "${YELLOW}[WARN]${NC} Você precisará fazer logout/login ou executar: newgrp docker"
        fi

        # Start Docker service
        $SUDO systemctl enable docker
        $SUDO systemctl start docker

        echo -e "${GREEN}[OK]${NC} Docker instalado com sucesso!"
    fi
}

# Install Docker Compose
install_docker_compose() {
    echo ""
    echo -e "${BLUE}[2/4]${NC} Verificando Docker Compose..."

    if docker compose version &> /dev/null; then
        echo -e "${GREEN}[OK]${NC} Docker Compose já está instalado"
    elif command -v docker-compose &> /dev/null; then
        echo -e "${GREEN}[OK]${NC} docker-compose já está instalado: $(docker-compose --version)"
    else
        echo -e "${BLUE}[INFO]${NC} Docker Compose V2 já incluído no Docker Engine moderno"
    fi
}

# Install dependencies (jq, git)
install_dependencies() {
    echo ""
    echo -e "${BLUE}[3/4]${NC} Instalando dependências (jq, git)..."

    case $OS in
        ubuntu|debian)
            $SUDO apt-get update -qq
            $SUDO apt-get install -y -qq jq git curl
            ;;
        centos|rhel|fedora)
            $SUDO yum install -y -q jq git curl
            ;;
        alpine)
            $SUDO apk add --no-cache jq git curl bash
            ;;
        *)
            echo -e "${YELLOW}[WARN]${NC} OS não reconhecido. Instale manualmente: jq, git, curl"
            ;;
    esac

    echo -e "${GREEN}[OK]${NC} Dependências instaladas!"
}

# Clone recovery repository
clone_repository() {
    echo ""
    echo -e "${BLUE}[4/4]${NC} Clonando repositório de recovery..."

    REPO_URL="https://github.com/henriquehmcusinagem-netizen/cronus-recovery.git"
    INSTALL_DIR="$HOME/cronus-recovery"

    if [ -d "$INSTALL_DIR" ]; then
        echo -e "${YELLOW}[WARN]${NC} Diretório já existe. Atualizando..."
        cd "$INSTALL_DIR"
        git pull origin main
    else
        git clone "$REPO_URL" "$INSTALL_DIR"
        cd "$INSTALL_DIR"
    fi

    # Make scripts executable
    chmod +x restore.sh lib/*.sh

    echo -e "${GREEN}[OK]${NC} Repositório clonado em: $INSTALL_DIR"
}

# Print next steps
print_next_steps() {
    echo ""
    echo -e "${GREEN}"
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║                                                               ║"
    echo "║                    SETUP COMPLETO! ✓                          ║"
    echo "║                                                               ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo ""
    echo -e "${CYAN}PRÓXIMOS PASSOS:${NC}"
    echo ""
    echo "  1. Se adicionado ao grupo docker, faça logout/login ou execute:"
    echo -e "     ${YELLOW}newgrp docker${NC}"
    echo ""
    echo "  2. Copie seu arquivo de backup para esta máquina:"
    echo -e "     ${YELLOW}scp backup.tar.gz usuario@este-servidor:~/cronus-recovery/${NC}"
    echo ""
    echo "  3. Entre no diretório de recovery:"
    echo -e "     ${YELLOW}cd ~/cronus-recovery${NC}"
    echo ""
    echo "  4. (Opcional) Veja o que será restaurado:"
    echo -e "     ${YELLOW}./restore.sh seu_backup.tar.gz --dry-run${NC}"
    echo ""
    echo "  5. Execute a restauração:"
    echo -e "     ${YELLOW}./restore.sh seu_backup.tar.gz${NC}"
    echo ""
    echo "  6. Aguarde a conclusão e verifique:"
    echo -e "     ${YELLOW}docker ps${NC}"
    echo ""
    echo -e "${BLUE}Documentação: https://github.com/henriquehmcusinagem-netizen/cronus-recovery${NC}"
    echo ""
}

# Main
main() {
    detect_os
    check_sudo
    install_docker
    install_docker_compose
    install_dependencies
    clone_repository
    print_next_steps
}

main "$@"
