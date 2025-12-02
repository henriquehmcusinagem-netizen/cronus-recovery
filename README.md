# Cronus Recovery

Disaster recovery scripts for restoring full server backups created by [Cronus](https://github.com/dfranciscus/cronus).

## Quick Start

```bash
# 1. Clone this repository
git clone https://github.com/dfranciscus/cronus-recovery.git
cd cronus-recovery

# 2. Download your backup file and place it here
# (e.g., server_backup_20241201_143052.tar.gz)

# 3. Run the restore script
./restore.sh server_backup_20241201_143052.tar.gz
```

## Prerequisites

Before running the restore script, ensure you have:

- **Docker** installed and running
- **docker-compose** (or Docker Compose V2)
- **jq** for JSON parsing
- Sufficient disk space for the restored data

### Installing Prerequisites

**Ubuntu/Debian:**
```bash
# Docker
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER

# jq
sudo apt-get install jq
```

**macOS:**
```bash
# Docker Desktop
brew install --cask docker

# jq
brew install jq
```

## Usage

### Basic Restore

```bash
./restore.sh backup.tar.gz
```

### Options

| Option | Description |
|--------|-------------|
| `--skip-networks` | Don't create Docker networks |
| `--skip-databases` | Skip database restoration (useful if you want to restore data only) |
| `--skip-compose` | Don't run `docker-compose up` (containers won't start) |
| `--dry-run` | Show what would be done without executing |
| `--container NAME` | Restore only a specific container |
| `-h, --help` | Show help message |

### Examples

```bash
# Restore everything
./restore.sh server_backup_20241201.tar.gz

# Skip database restoration
./restore.sh backup.tar.gz --skip-databases

# Restore only the postgres container
./restore.sh backup.tar.gz --container postgres

# Dry run to see what would happen
./restore.sh backup.tar.gz --dry-run
```

## What Gets Restored

A Cronus server backup includes:

1. **Docker Networks** - All custom networks are recreated
2. **Docker Volumes** - All named volumes with their data
3. **Database Dumps** - PostgreSQL, MySQL/MariaDB, MongoDB databases
4. **docker-compose.yml** - Reconstructed compose file to recreate all containers

## Backup Archive Structure

```
server_backup_YYYYMMDD_HHMMSS.tar.gz
├── manifest.json           # Backup metadata and container list
├── docker-compose.yml      # Reconstructed compose file
└── data/                   # Container data
    ├── postgres/
    │   ├── postgres_data.tar.gz
    │   └── pg_postgres.dump
    ├── my-app/
    │   └── app_data.tar.gz
    └── nginx/
        └── nginx_config.tar.gz
```

## Post-Restore Checklist

After running the restore:

1. **Verify containers are running:**
   ```bash
   docker ps
   ```

2. **Check container logs for errors:**
   ```bash
   docker logs <container_name>
   ```

3. **Verify database connectivity:**
   ```bash
   docker exec -it postgres psql -U postgres -c "SELECT 1"
   ```

4. **Update DNS/IP configurations** if restoring to a different server

5. **Check application health endpoints** if available

## Troubleshooting

### Network already exists
If you get "network already exists" errors, networks from a previous deployment may still exist. Either:
- Remove them: `docker network rm <network_name>`
- Use `--skip-networks` flag

### Permission denied
Make sure the script is executable:
```bash
chmod +x restore.sh lib/*.sh
```

### Database restore fails
- Ensure the container is fully started before database restore
- Check container logs: `docker logs <container_name>`
- Try restoring manually using the dump file in `data/<container>/`

### Out of disk space
- Check available space: `df -h`
- The restore needs space for both the extracted archive AND the restored volumes

## Manual Database Restore

If automatic database restore fails, you can restore manually:

**PostgreSQL:**
```bash
docker exec -i postgres pg_restore -U postgres -d postgres < data/postgres/pg_postgres.dump
```

**MySQL:**
```bash
docker exec -i mysql mysql -u root < data/mysql/mysql.sql
```

**MongoDB:**
```bash
docker exec -i mongodb mongorestore --archive < data/mongodb/dump.archive
```

## Support

- **Issues:** [GitHub Issues](https://github.com/dfranciscus/cronus-recovery/issues)
- **Cronus Project:** [GitHub](https://github.com/dfranciscus/cronus)

## License

MIT License - See [LICENSE](LICENSE) for details.
