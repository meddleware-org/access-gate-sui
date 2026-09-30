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
#   GATE_PRICE_MIST        default 0        (free: pays the PlatformConfig free-gate fee from gas;
#                                            a paid price must be >= the platform minimum)
#   GATE_PAYMENT_RECIPIENT default = active address
#   GATE_DEFAULT_USES      default 0        (0 = unlimited pass; N = single-use)
#   GATE_SOULBOUND         default true
#   GATE_AUTO_BURN         default false
#   GATE_NFT_NAME          default "Access Pass"
#   GATE_NFT_IMAGE_URL     default ""       (set after uploading artwork to Walrus)
#   GATE_NFT_DESCRIPTION   default ""
#   GATE_FREEZE_REQUIRES_UNPAUSED / GATE_LOCK_COMMISSION_ON_FREEZE /
#   GATE_PAUSE_BLOCKS_DECRYPTION / GATE_PAUSE_BLOCKS_ACCESS
#                          default false    (immutable GatePolicy flags)
#   GAS_BUDGET             default 200000000
#
# Safety (preflight, before anything is signed):
#   - the ACTIVE `sui client` env must already be <network> (the script never switches it —
#     run `sui client switch --env <network>` yourself);
#   - testnet/mainnet: the chain identifier must match the network;
#   - the `sui` CLI major.minor must match Published.toml `toolchain-version` (patch drift warns);
#   - mainnet additionally requires MAINNET_CONFIRM=1.
# An existing .env.<network> is kept as .env.<network>.<timestamp>.bak, never overwritten.
# -----------------------------------------------------------------------------
set -euo pipefail

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >&2; }
trap 'log "ERROR: publish.sh failed at line $LINENO (exit $?)."' ERR

PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Require explicit network argument.
if [ -z "${1:-}" ]; then
    log "ERROR: network argument required."
    log "Usage: ./scripts/publish.sh <localnet|testnet|mainnet> [--create-gate] [--make-immutable]"
    exit 1
fi
NETWORK="$1"
case "$NETWORK" in
    localnet|testnet|mainnet) ;;
    *) log "ERROR: unknown network '${NETWORK}' (expected localnet|testnet|mainnet)."; exit 1 ;;
esac
CREATE_GATE=""
MAKE_IMMUTABLE=""
for _arg in "${@:2}"; do
    case "$_arg" in
        --create-gate)    CREATE_GATE="--create-gate" ;;
        --make-immutable) MAKE_IMMUTABLE="--make-immutable" ;;
        *) log "ERROR: unknown flag '${_arg}' (a typo must not silently skip --make-immutable)."; exit 1 ;;
    esac
done
unset _arg
GAS_BUDGET="${GAS_BUDGET:-200000000}"
ENV_FILE="$PKG_DIR/.env.${NETWORK}"

command -v jq >/dev/null || { log "ERROR: jq is required"; exit 1; }

# ── Preflight (hard failures; nothing is signed before these pass) ────────────────────────────
# Chain identifiers of the public networks (`sui client chain-identifier`, hex form).
expected_chain_id() { case "$1" in testnet) echo 4c78adac ;; mainnet) echo 35834a8a ;; *) echo "" ;; esac; }
# Published.toml `toolchain-version` for a network (falls back to the testnet record).
toolchain_version() {
    local v
    v=$(awk -v s="[published.$1]" '$0==s{f=1;next} /^\[/{f=0} f && /^toolchain-version/{gsub(/.*= *"|".*/,"");print;exit}' "$PKG_DIR/Published.toml" 2>/dev/null)
    [ -n "$v" ] || v=$(awk '$0=="[published.testnet]"{f=1;next} /^\[/{f=0} f && /^toolchain-version/{gsub(/.*= *"|".*/,"");print;exit}' "$PKG_DIR/Published.toml" 2>/dev/null)
    echo "$v"
}

