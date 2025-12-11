#!/bin/bash
set -e

#######################################
# Cleanup Script After Demo
# This script will:
# 1. Delete Helm release
# 2. Delete namespaces
# 3. Clean up Released PVs
# 4. Delete Kind cluster (with confirmation)
# 5. Clean up host storage directories (optional)
#######################################

echo "=========================================="
echo "  Ethereum Validator Demo Cleanup Script"
echo "=========================================="
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

#######################################
# Step 1: Delete Helm Release
#######################################
echo -e "${YELLOW}Step 1: Checking for Helm release...${NC}"
if helm list -n validators | grep -q ethereum-validator; then
    echo "Found Helm release 'ethereum-validator'"
    read -p "Delete Helm release? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "Deleting Helm release..."
        helm uninstall ethereum-validator -n validators || echo "Helm uninstall failed or already deleted"
        echo -e "${GREEN}✓ Helm release deleted${NC}"
    else
        echo "Skipping Helm release deletion"
    fi
else
    echo "No Helm release found (already deleted or not installed)"
fi
echo ""

#######################################
# Step 2: Delete Namespaces
#######################################
echo -e "${YELLOW}Step 2: Checking for namespaces...${NC}"
NAMESPACES=$(kubectl get ns --no-headers | grep -E 'validators|monitoring' | awk '{print $1}' || echo "")
if [ -n "$NAMESPACES" ]; then
    echo "Found namespaces:"
    echo "$NAMESPACES"
    read -p "Delete these namespaces? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "Deleting namespaces..."
        echo "$NAMESPACES" | while IFS= read -r ns; do
            if [ -n "$ns" ]; then
                echo "  Deleting namespace: $ns"
                kubectl delete namespace "$ns" --timeout=60s || echo "    Failed to delete $ns (may need manual cleanup)"
            fi
        done
        echo -e "${GREEN}✓ Namespaces deleted${NC}"
    else
        echo "Skipping namespace deletion"
    fi
else
    echo "No target namespaces found"
fi
echo ""

#######################################
# Step 3: Clean up Released PVs
#######################################
echo -e "${YELLOW}Step 3: Cleaning up Released PersistentVolumes...${NC}"
PVS=$(kubectl get pv --no-headers -o jsonpath='{range .items[?(@.status.phase=="Released")]}{.metadata.name}{"\n"}{end}' 2>/dev/null || echo "")

if [ -n "$PVS" ]; then
    echo "Found Released PVs:"
    echo "$PVS"
    read -p "Force delete these Released PVs? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "$PVS" | while IFS= read -r pv; do
            if [ -n "$pv" ]; then
                echo "  Patching finalizers on $pv..."
                kubectl patch pv "$pv" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || echo "    Patch failed/skipped for $pv"
                echo "  Force deleting $pv..."
                kubectl delete pv "$pv" --force --grace-period=0 2>/dev/null || echo "    Delete failed for $pv"
            fi
        done
        echo -e "${GREEN}✓ Released PVs deleted${NC}"
    else
        echo "Skipping PV deletion"
    fi
else
    echo "No Released PVs found"
fi
echo ""

# Also clean up any remaining PVs (Available or Bound to deleted PVCs)
echo "Checking for other PVs related to ethereum-validator..."
ALL_PVS=$(kubectl get pv --no-headers -o custom-columns=NAME:.metadata.name,CLAIM:.spec.claimRef.name 2>/dev/null | grep -E 'sentry|validator|grafana|prometheus' | awk '{print $1}' || echo "")

if [ -n "$ALL_PVS" ]; then
    echo "Found ethereum-validator related PVs:"
    echo "$ALL_PVS"
    read -p "Force delete ALL these PVs? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "$ALL_PVS" | while IFS= read -r pv; do
            if [ -n "$pv" ]; then
                echo "  Patching finalizers on $pv..."
                kubectl patch pv "$pv" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || echo "    Patch failed/skipped for $pv"
                echo "  Force deleting $pv..."
                kubectl delete pv "$pv" --force --grace-period=0 2>/dev/null || echo "    Delete failed for $pv"
            fi
        done
        echo -e "${GREEN}✓ All PVs deleted${NC}"
    else
        echo "Skipping remaining PV deletion"
    fi
