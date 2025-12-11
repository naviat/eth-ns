# Ethereum Validator Infrastructure - Production Ready

## 🚀 Quick Start

**Start here:** [HOW_TO.md](HOW_TO.md)

## One-Command Deployment

```bash
# 1. Prepare disk (one-time)
sudo ./scripts/reclaim-docker-lv-for-kind.sh

# 2. Create Kind cluster
kind create cluster --name validator --config kind-config.yaml

# 3. Generate secrets
cd helm/ethereum-validator
../../scripts/init-secrets-helm.sh

# 4. Deploy
../../scripts/deploy-helm.sh

# 5. Verify
kubectl get pods -n validators
kubectl get endpoints -n validators execution-lb
```

## Architecture Highlights

```
                INTERNET
                    │
    ┌───────────────┼───────────────┐
    │                               │
Sentry 1                        Sentry 2
Nethermind EC                   Nethermind EC
Lighthouse CC                   Lighthouse CC
    │                               │
    └───────────┬───────────────────┘
                │
        execution-lb (K8s Service)
        Session Affinity: ClientIP
                │
    ════════════════════════════
    PRIVATE NETWORK (Isolated)
    ════════════════════════════
                │
          Validator (NO INTERNET)
          Lighthouse CC + VC
          + Validator Keys
          + Slashing Protection DB
(Optional / Roadmap) :
- MEV-Boost sidecar talking to public MEV relays via HTTPS
- VC / BN configured with builder proposal endpoints
```

Traffic model (steady state)

- Sentry ECs:
  - Outbound P2P to internet.
  - Expose Engine API (:8551) internally in the cluster.
- Sentry BNs:
  - P2P to internet (beacon gossip).
  - Talk to local EC (sentryX-execution:8551) via Engine API.
- Validator BN:
  - Talks to execution-lb (ECs) via Engine API.
  - Beacon gossip (P2P) can be on, but may be restricted by NetworkPolicy.
- Validator VC:
  - Talks to multiple BNs:
    - validator-consensus
    - sentry1-consensus
    - sentry2-consensus
- This is effectively client-side load-balancing + failover.
  - MEV-Boost (optional):
  - Runs next to validator BN.
  - Talks outbound HTTPS to public MEV relays.
  - BN talks to MEV-Boost instead of directly to local EC for block building.

## Success Criteria

Deployment successful when:

- [ ] All 9 pods Running
- [ ] execution-lb has 2 endpoints
- [ ] 6 NetworkPolicies applied
- [ ] Validator can reach execution-lb
- [ ] Validator CANNOT reach internet
- [ ] Grafana accessible (localhost:3000)
- [ ] Attestations being published

## **🔧 Client Selection & Trade-offs**

### **Execution Client:**

### **Nethermind**

**Why Nethermind:**

- Good performance and memory profile for constrained hardware (mini PC).
- Strong support for modern features:
  - Merge / Engine API
  - Snap sync
  - Blob / EIP-4844 support.
- Nice operational logging and metrics.

**Trade-offs vs e.g. Geth / Besu:**

- Slightly more complex config surface than Geth.
- You must keep up with Nethermind’s release cadence to avoid consensus issues.
- Ecosystem docs sometimes lag behind Geth.

### **Consensus / Validator Client:**

### **Lighthouse**

**Why Lighthouse:**

- Very battle-tested on mainnet.
- Excellent slashing protection DB implementation.
- Good metrics story (Prometheus) and tooling.
- Native support for:
  - Multiple --beacon-nodes= (client-side failover).
  - Checkpoint sync.
  - MEV-Boost integration.

**Trade-offs vs Prysm / Teku / Nimbus:**

- Configuration flags differ, migration between clients is non-trivial.
- Slightly more “power-user” oriented; less GUI / wizard type experience.

### **MEV-Boost (Optional)**

Planned integration:

- Run **mev-boost** as a Deployment/StatefulSet in validators namespace.
- BN configured with:
  - -builder-proposals=true
  - -builder-endpoint=<http://mev-boost:18550>
- MEV-Boost talks to public relays (HTTPS, port 443).

**Trade-off:**

- More complexity and external dependencies (relays uptime).
- Better rewards but more moving pieces to monitor.

## **🔒 Security Posture Summary**

**Goal:** Home mini-PC, validator protected by k8s + sentry layer, minimal internet exposure.

### **Current / Intended Security Properties**

- **Validator node is never exposed to the internet directly**:
  - No public P2P ports.
  - No public HTTP / RPC.
  - Only talks to:
    - Internal BNs (validator + sentries)
    - (Optional) MEV-Boost
- **Sentry nodes handle all public P2P**:
  - They connect to the broader Ethereum network.
  - They are “expendable”; compromise should *not* leak validator keys.
- **Private networking**:
  - All validator components are inside the validators namespace.
  - Pod-to-pod communication via ClusterIP Services only.
  - NetworkPolicy (once re-enabled) will:
    - Allow only the minimum required pod ↔ pod paths.
    - Deny validator to general internet.
- **Secrets**:
  - JWT secret stored as Kubernetes Secret (backed by file from init-secrets-helm.sh).
  - Validator keystore + mnemonic **not committed**; only mounted from Secrets/PVC.
  - Slashing protection DB on its own PVC, separate from execution/consensus DBs.
