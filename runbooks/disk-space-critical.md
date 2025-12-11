# Runbook: Disk Space Critical

## Severity: CRITICAL

**Alert**: `CriticalDiskUsage`
**Impact**: Service failure, data loss, validator downtime
**Response Time**: < 10 minutes

## Symptoms

- Prometheus alert: "Disk usage above 90%"
- Services failing to start
- Database write errors
- Container restart loops

## Quick Check

```bash
# Check disk usage immediately
make disk-monitor

# Or manually:
df -h /var/lib/docker
df -h /
```

## Emergency Response (< 5 minutes)

### If > 95% Full - IMMEDIATE ACTION

```bash
# 1. Clean Docker cache (safe, fast)
docker system prune -af --volumes

# 2. Check space gained
df -h /var/lib/docker

# 3. If still > 90%, stop non-critical services
docker compose stop grafana prometheus

# 4. Clean old logs
sudo journalctl --vacuum-time=7d
```

## Root Cause Analysis (5 minutes)

### Find What's Using Space

```bash
# Docker volumes
docker system df -v

# Largest volumes
sudo du -sh /var/lib/docker/volumes/* | sort -hr | head -10

# Specific service data
sudo du -sh /var/lib/docker/volumes/validator_*
```

## Resolution Steps

### Issue 1: Execution Client Too Large

**Symptom**: `sentry*-execution-data` volumes > 150GB

```bash
# Check execution client sizes
sudo du -sh /var/lib/docker/volumes/*execution*

# Solution: Trigger pruning in Nethermind
docker exec sentry1-execution curl -X POST -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"admin_prune","params":[],"id":1}' \
  http://localhost:8545

# Wait 30-60 minutes for pruning
# Monitor:
watch -n 60 'sudo du -sh /var/lib/docker/volumes/validator_sentry1-execution-data'
```

### Issue 2: Prometheus Data Too Large

**Symptom**: `prometheus-data` > 30GB

```bash
# Reduce retention time
# Edit configs/prometheus/prometheus.yml:
# --storage.tsdb.retention.time=15d  # Was 30d
# --storage.tsdb.retention.size=15GB # Was 20GB

# Restart Prometheus
docker compose restart prometheus

# Old data will be deleted automatically
```

### Issue 3: Logs Taking Too Much Space

```bash
# Check Docker logs
sudo du -sh /var/lib/docker/containers/*/*-json.log | sort -hr | head -5

# Configure log rotation (add to docker-compose.yml):
# services:
#   validator-client:
#     logging:
#       driver: "json-file"
#       options:
#         max-size: "10m"
#         max-file: "3"

# Immediate cleanup
sudo sh -c 'truncate -s 0 /var/lib/docker/containers/*/*-json.log'
```

### Issue 4: Multiple Old Images

```bash
# List all images
docker images

# Remove unused images
docker image prune -af

# Remove specific old versions
docker rmi nethermind/nethermind:1.24.0  # Keep only current
```

## Long-Term Solutions

### Option 1: Extend LVM (If space available in VG)

```bash
# Check available space
sudo vgs ubuntu-vg

# If space available, extend Docker LV
sudo lvextend -L +200G /dev/ubuntu-vg/docker-lv
sudo resize2fs /dev/ubuntu-vg/docker-lv

# Verify
df -h /var/lib/docker
```

### Option 2: Add External Volume

```bash
# Mount external drive for archival data
# Move old prometheus data to external storage
sudo mv /var/lib/docker/volumes/validator_prometheus-data \
        /mnt/external/prometheus-backup

# Create symlink
sudo ln -s /mnt/external/prometheus-backup \
           /var/lib/docker/volumes/validator_prometheus-data
```

### Option 3: Aggressive Pruning Configuration

Update `configs/nethermind/sentry*.cfg`:

```json
{
  "Pruning": {
    "Mode": "Full",
    "FullPruningTrigger": "VolumeFreeSpace",
    "FullPruningThresholdMb": 100000,  // Trigger at 100GB free (was 256GB)
    "FullPruningMinimumDelayHours": 120  // More frequent (was 240)
  }
}
```

Restart execution clients:

```bash
docker compose restart sentry1-execution sentry2-execution
```

## Monitoring Setup

### Prevent Future Issues

```bash
# Add cron job for daily cleanup
cat > /etc/cron.daily/docker-cleanup << 'EOF'
#!/bin/bash
docker system prune -af --filter "until=24h"
journalctl --vacuum-time=7d
EOF

chmod +x /etc/cron.daily/docker-cleanup
```

### Alert Thresholds

Ensure these alerts exist in `configs/prometheus/alerts.yml`:

```yaml
- alert: DiskWarning
  expr: (node_filesystem_avail_bytes / node_filesystem_size_bytes) < 0.20
  for: 30m
  labels:
    severity: warning

- alert: DiskCritical
  expr: (node_filesystem_avail_bytes / node_filesystem_size_bytes) < 0.10
  for: 5m
  labels:
    severity: critical
```

## Disk Space Budget

**Total Available**: 800GB (on /var/lib/docker)

**Allocation**:

```
Execution Clients (2×)    : 200GB (100GB each with pruning)
Consensus Clients (3×)    : 150GB (50GB each)
Slashing Protection       : 1GB
Prometheus (15 days)      : 15GB
Grafana                   : 2GB
Docker Images/Containers  : 10GB
Buffer/Safety Margin      : 422GB (53% free)
```

**Red Line Triggers**:

- Warning: < 160GB free (20%)
- Critical: < 80GB free (10%)
- Emergency: < 40GB free (5%)

## Cleanup Checklist

```bash
# Run this monthly
./scripts/monthly-cleanup.sh

# Or manually:
□ docker system prune -af
□ Remove old backups (keep last 3)
□ Clean journal logs
□ Trigger Nethermind pruning
□ Check for core dumps
□ Remove old upgrade backups
□ Verify Prometheus retention
```

## Emergency Contacts

**If disk fills completely:**

1. Stop all containers: `docker compose down`
2. Free space using any method above
3. Verify: `df -h`
4. Restart: `make deploy`

**If unable to resolve:**

- Escalate to senior infrastructure team
- Consider migrating to larger disk
- Review capacity planning

## Post-Incident Actions

### 1. Review Growth Rate

```bash
# Install ncdu for disk analysis
sudo apt install ncdu

# Analyze growth
sudo ncdu /var/lib/docker/volumes
```

### 2. Update Capacity Plan

Document in PLANNING.md:

- Actual disk usage vs estimates
- Growth rate per week
- Projected full date
- When to expand

### 3. Improve Monitoring

Add capacity tracking:

```promql
# Prometheus query
predict_linear(node_filesystem_avail_bytes[7d], 30*24*3600)

# Alerts when < 30 days until full
```

## Related Runbooks

- [Execution Client Pruning](./execution-client-pruning.md)
- [Database Maintenance](./database-maintenance.md)
- [Backup and Restore](./backup-restore.md)

## Useful Commands

```bash
# Top 20 largest files
sudo find /var/lib/docker -type f -exec du -h {} + | sort -hr | head -20

# Space by service
for vol in $(docker volume ls -q); do
  echo "$vol: $(sudo du -sh /var/lib/docker/volumes/$vol | cut -f1)"
done

# Growth rate (run twice, 1 hour apart)
df -h /var/lib/docker > /tmp/disk-before.txt
# ... wait 1 hour ...
df -h /var/lib/docker > /tmp/disk-after.txt
diff /tmp/disk-before.txt /tmp/disk-after.txt
```

---

**Last Updated**: 2025-12-11
