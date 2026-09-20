#!/usr/bin/env bash
# =============================================================================
# access_gate — publish + (optional) gate bootstrap
# =============================================================================
# Publishes the generic access-gate Move package and, optionally, creates a first
# Gate in the same run. All IDs are written to `.env.<network>` for downstream use
# (gateway config, frontend config).
#
# Usage:
#   ./scripts/publish.sh localnet [--create-gate] [--make-immutable]
#   ./scripts/publish.sh testnet  [--create-gate] [--make-immutable]
#   ./scripts/publish.sh mainnet  [--create-gate] [--make-immutable]
#
# Flags (order-independent after the network argument):
#   --create-gate      After publishing, call access_gate::create_gate with the defaults below.
#   --make-immutable   After publishing (and gate creation, if requested), burn the UpgradeCap
#                      permanently via 0x2::package::make_immutable. IRREVERSIBLE. Prompts for
#                      explicit "YES" confirmation. Not meaningful on localnet (test-publish
#                      already creates an ephemeral immutable package).
#
# Env for --create-gate (all optional; sensible defaults shown):
#   GATE_PRICE_MIST        default 0        (free)
#   GATE_PAYMENT_RECIPIENT default = active address
#   GATE_DEFAULT_USES      default 0        (0 = unlimited pass; N = single-use)
#   GATE_SOULBOUND         default true
#   GATE_AUTO_BURN         default false
#   GATE_NFT_NAME          default "Access Pass"
#   GATE_NFT_IMAGE_URL     default ""       (set after uploading artwork to Walrus)
#   GATE_NFT_DESCRIPTION   default ""
#   GAS_BUDGET             default 200000000
# -----------------------------------------------------------------------------
set -euo pipefail
trap 'log "ERROR: publish.sh failed at line $LINENO (exit $?)."' ERR

PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Require explicit network argument.
if [ -z "${1:-}" ]; then
    log "ERROR: network argument required."
    log "Usage: ./scripts/publish.sh <localnet|testnet|mainnet> [--create-gate]"
    exit 1
fi
NETWORK="$1"
CREATE_GATE=""
MAKE_IMMUTABLE=""
for _arg in "${@:2}"; do
    case "$_arg" in
        --create-gate)    CREATE_GATE="--create-gate" ;;
        --make-immutable) MAKE_IMMUTABLE="--make-immutable" ;;
    esac
done
unset _arg
GAS_BUDGET="${GAS_BUDGET:-200000000}"
ENV_FILE="$PKG_DIR/.env.${NETWORK}"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >&2; }

command -v jq >/dev/null || { log "ERROR: jq is required"; exit 1; }

# Switch to target Sui environment.
log "Switching to Sui environment: ${NETWORK} ..."
sui client switch --env "$NETWORK" || {
    log "ERROR: unknown environment '${NETWORK}'."
    log "Add it with: sui client new-env --alias ${NETWORK} --rpc <rpc-url>"
    exit 1
}

# Print active RPC endpoint for confirmation.
ACTIVE_RPC=$(sui client envs --json 2>/dev/null \
    | jq -r ".[0][] | select(.alias==\"${NETWORK}\") | .rpc" 2>/dev/null || echo "unknown")
log "RPC endpoint: ${ACTIVE_RPC}"

log "Publishing access_gate to ${NETWORK} ..."

# Use test-publish for localnet (Move.toml doesn't define localnet env).
if [ "$NETWORK" = "localnet" ]; then
    # Use a timestamped pubfile for localnet to avoid chain-id conflicts after localnet restarts
    PUBFILE="/tmp/pub-localnet-$RANDOM.toml"
    PUBLISH_JSON=$(sui client test-publish "$PKG_DIR" --json --build-env localnet --pubfile-path "$PUBFILE" --gas-budget "$GAS_BUDGET" 2>&1) || {
        log "ERROR: test-publish failed"
        log "$PUBLISH_JSON"
        exit 1
    }
else
    PUBLISH_JSON=$(sui client publish "$PKG_DIR" --json --gas-budget "$GAS_BUDGET" 2>&1) || {
        log "ERROR: publish failed"
        log "$PUBLISH_JSON"
        exit 1
    }
fi

# Extract JSON from output (skip build logs like "INCLUDING DEPENDENCY" etc)
# Find the line that starts with '{' and take everything from there
PUBLISH_JSON_CLEAN=$(echo "$PUBLISH_JSON" | awk '/^{/,0')

# Handle both regular publish (objectChanges) and test-publish (effects.created) formats
if echo "$PUBLISH_JSON_CLEAN" | jq -e '.objectChanges' > /dev/null 2>&1; then
    # Regular publish format (testnet/mainnet)
    PACKAGE_ID=$(echo "$PUBLISH_JSON_CLEAN" | jq -r '.objectChanges[] | select(.type=="published") | .packageId')
    UPGRADE_CAP_ID=$(echo "$PUBLISH_JSON_CLEAN" | jq -r '.objectChanges[] | select(.objectType? and (.objectType|test("::package::UpgradeCap$"))) | .objectId')
