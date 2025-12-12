# Makefile for Ethereum Validator Infrastructure
# Nansen Staking DevOps Assignment

.PHONY: help
.DEFAULT_GOAL := help

# Colors for output
RED := \033[0;31m
GREEN := \033[0;32m
YELLOW := \033[1;33m
BLUE := \033[0;34m
NC := \033[0m # No Color

# Configuration
CLUSTER_NAME ?= validator
NAMESPACE ?= validators
MONITORING_NAMESPACE ?= monitoring
HELM_CHART := ./helm/ethereum-validator
RELEASE_NAME := ethereum-validator
NETWORK ?= sepolia

##@ Help

help: ## Display this help message
	@echo "$(BLUE)Ethereum Validator Infrastructure - Makefile Commands$(NC)"
	@echo ""
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make $(BLUE)<target>$(NC)\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  $(BLUE)%-20s$(NC) %s\n", $$1, $$2 } /^##@/ { printf "\n$(YELLOW)%s$(NC)\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Setup & Initialization

setup: check-deps kind-up secrets-init deploy ## Complete setup (cluster + secrets + deploy)
	@echo "$(GREEN)✓ Setup complete!$(NC)"
	@echo ""
	@echo "$(BLUE)Next steps:$(NC)"
	@echo "  1. Check status: make status"
	@echo "  2. View logs: make logs"
	@echo "  3. Access Grafana: make grafana-port-forward"
	@echo ""

check-deps: ## Check required dependencies
	@echo "$(BLUE)Checking dependencies...$(NC)"
	@command -v docker >/dev/null 2>&1 || { echo "$(RED)✗ docker not found$(NC)"; exit 1; }
	@command -v kind >/dev/null 2>&1 || { echo "$(RED)✗ kind not found$(NC)"; exit 1; }
	@command -v kubectl >/dev/null 2>&1 || { echo "$(RED)✗ kubectl not found$(NC)"; exit 1; }
	@command -v helm >/dev/null 2>&1 || { echo "$(RED)✗ helm not found$(NC)"; exit 1; }
	@echo "$(GREEN)✓ All dependencies found$(NC)"

##@ Cluster Management

kind-up: ## Create Kind cluster
	@echo "$(BLUE)Creating Kind cluster: $(CLUSTER_NAME)...$(NC)"
	@if kind get clusters | grep -q "^$(CLUSTER_NAME)$$"; then \
		echo "$(YELLOW)⚠ Cluster already exists$(NC)"; \
	else \
		kind create cluster --name $(CLUSTER_NAME) --config kind-config.yaml; \
		echo "$(GREEN)✓ Cluster created$(NC)"; \
	fi
	@kubectl cluster-info --context kind-$(CLUSTER_NAME)

kind-down: ## Delete Kind cluster
	@echo "$(BLUE)Deleting Kind cluster: $(CLUSTER_NAME)...$(NC)"
	@kind delete cluster --name $(CLUSTER_NAME) || true
	@echo "$(GREEN)✓ Cluster deleted$(NC)"

kind-restart: kind-down kind-up ## Restart Kind cluster
	@echo "$(GREEN)✓ Cluster restarted$(NC)"

##@ Secrets Management

secrets-init: ## Initialize secrets (JWT + validator keys)
	@echo "$(BLUE)Initializing secrets...$(NC)"
	@chmod +x scripts/init-secrets-helm.sh
	@./scripts/init-secrets-helm.sh
	@echo "$(GREEN)✓ Secrets initialized$(NC)"

secrets-clean: ## Clean generated secrets (WARNING: destructive)
	@echo "$(RED)WARNING: This will delete all generated secrets!$(NC)"
	@read -p "Are you sure? [y/N] " -n 1 -r; \
	echo; \
	if [[ $$REPLY =~ ^[Yy]$$ ]]; then \
		rm -rf secrets/jwt.hex secrets/mnemonic.txt secrets/validator-keys/*; \
		echo "$(GREEN)✓ Secrets cleaned$(NC)"; \
	else \
		echo "$(YELLOW)Cancelled$(NC)"; \
	fi

secrets-backup: ## Backup secrets to backup/ directory
	@echo "$(BLUE)Backing up secrets...$(NC)"
	@mkdir -p backup
	@tar -czf backup/secrets-$(shell date +%Y%m%d-%H%M%S).tar.gz secrets/
	@echo "$(GREEN)✓ Secrets backed up to backup/$(NC)"

secrets-list: ## List current secrets
	@echo "$(BLUE)Kubernetes Secrets:$(NC)"
	@kubectl get secrets -n $(NAMESPACE) 2>/dev/null || echo "$(YELLOW)No secrets found (cluster may not be running)$(NC)"
	@echo ""
	@echo "$(BLUE)Local Secrets:$(NC)"
	@ls -lh secrets/ 2>/dev/null || echo "$(YELLOW)No local secrets found$(NC)"

##@ Deployment

deploy: lint ## Deploy Ethereum validator infrastructure
	@echo "$(BLUE)Deploying $(RELEASE_NAME) to $(NAMESPACE)...$(NC)"
	@chmod +x scripts/deploy-helm.sh
	@./scripts/deploy-helm.sh
	@echo "$(GREEN)✓ Deployment complete$(NC)"

deploy-dry-run: ## Dry-run deployment (template only)
	@echo "$(BLUE)Dry-run deployment...$(NC)"
	@helm upgrade --install $(RELEASE_NAME) $(HELM_CHART) \
		--namespace $(NAMESPACE) \
		--create-namespace \
		--dry-run --debug

upgrade: lint ## Upgrade existing deployment
	@echo "$(BLUE)Upgrading $(RELEASE_NAME)...$(NC)"
	@helm upgrade $(RELEASE_NAME) $(HELM_CHART) \
		--namespace $(NAMESPACE) \
		--wait \
		--timeout 10m
	@echo "$(GREEN)✓ Upgrade complete$(NC)"
	@make health-check

undeploy: ## Remove deployment
	@echo "$(BLUE)Removing $(RELEASE_NAME)...$(NC)"
	@helm uninstall $(RELEASE_NAME) -n $(NAMESPACE) || true
	@kubectl delete namespace $(NAMESPACE) --wait=true || true
	@kubectl delete namespace $(MONITORING_NAMESPACE) --wait=true || true
	@echo "$(GREEN)✓ Deployment removed$(NC)"

redeploy: undeploy deploy ## Undeploy and redeploy (fresh start)
	@echo "$(GREEN)✓ Redeployment complete$(NC)"

##@ Rollback & Recovery

rollback: ## Rollback to previous Helm release
	@echo "$(BLUE)Rolling back $(RELEASE_NAME)...$(NC)"
	@helm rollback $(RELEASE_NAME) -n $(NAMESPACE)
	@echo "$(GREEN)✓ Rollback complete$(NC)"
	@make health-check

rollback-to: ## Rollback to specific revision (usage: make rollback-to REVISION=1)
	@if [ -z "$(REVISION)" ]; then \
		echo "$(RED)✗ Please specify REVISION (usage: make rollback-to REVISION=1)$(NC)"; \
		exit 1; \
	fi
	@echo "$(BLUE)Rolling back to revision $(REVISION)...$(NC)"
	@helm rollback $(RELEASE_NAME) $(REVISION) -n $(NAMESPACE)
	@echo "$(GREEN)✓ Rollback to revision $(REVISION) complete$(NC)"
	@make health-check

history: ## Show deployment history
	@echo "$(BLUE)Deployment history:$(NC)"
	@helm history $(RELEASE_NAME) -n $(NAMESPACE) || echo "$(YELLOW)No history found$(NC)"

##@ Validation & Testing

lint: ## Lint Helm chart
	@echo "$(BLUE)Linting Helm chart...$(NC)"
	@helm lint $(HELM_CHART)
	@echo "$(GREEN)✓ Lint passed$(NC)"

validate: lint ## Validate Helm chart (lint + template)
	@echo "$(BLUE)Validating Helm chart...$(NC)"
	@helm template $(RELEASE_NAME) $(HELM_CHART) > /dev/null
	@echo "$(GREEN)✓ Validation passed$(NC)"

test: ## Run Helm tests
	@echo "$(BLUE)Running Helm tests...$(NC)"
	@helm test $(RELEASE_NAME) -n $(NAMESPACE)
	@echo "$(GREEN)✓ Tests passed$(NC)"

health-check: ## Check health of all components
	@echo "$(BLUE)Checking component health...$(NC)"
	@echo ""
	@echo "$(BLUE)Pods:$(NC)"
	@kubectl get pods -n $(NAMESPACE) -o wide
	@echo ""
	@echo "$(BLUE)Services:$(NC)"
	@kubectl get svc -n $(NAMESPACE)
	@echo ""
	@echo "$(BLUE)PVCs:$(NC)"
	@kubectl get pvc -n $(NAMESPACE)
	@echo ""
	@echo "$(BLUE)NetworkPolicies:$(NC)"
	@kubectl get networkpolicy -n $(NAMESPACE)
	@echo ""
	@echo "$(BLUE)Pod Status Summary:$(NC)"
	@kubectl get pods -n $(NAMESPACE) --no-headers | awk '{print $$3}' | sort | uniq -c

connectivity-test: ## Test network connectivity between components
	@echo "$(BLUE)Testing connectivity...$(NC)"
	@echo ""
	@echo "$(BLUE)Testing: Validator → Sentry1 Execution$(NC)"
	@kubectl exec -n $(NAMESPACE) validator-0 -c consensus -- \
		curl -m 5 http://sentry1-execution:8545 -d '{"jsonrpc":"2.0","method":"eth_syncing","id":1}' || echo "$(RED)✗ Failed$(NC)"
	@echo ""
	@echo "$(BLUE)Testing: Validator → Sentry1 Consensus$(NC)"
	@kubectl exec -n $(NAMESPACE) validator-0 -c consensus -- \
		curl -m 5 http://sentry1-consensus:5052/eth/v1/node/health || echo "$(RED)✗ Failed$(NC)"
	@echo ""
	@echo "$(BLUE)Testing: Prometheus → Sentry1 Metrics$(NC)"
	@kubectl exec -n $(MONITORING_NAMESPACE) deploy/prometheus -- \
		curl -m 5 http://sentry1-execution.$(NAMESPACE):6060/metrics | head -5 || echo "$(RED)✗ Failed$(NC)"
	@echo ""
	@echo "$(GREEN)✓ Connectivity tests complete$(NC)"

smoke-test: health-check connectivity-test ## Run smoke tests
	@echo "$(GREEN)✓ Smoke tests complete$(NC)"

##@ Monitoring & Logs

status: ## Show deployment status
	@echo "$(BLUE)Deployment Status:$(NC)"
	@helm status $(RELEASE_NAME) -n $(NAMESPACE) || echo "$(YELLOW)No deployment found$(NC)"

logs: ## Show logs from all components
	@echo "$(BLUE)Recent logs from all components:$(NC)"
	@echo ""
	@echo "$(BLUE)Sentry1 Execution:$(NC)"
	@kubectl logs -n $(NAMESPACE) sentry1-0 -c execution --tail=10 || true
	@echo ""
	@echo "$(BLUE)Sentry1 Consensus:$(NC)"
	@kubectl logs -n $(NAMESPACE) sentry1-0 -c consensus --tail=10 || true
	@echo ""
	@echo "$(BLUE)Validator:$(NC)"
	@kubectl logs -n $(NAMESPACE) validator-0 -c validator --tail=10 || true

logs-follow: ## Follow logs from validator (usage: make logs-follow COMPONENT=validator)
	@if [ -z "$(COMPONENT)" ]; then \
		COMPONENT=validator; \
	fi; \
	echo "$(BLUE)Following logs from $(COMPONENT)...$(NC)"; \
	if [ "$(COMPONENT)" = "validator" ]; then \
		kubectl logs -f -n $(NAMESPACE) validator-0 -c validator; \
	elif [ "$(COMPONENT)" = "sentry1-execution" ]; then \
		kubectl logs -f -n $(NAMESPACE) sentry1-0 -c execution; \
	elif [ "$(COMPONENT)" = "sentry1-consensus" ]; then \
		kubectl logs -f -n $(NAMESPACE) sentry1-0 -c consensus; \
	elif [ "$(COMPONENT)" = "sentry2-execution" ]; then \
		kubectl logs -f -n $(NAMESPACE) sentry2-0 -c execution; \
	elif [ "$(COMPONENT)" = "sentry2-consensus" ]; then \
		kubectl logs -f -n $(NAMESPACE) sentry2-0 -c consensus; \
	else \
		echo "$(RED)Unknown component: $(COMPONENT)$(NC)"; \
		exit 1; \
	fi

events: ## Show recent events
	@echo "$(BLUE)Recent events:$(NC)"
	@kubectl get events -n $(NAMESPACE) --sort-by='.lastTimestamp' | tail -20

describe-validator: ## Describe validator pod
	@kubectl describe pod validator-0 -n $(NAMESPACE)

describe-sentry1: ## Describe sentry1 pod
	@kubectl describe pod sentry1-0 -n $(NAMESPACE)

describe-sentry2: ## Describe sentry2 pod
	@kubectl describe pod sentry2-0 -n $(NAMESPACE)

##@ Port Forwarding & Access

grafana-port-forward: ## Port-forward to Grafana (http://localhost:3000)
	@echo "$(BLUE)Port-forwarding to Grafana...$(NC)"
	@echo "$(GREEN)Access Grafana at: http://localhost:3000$(NC)"
	@echo "$(GREEN)Default credentials: admin / admin$(NC)"
	@kubectl port-forward -n $(MONITORING_NAMESPACE) svc/grafana 3000:3000

prometheus-port-forward: ## Port-forward to Prometheus (http://localhost:9090)
	@echo "$(BLUE)Port-forwarding to Prometheus...$(NC)"
	@echo "$(GREEN)Access Prometheus at: http://localhost:9090$(NC)"
	@kubectl port-forward -n $(NAMESPACE) svc/prometheus 9090:9090

execution-port-forward: ## Port-forward to Sentry1 execution RPC (http://localhost:8545)
	@echo "$(BLUE)Port-forwarding to Sentry1 Execution RPC...$(NC)"
	@echo "$(GREEN)Access RPC at: http://localhost:8545$(NC)"
	@kubectl port-forward -n $(NAMESPACE) svc/sentry1-execution 8545:8545

consensus-port-forward: ## Port-forward to Sentry1 consensus API (http://localhost:5052)
	@echo "$(BLUE)Port-forwarding to Sentry1 Consensus API...$(NC)"
	@echo "$(GREEN)Access API at: http://localhost:5052$(NC)"
	@kubectl port-forward -n $(NAMESPACE) svc/sentry1-consensus 5052:5052

##@ Maintenance

restart-validator: ## Restart validator pod
	@echo "$(BLUE)Restarting validator...$(NC)"
	@kubectl delete pod validator-0 -n $(NAMESPACE)
	@kubectl wait --for=condition=ready pod/validator-0 -n $(NAMESPACE) --timeout=5m
	@echo "$(GREEN)✓ Validator restarted$(NC)"

restart-sentry1: ## Restart sentry1 pod
	@echo "$(BLUE)Restarting sentry1...$(NC)"
	@kubectl delete pod sentry1-0 -n $(NAMESPACE)
	@kubectl wait --for=condition=ready pod/sentry1-0 -n $(NAMESPACE) --timeout=10m
	@echo "$(GREEN)✓ Sentry1 restarted$(NC)"

restart-sentry2: ## Restart sentry2 pod
	@echo "$(BLUE)Restarting sentry2...$(NC)"
	@kubectl delete pod sentry2-0 -n $(NAMESPACE)
	@kubectl wait --for=condition=ready pod/sentry2-0 -n $(NAMESPACE) --timeout=10m
	@echo "$(GREEN)✓ Sentry2 restarted$(NC)"

restart-all: restart-sentry1 restart-sentry2 restart-validator ## Restart all components
	@echo "$(GREEN)✓ All components restarted$(NC)"

scale-down: ## Scale down all components (for maintenance)
	@echo "$(BLUE)Scaling down all components...$(NC)"
	@kubectl scale statefulset validator --replicas=0 -n $(NAMESPACE)
	@kubectl scale statefulset sentry1 --replicas=0 -n $(NAMESPACE)
	@kubectl scale statefulset sentry2 --replicas=0 -n $(NAMESPACE)
	@echo "$(GREEN)✓ All components scaled down$(NC)"

scale-up: ## Scale up all components
	@echo "$(BLUE)Scaling up all components...$(NC)"
	@kubectl scale statefulset sentry1 --replicas=1 -n $(NAMESPACE)
	@kubectl scale statefulset sentry2 --replicas=1 -n $(NAMESPACE)
	@sleep 30  # Wait for sentries to start
	@kubectl scale statefulset validator --replicas=1 -n $(NAMESPACE)
	@echo "$(GREEN)✓ All components scaled up$(NC)"

##@ Debugging

debug-validator: ## Open shell in validator pod
	@kubectl exec -it -n $(NAMESPACE) validator-0 -c consensus -- /bin/sh

debug-sentry1-execution: ## Open shell in sentry1 execution container
	@kubectl exec -it -n $(NAMESPACE) sentry1-0 -c execution -- /bin/sh

debug-sentry1-consensus: ## Open shell in sentry1 consensus container
	@kubectl exec -it -n $(NAMESPACE) sentry1-0 -c consensus -- /bin/sh

get-validator-version: ## Get validator client version
	@echo "$(BLUE)Validator Client Version:$(NC)"
	@kubectl exec -n $(NAMESPACE) validator-0 -c validator -- lighthouse --version

get-consensus-version: ## Get consensus client version
	@echo "$(BLUE)Consensus Client Version:$(NC)"
	@kubectl exec -n $(NAMESPACE) sentry1-0 -c consensus -- lighthouse --version

get-execution-version: ## Get execution client version
	@echo "$(BLUE)Execution Client Version:$(NC)"
	@kubectl exec -n $(NAMESPACE) sentry1-0 -c execution -- nethermind --version | head -5

check-peers: ## Check peer count on all nodes
	@echo "$(BLUE)Peer counts:$(NC)"
	@echo ""
	@echo "$(BLUE)Sentry1 Execution:$(NC)"
	@kubectl exec -n $(NAMESPACE) sentry1-0 -c execution -- \
		curl -s http://localhost:8545 -d '{"jsonrpc":"2.0","method":"net_peerCount","id":1}' | jq .result || true
	@echo ""
	@echo "$(BLUE)Sentry2 Execution:$(NC)"
	@kubectl exec -n $(NAMESPACE) sentry2-0 -c execution -- \
		curl -s http://localhost:8545 -d '{"jsonrpc":"2.0","method":"net_peerCount","id":1}' | jq .result || true

check-sync: ## Check sync status of all nodes
	@echo "$(BLUE)Sync status:$(NC)"
	@echo ""
	@echo "$(BLUE)Sentry1 Execution:$(NC)"
	@kubectl exec -n $(NAMESPACE) sentry1-0 -c execution -- \
		curl -s http://localhost:8545 -d '{"jsonrpc":"2.0","method":"eth_syncing","id":1}' | jq . || true
	@echo ""
	@echo "$(BLUE)Sentry1 Consensus:$(NC)"
	@kubectl exec -n $(NAMESPACE) sentry1-0 -c consensus -- \
		curl -s http://localhost:5052/eth/v1/node/syncing | jq . || true

##@ Metrics & Monitoring

metrics-validator: ## Get validator metrics
	@kubectl exec -n $(NAMESPACE) validator-0 -c validator -- \
		curl -s http://localhost:5064/metrics | grep -E "^validator_" | head -20

metrics-sentry1-execution: ## Get sentry1 execution metrics
	@kubectl exec -n $(NAMESPACE) sentry1-0 -c execution -- \
		curl -s http://localhost:6060/metrics | grep -E "^nethermind_" | head -20

metrics-sentry1-consensus: ## Get sentry1 consensus metrics
	@kubectl exec -n $(NAMESPACE) sentry1-0 -c consensus -- \
		curl -s http://localhost:5054/metrics | grep -E "^lighthouse_" | head -20

prometheus-targets: ## Check Prometheus targets status
	@echo "$(BLUE)Prometheus targets:$(NC)"
	@kubectl exec -n $(NAMESPACE) deploy/prometheus -- \
		curl -s http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | {job: .labels.job, health: .health, lastScrape: .lastScrape}'

##@ Cleanup

clean: ## Clean up everything (cluster + secrets)
	@echo "$(RED)WARNING: This will delete everything!$(NC)"
	@read -p "Are you sure? [y/N] " -n 1 -r; \
	echo; \
	if [[ $$REPLY =~ ^[Yy]$$ ]]; then \
		make kind-down; \
		make secrets-clean; \
		echo "$(GREEN)✓ Cleanup complete$(NC)"; \
	else \
		echo "$(YELLOW)Cancelled$(NC)"; \
	fi

clean-data: ## Clean persistent data (PVCs)
	@echo "$(RED)WARNING: This will delete all persistent data!$(NC)"
	@read -p "Are you sure? [y/N] " -n 1 -r; \
	echo; \
	if [[ $$REPLY =~ ^[Yy]$$ ]]; then \
		kubectl delete pvc --all -n $(NAMESPACE) || true; \
		kubectl delete pvc --all -n $(MONITORING_NAMESPACE) || true; \
		echo "$(GREEN)✓ Data cleaned$(NC)"; \
	else \
		echo "$(YELLOW)Cancelled$(NC)"; \
	fi

##@ Documentation

docs: ## Generate documentation
	@echo "$(BLUE)Documentation available at:$(NC)"
	@echo "  - README.md - Getting started"
	@echo "  - ARCHITECTURE_FINAL.md - Architecture details"
	@echo "  - DEPLOYMENT_GUIDE.md - Deployment guide"
	@echo "  - INTERVIEW_PREP.md - Interview preparation"
	@echo "  - docs/ - Additional documentation"
	@echo "  - runbooks/ - Operational runbooks"

show-architecture: ## Show architecture diagram
	@cat README.md | sed -n '/```mermaid/,/```/p'

##@ Quick Commands

up: setup ## Alias for setup (quick start)

down: kind-down ## Alias for kind-down (quick stop)

restart: kind-restart deploy ## Full restart (cluster + deploy)

ps: status ## Alias for status (check running components)

shell: debug-validator ## Alias for debug-validator (quick shell access)

watch: ## Watch pod status (live updates)
	@watch -n 2 kubectl get pods -n $(NAMESPACE)

top: ## Show resource usage
	@echo "$(BLUE)Resource usage:$(NC)"
	@kubectl top nodes || echo "$(YELLOW)Metrics server not available$(NC)"
	@echo ""
	@kubectl top pods -n $(NAMESPACE) || echo "$(YELLOW)Metrics server not available$(NC)"

##@ CI/CD Helpers

ci-validate: check-deps lint validate ## CI validation pipeline
	@echo "$(GREEN)✓ CI validation passed$(NC)"

ci-test: ci-validate setup smoke-test ## CI test pipeline
	@echo "$(GREEN)✓ CI tests passed$(NC)"

ci-cleanup: undeploy kind-down ## CI cleanup
	@echo "$(GREEN)✓ CI cleanup complete$(NC)"
