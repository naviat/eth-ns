#!/bin/bash
set -e

# Colors
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

SECRETS_DIR="$(dirname "$0")/../secrets"

echo -e "${BLUE}=== Initializing Secrets for Helm Deployment ===${NC}\n"

# Create directories
mkdir -p "$SECRETS_DIR/validator-keys"

# Generate single JWT secret (used by all nodes in Helm chart)
echo -e "${BLUE}Generating JWT secret...${NC}"

if [ -f "$SECRETS_DIR/jwt.hex" ]; then
    echo -e "${YELLOW}jwt.hex already exists, skipping${NC}"
else
    openssl rand -hex 32 > "$SECRETS_DIR/jwt.hex"
    chmod 600 "$SECRETS_DIR/jwt.hex"
    echo -e "${GREEN}✓ Generated jwt.hex${NC}"
fi

# Generate validator keystore password
echo -e "\n${BLUE}Generating validator keystore password...${NC}"
if [ -f "$SECRETS_DIR/validator-keys/password.txt" ]; then
    echo -e "${YELLOW}password.txt already exists, skipping${NC}"
else
    # Generate a strong random password
    openssl rand -base64 32 > "$SECRETS_DIR/validator-keys/password.txt"
    chmod 600 "$SECRETS_DIR/validator-keys/password.txt"
    echo -e "${GREEN}✓ Generated password.txt${NC}"
fi

# Generate test validator keys using staking-deposit-cli
echo -e "\n${BLUE}Generating test validator keys...${NC}"

if [ -f "$SECRETS_DIR/validator-keys/keystore-m_12381_3600_0_0_0.json" ]; then
    echo -e "${YELLOW}Validator keys already exist, skipping${NC}"
else
    echo -e "${YELLOW}Using staking-deposit-cli to generate test keys...${NC}"

    # Check if Docker is running
    if ! docker info > /dev/null 2>&1; then
        echo -e "${RED}Error: Docker is not running. Please start Docker and try again.${NC}"
        exit 1
    fi

    # Pull the ethstaker deposit CLI image
    echo -e "${YELLOW}Pulling ethstaker deposit CLI...${NC}"
    docker pull ghcr.io/ethstaker/ethstaker-deposit-cli:latest

    # Generate 1 test validator key for Sepolia
    # Using a fixed test mnemonic for demo purposes
    MNEMONIC="test test test test test test test test test test test junk"

    # Save mnemonic
    echo "$MNEMONIC" > "$SECRETS_DIR/mnemonic.txt"
    chmod 600 "$SECRETS_DIR/mnemonic.txt"

    PASSWORD=$(cat "$SECRETS_DIR/validator-keys/password.txt")

    # Create validator keys using the deposit CLI
    echo -e "${YELLOW}Generating validator keys...${NC}"
    docker run --rm -it \
        -v "$PWD/$SECRETS_DIR/validator-keys:/app/validator_keys" \
        ghcr.io/ethstaker/ethstaker-deposit-cli:latest \
        existing-mnemonic \
        --num_validators=1 \
        --validator_start_index=0 \
        --chain=sepolia \
        --keystore_password="$PASSWORD" \
        --mnemonic="$MNEMONIC"

    echo -e "${GREEN}✓ Generated 1 test validator key${NC}"
    echo -e "${YELLOW}⚠️  These are TEST keys for Sepolia demonstration only!${NC}"
    echo -e "${YELLOW}⚠️  Mnemonic: test test test test test test test test test test test junk${NC}"

    # Fix ownership - files created by Docker are owned by root
    # Change ownership to current user
    echo -e "${YELLOW}Fixing file ownership...${NC}"
    if [ "$(id -u)" -eq 0 ]; then
        # Running as root, keep root ownership but fix permissions
        chmod 644 "$SECRETS_DIR"/validator-keys/*.json 2>/dev/null || true
    else
        # Running as regular user, use sudo to fix ownership
        if command -v sudo &> /dev/null; then
            sudo chown -R $(id -u):$(id -g) "$SECRETS_DIR/validator-keys"
            echo -e "${GREEN}✓ Fixed ownership to $(whoami)${NC}"
        else
            echo -e "${YELLOW}⚠️  Warning: Cannot fix ownership (no sudo). Files owned by root.${NC}"
            echo -e "${YELLOW}    Run: sudo chown -R \$(id -u):\$(id -g) $SECRETS_DIR/validator-keys${NC}"
        fi
    fi
fi

# Set proper permissions
chmod 700 "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR/validator-keys" 2>/dev/null || true
find "$SECRETS_DIR" -type f -exec chmod 600 {} \; 2>/dev/null || true

echo -e "\n${GREEN}=== Secrets Initialization Complete ===${NC}"
echo -e "${BLUE}Generated:${NC}"
echo "  • JWT secret: secrets/jwt.hex"
echo "  • Validator password: secrets/validator-keys/password.txt"
echo "  • Validator keystore: secrets/validator-keys/keystore-*.json"
echo "  • Deposit data: secrets/validator-keys/deposit_data-*.json"
echo "  • Mnemonic: secrets/mnemonic.txt"
echo ""
echo -e "${YELLOW}⚠️  IMPORTANT:${NC}"
echo "  • These secrets are gitignored and will NOT be committed"
echo "  • Never share validator keys, mnemonic, or JWT secrets!"
echo "  • For production, use a secure mnemonic generator"
echo ""
echo -e "${BLUE}Next steps:${NC}"
echo "  1. Deploy with Helm: cd k8s/helm && ./deploy-helm.sh"
echo "  2. Or deploy with raw manifests: cd k8s && ./deploy-kind.sh"
echo ""
