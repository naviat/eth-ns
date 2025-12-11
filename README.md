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
```

## Success Criteria

Deployment successful when:

- [ ] All 9 pods Running
- [ ] execution-lb has 2 endpoints
- [ ] 6 NetworkPolicies applied
- [ ] Validator can reach execution-lb
- [ ] Validator CANNOT reach internet
- [ ] Grafana accessible (localhost:3000)
- [ ] Attestations being published
