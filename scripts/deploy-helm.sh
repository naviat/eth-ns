#!/usr/bin/env bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

CHART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../helm/ethereum-validator" && pwd)"
SECRETS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/secrets"
RELEASE_NAME="ethereum-validator"
NAMESPACE="validators"

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Ethereum Validator Helm Deployment${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Step 1: Check prerequisites
echo -e "${YELLOW}Step 1: Checking prerequisites...${NC}"
if ! command -v helm &> /dev/null; then
    echo -e "${RED}❌ helm not found. Please install helm: https://helm.sh/docs/intro/install/${NC}"
    exit 1
fi

if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}❌ kubectl not found. Please install kubectl${NC}"
    exit 1
fi

if ! command -v kind &> /dev/null; then
    echo -e "${RED}❌ kind not found. Please install kind: https://kind.sigs.k8s.io/docs/user/quick-start/#installation${NC}"
    exit 1
fi

echo -e "${GREEN}✓ All prerequisites found${NC}"
echo ""

# Step 2: Create Kind cluster
echo -e "${YELLOW}Step 2: Creating Kind cluster...${NC}"
if kind get clusters | grep -q "^validator-cluster$"; then
    echo -e "${GREEN}✓ Kind cluster 'validator-cluster' already exists${NC}"
else
    kind create cluster --name validator-cluster --config "${CHART_DIR}/../kind-config.yaml"
    echo -e "${GREEN}✓ Kind cluster created${NC}"
fi
echo ""

# Step 3: Install local-path-provisioner
echo -e "${YELLOW}Step 3: Installing local-path-provisioner...${NC}"
if kubectl get storageclass local-path &> /dev/null; then
    echo -e "${GREEN}✓ local-path-provisioner already installed${NC}"
else
    kubectl apply -f local-path-storage.yaml
    kubectl wait --for=condition=ready pod -l app=local-path-provisioner -n local-path-storage --timeout=120s
    echo -e "${GREEN}✓ local-path-provisioner installed${NC}"
fi
echo ""

# Step 4: Prepare secrets
echo -e "${YELLOW}Step 4: Preparing secrets...${NC}"
if [ ! -f "${SECRETS_DIR}/jwt.hex" ]; then
    echo -e "${RED}❌ JWT secret not found at ${SECRETS_DIR}/jwt.hex${NC}"
    echo -e "${YELLOW}Run: make secrets-init${NC}"
    exit 1
fi

if [ ! -d "${SECRETS_DIR}/validator-keys" ]; then
    echo -e "${RED}❌ Validator keys not found at ${SECRETS_DIR}/validator-keys${NC}"
    echo -e "${YELLOW}Run: make secrets-init${NC}"
    exit 1
fi

# Create values file with secrets
VALUES_FILE="/tmp/ethereum-validator-values.yaml"
cat > "${VALUES_FILE}" <<EOF
# Custom values for Helm deployment
global:
  network: sepolia

secrets:
  jwtSecret: "$(cat ${SECRETS_DIR}/jwt.hex)"

# Override for Kind cluster
storage:
  storageClass: local-path
EOF

echo -e "${GREEN}✓ Secrets prepared${NC}"
echo ""

# Step 5: Lint Helm chart
echo -e "${YELLOW}Step 5: Linting Helm chart...${NC}"
helm lint "${CHART_DIR}" -f "${VALUES_FILE}"
echo -e "${GREEN}✓ Helm chart validation passed${NC}"
echo ""

# Step 6: Install/Upgrade Helm chart
echo -e "${YELLOW}Step 6: Deploying Ethereum validator...${NC}"

# Delete namespace if it exists without Helm labels (from previous failed run)
if kubectl get namespace ${NAMESPACE} &> /dev/null; then
    # Check if namespace has Helm labels
    if ! kubectl get namespace ${NAMESPACE} -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null | grep -q "Helm"; then
        echo -e "${YELLOW}Deleting existing non-Helm namespace (created without Helm)...${NC}"
        kubectl delete namespace ${NAMESPACE} --wait=true
        echo -e "${GREEN}✓ Namespace deleted${NC}"
    fi
fi

# Ensure namespace exists (Helm will create with proper labels via --create-namespace)
# But we need it now for secrets, so create it manually with Helm labels
if ! kubectl get namespace ${NAMESPACE} &> /dev/null; then
    echo -e "${YELLOW}Creating namespace with Helm labels...${NC}"
    kubectl create namespace ${NAMESPACE}
    kubectl label namespace ${NAMESPACE} app.kubernetes.io/managed-by=Helm
    kubectl annotate namespace ${NAMESPACE} meta.helm.sh/release-name=${RELEASE_NAME}
    kubectl annotate namespace ${NAMESPACE} meta.helm.sh/release-namespace=${NAMESPACE}
    echo -e "${GREEN}✓ Namespace created${NC}"
fi

# Create secret for JWT with Helm labels
echo -e "${YELLOW}Creating JWT secret with Helm labels...${NC}"
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: ${RELEASE_NAME}-jwt
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/managed-by: Helm
  annotations:
    meta.helm.sh/release-name: ${RELEASE_NAME}
    meta.helm.sh/release-namespace: ${NAMESPACE}