else
    # test-publish format (localnet): package is the first immutable object created
    PACKAGE_ID=$(echo "$PUBLISH_JSON_CLEAN" | jq -r '.effects.created[] | select(.owner=="Immutable") | .reference.objectId' | head -1)
    # For test-publish, upgrade cap is typically the second created object (owned by sender)
    UPGRADE_CAP_ID=$(echo "$PUBLISH_JSON_CLEAN" | jq -r '.effects.created[] | select(.owner | type=="object") | .reference.objectId' | head -1)
fi

[ -n "$PACKAGE_ID" ] && [ "$PACKAGE_ID" != "null" ] || { log "ERROR: could not parse packageId"; exit 1; }

ACCESS_NFT_TYPE="${PACKAGE_ID}::access_gate::AccessNFT"
SOULBOUND_NFT_TYPE="${PACKAGE_ID}::access_gate::SoulboundAccessNFT"

{
  echo "ACCESS_GATE_PACKAGE_ID=$PACKAGE_ID"
  echo "ACCESS_GATE_UPGRADE_CAP_ID=$UPGRADE_CAP_ID"
  echo "ACCESS_NFT_TYPE=$ACCESS_NFT_TYPE"
  echo "SOULBOUND_NFT_TYPE=$SOULBOUND_NFT_TYPE"
} > "$ENV_FILE"
log "Published. packageId=$PACKAGE_ID"
log "Wrote $ENV_FILE"

if [ "$CREATE_GATE" == "--create-gate" ]; then
  PRICE="${GATE_PRICE_MIST:-0}"
  RECIPIENT="${GATE_PAYMENT_RECIPIENT:-$(sui client active-address)}"
  USES="${GATE_DEFAULT_USES:-0}"
  SOULBOUND="${GATE_SOULBOUND:-true}"
  AUTO_BURN="${GATE_AUTO_BURN:-false}"
  NFT_NAME="${GATE_NFT_NAME:-Access Pass}"
  NFT_IMAGE_URL="${GATE_NFT_IMAGE_URL:-}"
  NFT_DESCRIPTION="${GATE_NFT_DESCRIPTION:-}"

  log "Creating gate (price=$PRICE recipient=$RECIPIENT uses=$USES soulbound=$SOULBOUND auto_burn=$AUTO_BURN name='$NFT_NAME') ..."
  GATE_JSON=$(sui client call --json --gas-budget "$GAS_BUDGET" \
    --package "$PACKAGE_ID" --module access_gate --function create_gate \
    --args "$PRICE" "$RECIPIENT" "$USES" "$SOULBOUND" "$AUTO_BURN" \
    "$NFT_NAME" "$NFT_IMAGE_URL" "$NFT_DESCRIPTION")

  GATE_ID=$(echo "$GATE_JSON" | jq -r '.objectChanges[] | select(.objectType? and (.objectType|test("::access_gate::Gate$"))) | .objectId')
  ADMIN_CAP_ID=$(echo "$GATE_JSON" | jq -r '.objectChanges[] | select(.objectType? and (.objectType|test("::access_gate::AdminCap$"))) | .objectId')

  {
    echo "ACCESS_GATE_GATE_ID=$GATE_ID"
    echo "ACCESS_GATE_ADMIN_CAP_ID=$ADMIN_CAP_ID"
  } >> "$ENV_FILE"
  log "Gate created. gateId=$GATE_ID adminCapId=$ADMIN_CAP_ID"
fi

if [ "$MAKE_IMMUTABLE" = "--make-immutable" ]; then
    if [ "$NETWORK" = "localnet" ]; then
        log "NOTE: --make-immutable has no effect on localnet (test-publish already creates an ephemeral package). Skipping."
    else
        log "WARNING: About to burn UpgradeCap $UPGRADE_CAP_ID for package $PACKAGE_ID."
        log "         This is PERMANENTLY IRREVERSIBLE. The package can never be upgraded."
        read -r -p "         Type YES to confirm: " CONFIRM
        [ "$CONFIRM" = "YES" ] || { log "Aborted."; exit 1; }
        sui client call --json --gas-budget "$GAS_BUDGET" \
            --package 0x2 --module package --function make_immutable \
            --args "$UPGRADE_CAP_ID"
        sed -i '/^ACCESS_GATE_UPGRADE_CAP_ID=/d' "$ENV_FILE"
        log "Package $PACKAGE_ID is now permanently immutable. UpgradeCap removed from $ENV_FILE."
    fi
fi

log "Done. Configure the gateway/frontend with:"
log "  nft_type = $ACCESS_NFT_TYPE (or $SOULBOUND_NFT_TYPE for soulbound gates)"
log "  gate_id  = (see $ENV_FILE)"
