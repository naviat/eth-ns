#!/usr/bin/env bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Reclaim docker-lv for Kind Storage${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run as root or with sudo${NC}"
    exit 1
fi

# Step 1: Check current state
echo -e "${YELLOW}Step 1: Checking current LVM state...${NC}"
echo ""
lvs
echo ""

# Check if docker-lv exists
if ! lvs | grep -q "docker-lv"; then
    echo -e "${YELLOW}docker-lv not found. Creating fresh kind-lv instead.${NC}"
    SKIP_REMOVAL=true
else
    SKIP_REMOVAL=false
fi

if [ "$SKIP_REMOVAL" = false ]; then
    # Step 2: Stop Docker
    echo -e "${YELLOW}Step 2: Stopping Docker...${NC}"
    systemctl stop docker
    echo -e "${GREEN}✓ Docker stopped${NC}"
    echo ""

    # Step 3: Unmount docker-lv if mounted
    echo -e "${YELLOW}Step 3: Checking if docker-lv is mounted...${NC}"
    if mount | grep -q "/var/lib/docker"; then
        echo "Unmounting /var/lib/docker..."
        umount /var/lib/docker
        echo -e "${GREEN}✓ Unmounted /var/lib/docker${NC}"
    else
        echo -e "${GREEN}✓ /var/lib/docker not mounted${NC}"
    fi
    echo ""

    # Step 4: Remove docker-lv from fstab
    echo -e "${YELLOW}Step 4: Removing docker-lv from /etc/fstab...${NC}"
    if grep -q "docker-lv" /etc/fstab; then
        sed -i.bak '/docker-lv/d' /etc/fstab
        echo -e "${GREEN}✓ Removed from fstab (backup: /etc/fstab.bak)${NC}"
    else
        echo -e "${GREEN}✓ Not in fstab${NC}"
    fi
    echo ""

    # Step 5: Remove docker-lv
    echo -e "${YELLOW}Step 5: Removing docker-lv logical volume...${NC}"
    lvremove -f /dev/ubuntu-vg/docker-lv
    echo -e "${GREEN}✓ docker-lv removed (800GB freed!)${NC}"
    echo ""
fi

# Step 6: Show available space
echo -e "${YELLOW}Step 6: Checking available space in ubuntu-vg...${NC}"
vgs ubuntu-vg
echo ""

# Step 7: Create kind-lv (1TB)
echo -e "${YELLOW}Step 7: Creating kind-lv (1TB) for Kind storage...${NC}"

# Check if kind-lv already exists
if lvs | grep -q "kind-lv"; then
    echo -e "${YELLOW}⚠ kind-lv already exists. Skipping creation.${NC}"
else
    lvcreate -L 1000G -n kind-lv ubuntu-vg
    echo -e "${GREEN}✓ kind-lv created (1TB)${NC}"
fi
echo ""

# Step 8: Format kind-lv
echo -e "${YELLOW}Step 8: Formatting kind-lv with ext4...${NC}"
if blkid /dev/ubuntu-vg/kind-lv | grep -q "ext4"; then
    echo -e "${YELLOW}⚠ kind-lv already formatted${NC}"
else
    mkfs.ext4 /dev/ubuntu-vg/kind-lv
    echo -e "${GREEN}✓ Formatted with ext4${NC}"
fi
echo ""

# Step 9: Create mount point
echo -e "${YELLOW}Step 9: Creating mount point...${NC}"
mkdir -p /mnt/kind-storage
echo -e "${GREEN}✓ Created /mnt/kind-storage${NC}"
echo ""

# Step 10: Mount kind-lv
echo -e "${YELLOW}Step 10: Mounting kind-lv...${NC}"
if mount | grep -q "/mnt/kind-storage"; then
    echo -e "${YELLOW}⚠ Already mounted${NC}"
else
    mount /dev/ubuntu-vg/kind-lv /mnt/kind-storage
    echo -e "${GREEN}✓ Mounted to /mnt/kind-storage${NC}"
fi
echo ""

# Step 11: Add to fstab for persistence
echo -e "${YELLOW}Step 11: Adding to /etc/fstab for auto-mount...${NC}"
if grep -q "kind-lv" /etc/fstab; then
    echo -e "${YELLOW}⚠ Already in fstab${NC}"
else
    echo "/dev/ubuntu-vg/kind-lv /mnt/kind-storage ext4 defaults 0 2" >> /etc/fstab
    echo -e "${GREEN}✓ Added to fstab${NC}"
fi
echo ""

# Step 12: Create Kind storage directory
echo -e "${YELLOW}Step 12: Creating Kind storage directory...${NC}"
mkdir -p /mnt/kind-storage/validator-data
chmod 777 /mnt/kind-storage/validator-data
echo -e "${GREEN}✓ Created /mnt/kind-storage/validator-data${NC}"
echo ""

# Step 13: Restart Docker (if needed)
if [ "$SKIP_REMOVAL" = false ]; then
    echo -e "${YELLOW}Step 13: Restarting Docker...${NC}"
    systemctl start docker
    echo -e "${GREEN}✓ Docker started${NC}"
    echo ""
fi

# Step 14: Show final state
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Final State${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

echo -e "${YELLOW}Logical Volumes:${NC}"
lvs
echo ""

echo -e "${YELLOW}Mount Points:${NC}"
df -h | grep -E "(Filesystem|kind-storage|ubuntu-lv)"
echo ""

echo -e "${YELLOW}Volume Group Free Space:${NC}"
vgs ubuntu-vg
echo ""

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Success! 🎉${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

echo -e "${YELLOW}Summary:${NC}"
echo "  ✓ Removed docker-lv (800GB freed)"
echo "  ✓ Created kind-lv (1TB)"
echo "  ✓ Mounted at /mnt/kind-storage"
echo "  ✓ Auto-mount configured in fstab"
echo "  ✓ Kind storage ready at /mnt/kind-storage/validator-data"
echo ""

echo -e "${YELLOW}Next Steps:${NC}"
echo "  1. Update kind-config.yaml to use /mnt/kind-storage/validator-data"
echo "  2. Deploy Kind cluster: cd k8s/helm && ./deploy-helm.sh"
echo ""

echo -e "${YELLOW}Storage Allocation:${NC}"
echo "  - Total: 1TB (kind-lv)"
echo "  - Available for Kind PVCs: ~980GB"
echo "  - Planned usage:"
echo "    • Sentry1 execution: 300GB"
echo "    • Sentry2 execution: 300GB"
echo "    • Sentry1 consensus: 100GB"
echo "    • Sentry2 consensus: 100GB"
echo "    • Validator consensus: 100GB"
echo "    • Validator keys: 10GB"
echo "    • Prometheus: 50GB"
echo "    • Grafana: 10GB"
echo "    • Total: ~970GB (fits perfectly!)"