type: Opaque
data:
  jwt.hex: $(cat ${SECRETS_DIR}/jwt.hex | base64 | tr -d '\n')
EOF
echo -e "${GREEN}✓ JWT secret created${NC}"

# Create secret for validator keys with Helm labels
if [ -d "${SECRETS_DIR}/validator-keys" ] && [ "$(ls -A ${SECRETS_DIR}/validator-keys 2>/dev/null)" ]; then
    echo -e "${YELLOW}Creating validator-keys secret with Helm labels...${NC}"

    # Build base64 encoded data entries
    DATA_ENTRIES=""
    for file in ${SECRETS_DIR}/validator-keys/*; do
        if [ -f "$file" ]; then
            filename=$(basename "$file")
            encoded=$(cat "$file" | base64 | tr -d '\n')
            DATA_ENTRIES="${DATA_ENTRIES}  ${filename}: ${encoded}\n"
            echo "  Adding file: ${filename}"
        fi
    done

    # Create secret with Helm labels
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: ${RELEASE_NAME}-validator-keys
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/managed-by: Helm
  annotations:
    meta.helm.sh/release-name: ${RELEASE_NAME}
    meta.helm.sh/release-namespace: ${NAMESPACE}
type: Opaque
data:
$(echo -e "${DATA_ENTRIES}")
EOF
    echo -e "${GREEN}✓ Validator keys secret created${NC}"
else
    echo -e "${RED}❌ Validator keys directory not found or empty at ${SECRETS_DIR}/validator-keys${NC}"
    echo -e "${YELLOW}Run: make secrets-init-helm${NC}"
    exit 1
fi

# Install or upgrade Helm chart
helm upgrade --install ${RELEASE_NAME} "${CHART_DIR}" \
    --namespace ${NAMESPACE} \
    --create-namespace \
    -f "${VALUES_FILE}" \
    --wait \
    --timeout 10m

echo -e "${GREEN}✓ Helm chart deployed successfully${NC}"
echo ""

# Step 7: Wait for pods to be ready
echo -e "${YELLOW}Step 7: Waiting for pods to be ready...${NC}"
echo ""

echo -e "${BLUE}Waiting for sentry1...${NC}"
kubectl wait --for=condition=ready pod -l component=sentry1 -n ${NAMESPACE} --timeout=600s

echo -e "${BLUE}Waiting for sentry2...${NC}"
kubectl wait --for=condition=ready pod -l component=sentry2 -n ${NAMESPACE} --timeout=600s

echo -e "${BLUE}Waiting for validator...${NC}"
kubectl wait --for=condition=ready pod -l component=validator -n ${NAMESPACE} --timeout=600s

echo -e "${BLUE}Waiting for monitoring...${NC}"
kubectl wait --for=condition=ready pod -l component=monitoring -n monitoring --timeout=300s

echo -e "${GREEN}✓ All pods are ready${NC}"
echo ""

# Step 8: Show status
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Deployment Complete!${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

echo -e "${YELLOW}Helm Release Status:${NC}"
helm status ${RELEASE_NAME} -n ${NAMESPACE}
echo ""

echo -e "${YELLOW}Validator Pods:${NC}"
kubectl get pods -n ${NAMESPACE}
echo ""

echo -e "${YELLOW}Monitoring Pods:${NC}"
kubectl get pods -n monitoring
echo ""

echo -e "${YELLOW}Persistent Volume Claims:${NC}"
kubectl get pvc -n ${NAMESPACE}
kubectl get pvc -n monitoring
echo ""

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Access Services${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

echo -e "${YELLOW}Grafana:${NC}"
echo -e "  Local: http://localhost:30000 (NodePort)"
echo -e "  OR run: kubectl port-forward -n monitoring svc/grafana 3000:3000"
echo -e "  Then open: http://localhost:3000"
echo -e "  Credentials: admin / admin"
echo ""

echo -e "${YELLOW}Prometheus:${NC}"
echo -e "  kubectl port-forward -n monitoring svc/prometheus 9090:9090"
echo -e "  Then open: http://localhost:9090"
echo ""

echo -e "${YELLOW}View Logs:${NC}"
echo -e "  Sentry1 Execution:  kubectl logs -n ${NAMESPACE} -l component=sentry1,client=execution -f"
echo -e "  Sentry1 Consensus:  kubectl logs -n ${NAMESPACE} -l component=sentry1,client=consensus -f"
echo -e "  Validator:          kubectl logs -n ${NAMESPACE} -l component=validator,client=validator -f"
echo ""

echo -e "${YELLOW}Health Checks:${NC}"
echo -e "  kubectl get pods -n ${NAMESPACE} -w"
echo -e "  kubectl get events -n ${NAMESPACE} --sort-by='.lastTimestamp'"
echo ""

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Deployment successful! 🎉${NC}"
echo -e "${GREEN}========================================${NC}"