ACTIVE_ENV=$(sui client active-env 2>/dev/null || true)
[ "$ACTIVE_ENV" = "$NETWORK" ] || {
    log "ERROR: the active Sui env is '${ACTIVE_ENV:-<none>}', not '${NETWORK}'. This script never switches it."
    log "       Run: sui client switch --env ${NETWORK}   (add it first with: sui client new-env --alias ${NETWORK} --rpc <rpc-url>)"
    exit 1
}
WANT_CHAIN=$(expected_chain_id "$NETWORK")
if [ -n "$WANT_CHAIN" ]; then
    # Note: `sui client chain-identifier` caches the id in client.yaml (harmless).
    CHAIN=$(sui client chain-identifier 2>/dev/null | awk '/^Hex:/{print $2; exit} !/:/{print $1; exit}')
    [ "$CHAIN" = "$WANT_CHAIN" ] || { log "ERROR: chain identifier is '${CHAIN:-<unreachable>}', expected ${WANT_CHAIN} for ${NETWORK}."; exit 1; }
fi
WANT_TOOL=$(toolchain_version "$NETWORK")
CLI_VER=$(sui --version | awk '{print $2}' | cut -d- -f1)
if [ -n "$WANT_TOOL" ]; then
    if [ "${CLI_VER%.*}" != "${WANT_TOOL%.*}" ]; then
        log "ERROR: sui CLI ${CLI_VER} does not match Published.toml toolchain-version ${WANT_TOOL} (major.minor)."
        log "       Install it with: suiup install sui@testnet-v${WANT_TOOL} && suiup switch sui@testnet-v${WANT_TOOL}"
        exit 1
    elif [ "$CLI_VER" != "$WANT_TOOL" ]; then
        log "WARNING: sui CLI ${CLI_VER} differs from toolchain-version ${WANT_TOOL} at patch level."
    fi
fi
if [ "$NETWORK" = "mainnet" ] && [ "${MAINNET_CONFIRM:-}" != "1" ]; then
    log "SKIPPED: mainnet publishes real assets; re-run with MAINNET_CONFIRM=1 to proceed."
    exit 78
fi
log "Preflight OK: env=${NETWORK} chain=${CHAIN:-n/a} cli=${CLI_VER} signer=$(sui client active-address)"

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

# Both `publish` and `test-publish` return typed `objectChanges`. Extract every authority object
# by its EXACT type (no positional heuristics) so downstream custody tooling moves the right IDs.
echo "$PUBLISH_JSON_CLEAN" | jq -e '.objectChanges' > /dev/null 2>&1 \
    || { log "ERROR: publish output has no objectChanges; refusing to guess object IDs."; exit 1; }
PACKAGE_ID=$(echo "$PUBLISH_JSON_CLEAN" | jq -r '.objectChanges[] | select(.type=="published") | .packageId')
[ -n "$PACKAGE_ID" ] && [ "$PACKAGE_ID" != "null" ] || { log "ERROR: could not parse packageId"; exit 1; }

# created_id <exact objectType> — the single created object of that type (empty if none).
created_id() {
    echo "$PUBLISH_JSON_CLEAN" | jq -r --arg t "$1" \
        '[.objectChanges[] | select(.type=="created" and .objectType==$t) | .objectId] | if length==1 then .[0] else "" end'
}
UPGRADE_CAP_ID=$(created_id "0x2::package::UpgradeCap")
PUBLISHER_ID=$(created_id "0x2::package::Publisher")
PLATFORM_ADMIN_CAP_ID=$(created_id "${PACKAGE_ID}::access_gate::PlatformAdminCap")
PLATFORM_CONFIG_ID=$(created_id "${PACKAGE_ID}::access_gate::PlatformConfig")
DISPLAY_ACCESS_NFT_ID=$(created_id "0x2::display::Display<${PACKAGE_ID}::access_gate::AccessNFT>")
DISPLAY_SOULBOUND_NFT_ID=$(created_id "0x2::display::Display<${PACKAGE_ID}::access_gate::SoulboundAccessNFT>")
for _v in UPGRADE_CAP_ID PUBLISHER_ID PLATFORM_ADMIN_CAP_ID PLATFORM_CONFIG_ID DISPLAY_ACCESS_NFT_ID DISPLAY_SOULBOUND_NFT_ID; do
    [ -n "${!_v}" ] || { log "ERROR: could not find exactly one created object for ${_v}"; exit 1; }