- **Checkpoint sync**:
  - BNs may fetch checkpoint state from trusted endpoints (HTTPS only).
  - Outbound only; no inbound exposure.

---

## **📈 SLOs & Alerting (Current & Future)**

Right now, this stack does **not** define formal SLOs, but suggested targets:

- **Availability**:
  - BN/VC pods Ready ≥ 99.5%.
- **Chain sync**:
  - Head slot lag < 2 epochs most of the time.
- **Attestations**:
  - Missed attestations < 0.5% over 24h window (for active validator keys).

### **Future / Recommended Alerts (Prometheus/Grafana)**

- Lighthouse metrics:
  - lighthouse_head_slot vs lighthouse_current_slot.
  - lighthouse_validator_attestation_included_total vs expected.
- Nethermind metrics:
  - Sync status (fully synced vs catching up).
  - Peer count too low for prolonged periods.
- System:
  - Disk usage on EC/BN PVCs > 85%.
  - Pod restarts > N in 10min window (crashloop detection).

---

## **🚀 Rollout / Rollback Design**

### **Rollout Strategy**

1. **Bring up infra only**:
    - Deploy sentry ECs + BNs.
    - Confirm:
        - ECs syncing.
        - BNs reach checkpoint sync + peers.
2. **Introduce validator BN**:
    - Configure it to use execution-lb.
    - Confirm it fully synced.
3. **Introduce validator VC (no keys yet)**:
    - Run VC with no validators or dummy keys.
    - Confirm health, multiple --beacon-nodes connectivity.
4. **Import real validator keys**:
    - Use init-secrets-helm.sh and Lighthouse account import.
    - Confirm slashing DB mounted and functional.
5. **Enable MEV-Boost** (optional, later):
    - Deploy MEV-Boost.
    - Add builder flags to validator BN and monitor behavior.

### **Rollback Plan**

**Safe rollback rules:**

- **Never** change withdrawal addresses as part of rollback.
- **Never** discard or reuse slashing DB incorrectly.
- Prefer **stopping duties** over running in an unknown state.

### **Level 0 – Helm rollback**

For config/image mistakes:

```
cd helm/ethereum-validator

# See revisions
helm history ethereum-validator -n validators

# Roll back to previous known-good revision
helm rollback ethereum-validator <REVISION> -n validators
```

This preserves PVCs (execution DB, beacon DB, slashing DB) and secrets.

### **Level 1 – Safe stop (pause validation)**

If something looks dangerous (e.g. chain split, misconfig):

```
# Stop validator duties but keep infra up
kubectl scale statefulset/validator-client -n validators --replicas=0
kubectl scale statefulset/validator-consensus -n validators --replicas=0
```

You can later scale back up after fixing configuration.

### **Level 2 – Full teardown (last resort)**

```
# Delete chart but keep PVCs
helm uninstall ethereum-validator -n validators

# (Optional) delete namespace and PVCs ONLY if you are sure
kubectl delete namespace validators
# OR selectively:
kubectl delete pvc -n validators -l app.kubernetes.io/name=ethereum-validator
```

Before deleting any PVC that contains **slashing DB or validator data**:

1. Take an off-cluster backup.
2. Explicitly document the state so you don’t double-sign on restart.

### **Kind cluster rollback**

If the cluster state is completely broken and you want a fresh start:

```
kind delete cluster --name validator
kind create cluster --name validator --config kind-config.yaml
# Then redeploy Helm and re-import secrets/DBs as needed.
```

---

## **🧠 Assumptions, Non-Goals & Roadmap**

### **Assumptions**

- Deployment environment:
  - Single mini-PC with:
    - 1× root disk
    - 1× large LVM LV mounted at /mnt/kind-storage for Kind PVs.
- Kubernetes:
  - Kind cluster with 1 control-plane + 2 workers.
  - Local Path Provisioner used for PVs.
- Network:
  - Home / consumer-grade internet.
  - No guarantees on inbound port-forwarding → node behaves primarily as an **outbound client**.

### **Non-Goals (for now)**

- Not trying to be a **multi-region, multi-cluster** setup.
- Not providing a full **validator SaaS platform**.
- No built-in **multi-client diversity** (e.g. mix of Lighthouse + Prysm).
- No automatic **key management / remote signer** (keys live on this mini-PC).
- No highly opinionated MEV strategy (just baseline MEV-Boost integration, later).

### **Roadmap / Next Steps**

1. **Re-introduce NetworkPolicies** the right way:
    - Start with simple allow rules:
        - BN ↔ EC (8551)
        - VC ↔ all BNs (5052)
        - Pods ↔ kube-dns (53)
        - Sentries ↔ internet P2P.
    - Deny validator pods from general internet.
2. **Finalize MEV-Boost integration**:
    - Add mev-boost Deployment.
    - Wire BN flags and update README with exact config.
3. **Better observability**:
    - Pre-packaged Grafana dashboards for:
        - Nethermind
        - Lighthouse BN & VC
    - Example Prometheus alert rules.
4. **Client diversity** (optional):
    - Support a second client pair (e.g. Besu + Teku) behind execution-lb and multiple --beacon-nodes.
5. **Mainnet-ready hardening**:
    - Run on dedicated hardware / DC instead of home internet.
    - Out-of-band backups for DBs and slashing protection.
    - Add scripts for clean blue/green upgrades of clients.