else
    echo "No additional PVs found"
fi
echo ""

#######################################
# Step 4: Delete Kind Cluster
#######################################
echo -e "${YELLOW}Step 4: Delete Kind cluster...${NC}"
if kind get clusters 2>/dev/null | grep -q validator; then
    echo -e "${RED}WARNING: This will DELETE the entire Kind cluster 'validator'${NC}"
    echo "All data, configurations, and containers will be permanently removed."
    read -p "Are you sure you want to delete the Kind cluster? (yes/no): " -r
    echo
    if [[ $REPLY == "yes" ]]; then
        echo "Deleting Kind cluster 'validator'..."
        kind delete cluster --name validator
        echo -e "${GREEN}✓ Kind cluster deleted${NC}"
    else
        echo "Skipping Kind cluster deletion"
    fi
else
    echo "Kind cluster 'validator' not found (already deleted or not created)"
fi
echo ""

#######################################
# Step 5: Clean up Host Storage (Optional)
#######################################
echo -e "${YELLOW}Step 5: Clean up host storage directories (OPTIONAL)...${NC}"
echo "This will delete all validator data stored on the host machine."
echo "Directories that may be deleted:"
echo "  - /mnt/kind-storage/validator-data"
echo "  - /var/lib/docker/volumes/kind-validator"
echo ""
echo -e "${RED}WARNING: This will permanently delete ALL blockchain data!${NC}"
read -p "Do you want to clean up host storage? (yes/no): " -r
echo

if [[ $REPLY == "yes" ]]; then
    echo "Cleaning up host storage directories..."

    # Check if directories exist and delete
    if [ -d "/mnt/kind-storage/validator-data" ]; then
        echo "  Deleting /mnt/kind-storage/validator-data..."
        sudo rm -rf /mnt/kind-storage/validator-data
        echo "  ✓ Deleted /mnt/kind-storage/validator-data"
    else
        echo "  /mnt/kind-storage/validator-data not found"
    fi

    if [ -d "/var/lib/docker/volumes/kind-validator" ]; then
        echo "  Deleting /var/lib/docker/volumes/kind-validator..."
        sudo rm -rf /var/lib/docker/volumes/kind-validator
        echo "  ✓ Deleted /var/lib/docker/volumes/kind-validator"
    else
        echo "  /var/lib/docker/volumes/kind-validator not found"
    fi

    echo -e "${GREEN}✓ Host storage cleaned up${NC}"
else
    echo "Skipping host storage cleanup"
    echo "Note: Storage directories remain on host and can be reused for future deployments"
fi
echo ""

#######################################
# Step 6: Clean up Docker Resources (Optional)
#######################################
echo -e "${YELLOW}Step 6: Clean up Docker resources (OPTIONAL)...${NC}"
echo "This will remove unused Docker images, containers, and volumes."
read -p "Run Docker system prune? (y/n): " -n 1 -r
echo

if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Running docker system prune..."
    docker system prune -f --volumes
    echo -e "${GREEN}✓ Docker resources cleaned up${NC}"
else
    echo "Skipping Docker cleanup"
fi
echo ""

#######################################
# Summary
#######################################
echo "=========================================="
echo -e "${GREEN}Cleanup Complete!${NC}"
echo "=========================================="
echo ""
echo "Summary of cleanup:"
echo "  ✓ Helm release deleted (if confirmed)"
echo "  ✓ Namespaces deleted (if confirmed)"
echo "  ✓ PersistentVolumes cleaned up (if confirmed)"
echo "  ✓ Kind cluster deleted (if confirmed)"
echo "  ✓ Host storage cleaned up (if confirmed)"
echo "  ✓ Docker resources pruned (if confirmed)"
echo ""
echo "To verify cleanup:"
echo "  1. Check Kind clusters: kind get clusters"
echo "  2. Check PVs: kubectl get pv (should fail if cluster deleted)"
echo "  3. Check Docker: docker ps -a | grep kind"
echo "  4. Check storage: ls -lh /mnt/kind-storage/"
echo ""
echo "To redeploy:"
echo "  cd FINAL"
echo "  ./scripts/deploy-helm.sh"
echo ""
echo -e "${GREEN}Thank you for using the Ethereum Validator demo!${NC}"
