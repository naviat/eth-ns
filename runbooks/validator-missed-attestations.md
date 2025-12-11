# Runbook: Validator Missing Attestations

## Severity: HIGH

**Alert**: `ValidatorMissedAttestations`
**Impact**: Loss of staking rewards, potential penalties
**Response Time**: < 15 minutes

## Symptoms

- Grafana alert: "Validator is missing attestations"
- Prometheus metric: `rate(validator_attestations_missed_total[5m]) > 0`
- Validator balance not increasing

## Common Causes

1. Validator client offline
2. Beacon node not synced
3. Execution client lagging
4. Network connectivity issues
5. Clock drift

## Diagnosis Steps

### 1. Check Validator Client Status (30 seconds)

```bash
# Is it running?
docker compose ps validator-client

# Check recent logs
docker compose logs --tail=50 validator-client

# Look for:
# - "Published attestation" (should see every ~12 seconds)
# - Error messages
# - Connection issues
```

### 2. Check Beacon Node Sync (30 seconds)

```bash
# Run health check
make health-validator

# Or manually:
docker exec validator-consensus curl -s \
  http://localhost:5052/eth/v1/node/syncing | jq

# Should show: "is_syncing": false
```

### 3. Check Sentry Nodes (1 minute)

```bash
# Both sentries should be healthy
make health-sentry1
make health-sentry2

# Check execution clients
docker compose logs --tail=20 sentry1-execution
docker compose logs --tail=20 sentry2-execution
```

### 4. Check Network Connectivity (30 seconds)

```bash
# Validator → Sentries
./scripts/test-network.sh

# Check peer count
docker exec validator-consensus curl -s \
  http://localhost:5052/eth/v1/node/peer_count
```

## Resolution Steps

### Issue 1: Validator Client Crashed

```bash
# Restart validator client
docker compose restart validator-client

# Monitor for attestations
docker compose logs -f validator-client | grep "Published attestation"

# Should see attestation within 2 minutes
```

### Issue 2: Beacon Node Not Synced

```bash
# Check sync status
docker exec validator-consensus curl -s \
  http://localhost:5052/eth/v1/node/syncing

# If syncing: wait 5-10 minutes, monitor progress
# If stuck: restart beacon node
docker compose restart validator-consensus

# Wait for sync (checkpoint sync is fast)
watch -n 10 'docker compose logs validator-consensus | tail -20'
```

### Issue 3: Execution Client Issues

```bash
# Check sentry execution clients
docker compose logs --tail=100 sentry1-execution | grep -i error
docker compose logs --tail=100 sentry2-execution | grep -i error

# If both unhealthy: restart one at a time
docker compose restart sentry1-execution
# Wait 5 minutes
docker compose restart sentry2-execution
```

### Issue 4: Network Connectivity

```bash
# Test connectivity
./scripts/test-network.sh

# If validator can't reach sentries:
# Check Docker networks
docker network ls
docker network inspect validator_sentry1-internal
docker network inspect validator_sentry2-internal

# Recreate networks if needed
docker compose down
docker compose up -d
```

### Issue 5: Clock Drift

```bash
# Check system time
date -u
timedatectl status

# Should be synchronized
# If not:
sudo timedatectl set-ntp true
sudo systemctl restart systemd-timesyncd

# Verify
timedatectl status | grep "synchronized"
```

## Emergency Rollback

If issue persists > 10 minutes:

```bash
# Safe rollback
./scripts/rollback-advanced.sh

# Review logs
docker compose logs validator-client > /tmp/validator-crash.log
docker compose logs validator-consensus > /tmp/beacon-crash.log

# Restart with previous version
make deploy
```

## Post-Incident

### 1. Calculate Impact

```bash
# Missed attestations
curl -s http://localhost:5064/metrics | grep validator_attestations_missed_total

# Estimated penalty
# Each missed attestation: ~same as successful one
# 5 minutes downtime: ~25 missed attestations
# Penalty: ~0.0001 ETH per attestation
```

### 2. Document Incident

Create incident report:

- Time of alert
- Root cause
- Time to resolution
- Actions taken
- Lessons learned

### 3. Prevent Recurrence

- If client crash: Update to stable version
- If network issue: Add redundancy
- If sentry failure: Improve monitoring
- If config error: Add validation checks

## Escalation

**After 15 minutes without resolution:**

1. Engage senior DevOps engineer
2. Consider full system restart
3. Review disaster recovery procedures

**After 1 hour:**

1. Activate incident response team
2. Consider migrating to backup infrastructure
3. Contact Ethereum client developers (if client bug)

## Prevention

### Monitoring

```bash
# Ensure alerts are configured
curl http://localhost:9090/api/v1/rules | grep -i attestation

# Test alerts
# (simulate by stopping validator briefly)
```

### Regular Checks

```bash
# Daily health check
make health-check

# Weekly full test
./scripts/test-network.sh
```

### Maintenance Windows

- Schedule client upgrades during low-activity periods
- Always use `./scripts/upgrade.sh` for safe upgrades
- Never upgrade both sentries simultaneously

## Related Runbooks

- [Validator Client Crashed](./validator-client-crashed.md)
- [High Attestation Delay](./high-attestation-delay.md)
- [Sentry Node Failure](./sentry-node-failure.md)
- [Disk Space Critical](./disk-space-critical.md)

## Useful Commands

```bash
# Quick status check
make status && make health-check

# View all metrics
curl -s http://localhost:5064/metrics | grep validator_

# Check recent blocks
docker exec validator-consensus curl -s \
  http://localhost:5052/eth/v1/beacon/headers/head | jq

# Force sync reset (last resort)
docker compose down
docker volume rm validator-consensus-data
docker compose up -d
# (Will re-sync from checkpoint)
```

## Success Criteria

✅ Validator publishing attestations regularly
✅ No errors in logs
✅ Peer count > 10
✅ Sync status: synced
✅ Balance increasing

---

**Last Updated**: 2025-12-10