done
unset _v

ACCESS_NFT_TYPE="${PACKAGE_ID}::access_gate::AccessNFT"
SOULBOUND_NFT_TYPE="${PACKAGE_ID}::access_gate::SoulboundAccessNFT"

# Never overwrite a previous deployment record.
if [ -f "$ENV_FILE" ]; then
    BACKUP="${ENV_FILE}.$(date -u +%Y%m%dT%H%M%SZ).bak"
    mv "$ENV_FILE" "$BACKUP"
    log "Kept the previous record as $BACKUP"
fi
{
  echo "ACCESS_GATE_PACKAGE_ID=$PACKAGE_ID"
  echo "ACCESS_GATE_UPGRADE_CAP_ID=$UPGRADE_CAP_ID"
  echo "ACCESS_GATE_PUBLISHER_ID=$PUBLISHER_ID"
  echo "ACCESS_GATE_PLATFORM_ADMIN_CAP_ID=$PLATFORM_ADMIN_CAP_ID"
  echo "ACCESS_GATE_PLATFORM_CONFIG_ID=$PLATFORM_CONFIG_ID"
  echo "ACCESS_GATE_DISPLAY_ACCESS_NFT_ID=$DISPLAY_ACCESS_NFT_ID"
  echo "ACCESS_GATE_DISPLAY_SOULBOUND_NFT_ID=$DISPLAY_SOULBOUND_NFT_ID"
  echo "ACCESS_NFT_TYPE=$ACCESS_NFT_TYPE"
  echo "SOULBOUND_NFT_TYPE=$SOULBOUND_NFT_TYPE"
} > "$ENV_FILE"
log "Published. packageId=$PACKAGE_ID"
log "Wrote $ENV_FILE"
# Committed record of the shared objects consumers need (Published.toml holds the package IDs);
# @meddleware/access-gate-client generates its `deployments` export from both files.
if [ "$NETWORK" != "localnet" ]; then
    DEPLOYMENTS="$PKG_DIR/deployments.json"
    [ -f "$DEPLOYMENTS" ] || echo '{}' > "$DEPLOYMENTS"
    jq --arg n "$NETWORK" --arg id "$PLATFORM_CONFIG_ID" '.[$n].platformConfigId = $id' "$DEPLOYMENTS" > "$DEPLOYMENTS.tmp"
    mv "$DEPLOYMENTS.tmp" "$DEPLOYMENTS"
    log "Recorded platformConfigId in $DEPLOYMENTS — commit it with Published.toml."
fi
log "Recovery: every ID above is in $ENV_FILE; if a later step fails, re-run only that step (e.g. the gate"
log "          PTB below) against ACCESS_GATE_PACKAGE_ID / ACCESS_GATE_PLATFORM_CONFIG_ID — never re-publish."

