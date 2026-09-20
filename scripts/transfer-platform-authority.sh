#!/usr/bin/env bash
# Transfer platform authority objects from the deploy EOA to a multisig/governance address.
#
# Objects transferred:
#   - PlatformAdminCap   — authorises set_platform_treasury / set_commission_bps
#   - Publisher          — required for future Display updates
#   - Display<AccessNFT>
#   - Display<SoulboundAccessNFT>
#   - UpgradeCap         — ONLY when --include-upgrade-cap is passed (see below)
#
# UpgradeCap custody (two options — pick ONE):
#   * BURN it via `publish.sh --make-immutable` (package becomes permanently immutable), OR
#   * TRANSFER it to the multisig with this script's `--include-upgrade-cap` flag (multisig retains
#     upgrade authority under M-of-N control).
#   Both are safe; choose per deployment. By default this script does NOT touch the UpgradeCap.
#
# Prerequisites:
#   - sui CLI active with the deploy EOA as the active address (sui client active-address)
#   - PACKAGE_ID and PUBLISHED_AT set in .env.<network> (sourced below)
#   - MULTISIG_ADDRESS set as an env var or passed as $1
#   - For --include-upgrade-cap: ACCESS_GATE_UPGRADE_CAP_ID in .env.<network> (written by publish.sh),
#     or discovered from the active address's owned objects.
#
# Usage:
#   NETWORK=testnet MULTISIG_ADDRESS=0x<64hex> bash scripts/transfer-platform-authority.sh
#   NETWORK=testnet MULTISIG_ADDRESS=0x<64hex> bash scripts/transfer-platform-authority.sh --include-upgrade-cap
#
# The script is intentionally DRY-RUN by default. Set DRY_RUN=0 to execute.

set -euo pipefail

NETWORK="${NETWORK:-testnet}"
ENV_FILE="$(dirname "$0")/../.env.${NETWORK}"

if [[ -f "$ENV_FILE" ]]; then
  # shellcheck source=/dev/null
  source "$ENV_FILE"
fi

DRY_RUN="${DRY_RUN:-1}"
INCLUDE_UPGRADE_CAP=""
POSITIONAL=()
for arg in "$@"; do
  case "$arg" in
    --include-upgrade-cap) INCLUDE_UPGRADE_CAP="1" ;;
    *) POSITIONAL+=("$arg") ;;
  esac
done
MULTISIG_ADDRESS="${MULTISIG_ADDRESS:-${POSITIONAL[0]:-}}"

if [[ -z "$MULTISIG_ADDRESS" ]]; then
  echo "ERROR: MULTISIG_ADDRESS is required. Set it as an env var or pass it as \$1."
  exit 1
fi

if [[ -z "${PACKAGE_ID:-}" ]]; then
  echo "ERROR: PACKAGE_ID not set. Source .env.${NETWORK} or set it manually."
  exit 1
fi

ACTIVE_ADDRESS="$(sui client active-address 2>/dev/null)"
echo "Active address : $ACTIVE_ADDRESS"
echo "Package ID     : $PACKAGE_ID"
echo "Network        : $NETWORK"
echo "Recipient      : $MULTISIG_ADDRESS"
echo "Dry run        : $DRY_RUN"
echo ""

# Discover owned objects of the relevant types.
discover_object() {
  local type_filter="$1"
  local label="$2"
  local result
  result="$(sui client objects --json 2>/dev/null \
    | jq -r --arg t "$type_filter" \
        '.[] | select(.data.type | test($t)) | .data.objectId' \
    | head -n1)"
  if [[ -z "$result" ]]; then
    echo "WARNING: no $label found under active address — skipping."
  fi
  echo "$result"
}

PLATFORM_ADMIN_CAP="$(discover_object "::access_gate::PlatformAdminCap" "PlatformAdminCap")"
PUBLISHER="$(discover_object "0x2::package::Publisher" "Publisher")"
NFT_DISPLAY="$(discover_object "0x2::display::Display<.*AccessNFT>" "Display<AccessNFT>")"
SB_DISPLAY="$(discover_object "0x2::display::Display<.*SoulboundAccessNFT>" "Display<SoulboundAccessNFT>")"

transfer_object() {
  local obj_id="$1"
  local label="$2"
  if [[ -z "$obj_id" ]]; then
    echo "SKIP  $label (not found)"
    return
  fi
  echo "TRANSFER $label ($obj_id) → $MULTISIG_ADDRESS"
  if [[ "$DRY_RUN" == "0" ]]; then
    sui client transfer \
      --object-id "$obj_id" \
      --to "$MULTISIG_ADDRESS" \
      --gas-budget 10000000
    echo "OK    $label transferred."
  else
    echo "      (dry run — set DRY_RUN=0 to execute)"
  fi
}

echo "=== Platform authority transfer ==="
transfer_object "$PLATFORM_ADMIN_CAP" "PlatformAdminCap"
transfer_object "$PUBLISHER"          "Publisher"
transfer_object "$NFT_DISPLAY"        "Display<AccessNFT>"
transfer_object "$SB_DISPLAY"         "Display<SoulboundAccessNFT>"

if [[ -n "$INCLUDE_UPGRADE_CAP" ]]; then
  echo ""
  echo "=== UpgradeCap transfer (multisig custody option) ==="
  echo "NOTE: transferring the UpgradeCap keeps the package upgradeable under multisig control."
  echo "      The alternative is burning it via 'publish.sh --make-immutable'. Do NOT do both."
  UPGRADE_CAP="${ACCESS_GATE_UPGRADE_CAP_ID:-}"
  if [[ -z "$UPGRADE_CAP" ]]; then
    UPGRADE_CAP="$(discover_object "0x2::package::UpgradeCap" "UpgradeCap")"
  fi
  transfer_object "$UPGRADE_CAP" "UpgradeCap"
fi

echo ""
if [[ "$DRY_RUN" != "0" ]]; then
  echo "Dry run complete. Re-run with DRY_RUN=0 to execute transfers."
else
  echo "All transfers submitted. Verify ownership on Sui Explorer:"
  echo "  https://suivision.xyz/account/$MULTISIG_ADDRESS?network=$NETWORK"
fi