if [ "$CREATE_GATE" == "--create-gate" ]; then
  PRICE="${GATE_PRICE_MIST:-0}"
  RECIPIENT="${GATE_PAYMENT_RECIPIENT:-$(sui client active-address)}"
  USES="${GATE_DEFAULT_USES:-0}"
  SOULBOUND="${GATE_SOULBOUND:-true}"
  AUTO_BURN="${GATE_AUTO_BURN:-false}"
  NFT_NAME="${GATE_NFT_NAME:-Access Pass}"
  NFT_IMAGE_URL="${GATE_NFT_IMAGE_URL:-}"
  NFT_DESCRIPTION="${GATE_NFT_DESCRIPTION:-}"

  POLICY_ARGS=("${GATE_FREEZE_REQUIRES_UNPAUSED:-false}" "${GATE_LOCK_COMMISSION_ON_FREEZE:-false}" \
               "${GATE_PAUSE_BLOCKS_DECRYPTION:-false}" "${GATE_PAUSE_BLOCKS_ACCESS:-false}")
  # PTB string literals must be quoted inside the argument.
  q() { printf '"%s"' "$1"; }

  log "Creating gate (price=$PRICE recipient=$RECIPIENT uses=$USES soulbound=$SOULBOUND auto_burn=$AUTO_BURN policy=${POLICY_ARGS[*]} name='$NFT_NAME') ..."
  if [ "$PRICE" = "0" ]; then
    FEE=$(sui client object "$PLATFORM_CONFIG_ID" --json | jq -r '.content.free_gate_fee_mist // .content.fields.free_gate_fee_mist')
    [[ "$FEE" =~ ^[0-9]+$ ]] || { log "ERROR: could not read free_gate_fee_mist from $PLATFORM_CONFIG_ID"; exit 1; }
    log "Free gate: paying the free-gate fee of $FEE MIST."
    GATE_JSON=$(sui client ptb --gas-budget "$GAS_BUDGET" \
      --split-coins gas "[$FEE]" --assign fee \
      --move-call "${PACKAGE_ID}::access_gate::new_gate_policy" "${POLICY_ARGS[@]}" --assign policy \
      --move-call "${PACKAGE_ID}::access_gate::create_free_gate" "@$PLATFORM_CONFIG_ID" fee.0 "@$RECIPIENT" \
        "$USES" "$SOULBOUND" "$AUTO_BURN" "$(q "$NFT_NAME")" "$(q "$NFT_IMAGE_URL")" "$(q "$NFT_DESCRIPTION")" policy \
      --json)
  else
    GATE_JSON=$(sui client ptb --gas-budget "$GAS_BUDGET" \
      --move-call "${PACKAGE_ID}::access_gate::new_gate_policy" "${POLICY_ARGS[@]}" --assign policy \
      --move-call "${PACKAGE_ID}::access_gate::create_gate" "@$PLATFORM_CONFIG_ID" "$PRICE" "@$RECIPIENT" \
        "$USES" "$SOULBOUND" "$AUTO_BURN" "$(q "$NFT_NAME")" "$(q "$NFT_IMAGE_URL")" "$(q "$NFT_DESCRIPTION")" policy \
      --json)
  fi
  # Machine output: the single created object of each exact type (as for the publish above).
  # `--json` must come AFTER the other `ptb` options: placed right after `ptb` it is ignored and a
  # table is printed (CLI 1.80, verified on localnet 2026-09-30).
  gate_created_id() {
    echo "$GATE_JSON" | awk '/^{/,0' | jq -r --arg t "${PACKAGE_ID}::access_gate::$1" \
      '[.objectChanges[] | select(.type=="created" and .objectType==$t) | .objectId] | if length==1 then .[0] else "" end'
  }
  GATE_ID=$(gate_created_id Gate)
  ADMIN_CAP_ID=$(gate_created_id AdminCap)
  [ -n "$GATE_ID" ] && [ -n "$ADMIN_CAP_ID" ] || { log "ERROR: gate transaction output had no Gate/AdminCap:"; log "$GATE_JSON"; exit 1; }

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
        # A separate, specific confirmation: the earlier steps' consent does not cover this one.
        read -r -p "         Type BURN ${UPGRADE_CAP_ID:0:10} to confirm: " CONFIRM
        [ "$CONFIRM" = "BURN ${UPGRADE_CAP_ID:0:10}" ] || { log "Aborted (UpgradeCap kept; burn later with 0x2::package::make_immutable)."; exit 1; }
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
