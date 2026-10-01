#!/usr/bin/env bash
# Transfer platform authority objects from the deploy EOA to a multisig/governance address.
#
# Objects transferred (IDs recorded by `publish.sh` in .env.<network> — never discovered by guessing):
#   - PlatformAdminCap   — authorises set_platform_treasury / set_commission_bps
#   - Publisher          — required for future Display updates
#   - Display<AccessNFT>
#   - Display<SoulboundAccessNFT>
#   - UpgradeCap         — ONLY when --include-upgrade-cap is passed (see below)
#
# UpgradeCap custody follows the release lifecycle in CUSTODY.md: publish, transfer the UpgradeCap
# here with `--include-upgrade-cap`, launch, verify, then the multisig burns it on the planned date
# with scripts/make-immutable.sh. By default this script does NOT touch the UpgradeCap.
#
# On testnet/mainnet the new owners are recorded in deployments.json `custody` (commit it).
#
# Safety:
#   - Every object is re-read on-chain before transfer and must (a) have the exact expected type for
#     THIS package, (b) be owned by the active address; a Publisher/UpgradeCap must belong to this
#     package. Any mismatch aborts before anything is sent.
#   - DRY-RUN by default. DRY_RUN=0 executes, after an interactive "YES" confirmation.
#
# Prerequisites:
#   - sui CLI active on <network> with the deploy EOA as the active address
#   - .env.<network> written by `publish.sh` (ACCESS_GATE_PACKAGE_ID, ACCESS_GATE_*_ID)
#   - MULTISIG_ADDRESS set as an env var or passed as $1
#
# Usage:
#   NETWORK=testnet MULTISIG_ADDRESS=0x<64hex> bash scripts/transfer-platform-authority.sh
#   NETWORK=testnet MULTISIG_ADDRESS=0x<64hex> bash scripts/transfer-platform-authority.sh --include-upgrade-cap
#   DRY_RUN=0 NETWORK=testnet MULTISIG_ADDRESS=0x<64hex> bash scripts/transfer-platform-authority.sh

set -euo pipefail

warn() { echo "$*" >&2; }

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
    --*) warn "ERROR: unknown flag '$arg'."; exit 1 ;;
    *) POSITIONAL+=("$arg") ;;
  esac
done
MULTISIG_ADDRESS="${MULTISIG_ADDRESS:-${POSITIONAL[0]:-}}"

[[ -n "$MULTISIG_ADDRESS" ]] || { warn "ERROR: MULTISIG_ADDRESS is required (env var or \$1)."; exit 1; }
[[ "$MULTISIG_ADDRESS" =~ ^0x[0-9a-fA-F]{64}$ ]] || { warn "ERROR: MULTISIG_ADDRESS must be a 0x-prefixed 64-hex address."; exit 1; }

PACKAGE_ID="${ACCESS_GATE_PACKAGE_ID:-${PACKAGE_ID:-}}"
[[ -n "$PACKAGE_ID" ]] || { warn "ERROR: ACCESS_GATE_PACKAGE_ID not set — run publish.sh or source .env.${NETWORK}."; exit 1; }

# ── Preflight (hard failures before anything is signed; same rules as access-gate-sui publish.sh) ──
# The active env must be NETWORK; testnet/mainnet must report their chain identifier; the CLI
# major.minor must match Published.toml `toolchain-version`; mainnet needs MAINNET_CONFIRM=1.
preflight() {
  local published_toml="$1" env chain want tool cli
  env="$(sui client active-env 2>/dev/null || true)"
  [ "$env" = "$NETWORK" ] || { echo "ERROR: active Sui env is '${env:-<none>}', expected '$NETWORK' (sui client switch --env $NETWORK)." >&2; exit 1; }
  case "$NETWORK" in testnet) want=4c78adac ;; mainnet) want=35834a8a ;; *) want="" ;; esac
  if [ -n "$want" ]; then
    chain="$(sui client chain-identifier 2>/dev/null | awk '/^Hex:/{print $2; exit} !/:/{print $1; exit}')"
    [ "$chain" = "$want" ] || { echo "ERROR: chain identifier is '${chain:-<unreachable>}', expected $want for $NETWORK." >&2; exit 1; }
  fi
  tool="$(awk -v s="[published.$NETWORK]" '$0==s{f=1;next} /^\[/{f=0} f && /^toolchain-version/{gsub(/.*= *"|".*/,"");print;exit}' "$published_toml" 2>/dev/null || true)"
  cli="$(sui --version | awk '{print $2}' | cut -d- -f1)"
  if [ -n "$tool" ] && [ "${cli%.*}" != "${tool%.*}" ]; then
    echo "ERROR: sui CLI $cli does not match Published.toml toolchain-version $tool (major.minor)." >&2; exit 1
  fi
  if [ "$NETWORK" = "mainnet" ] && [ "${MAINNET_CONFIRM:-}" != "1" ]; then
    echo "SKIPPED: mainnet — re-run with MAINNET_CONFIRM=1 to proceed." >&2; exit 78
  fi
}
preflight "$(dirname "$0")/../Published.toml"
ACTIVE_ADDRESS="$(sui client active-address 2>/dev/null)"

# Long-form (64-hex) address, lower-case, for comparing on-chain type strings.
long_addr() { local h="${1#0x}"; printf '0x%064s' "${h,,}" | tr ' ' 0; }
PKG_LONG="$(long_addr "$PACKAGE_ID")"
FW="0x0000000000000000000000000000000000000000000000000000000000000002"

echo "Active address : $ACTIVE_ADDRESS"
echo "Package ID     : $PACKAGE_ID"
echo "Network        : $NETWORK"
echo "Recipient      : $MULTISIG_ADDRESS"
echo "Dry run        : $DRY_RUN"
echo ""

# verify_object <id> <label> <expected long-form type> [<expected content.package>]
# Aborts unless the object exists, has exactly the expected type, is owned by the active address,
# and (for Publisher / UpgradeCap) belongs to this package.
verify_object() {
  local id="$1" label="$2" want_type="$3" want_pkg="${4:-}"
  [[ -n "$id" ]] || { warn "ERROR: no recorded ID for $label in .env.${NETWORK}."; exit 1; }
  local json typ owner pkg
  json="$(sui client object "$id" --json 2>/dev/null)" || { warn "ERROR: cannot read $label ($id)."; exit 1; }
  typ="$(jq -r '.objType // empty' <<<"$json")"
  owner="$(jq -r '.owner.AddressOwner // empty' <<<"$json")"
  [[ "$typ" == "$want_type" ]] || { warn "ERROR: $label $id has type '$typ', expected '$want_type'."; exit 1; }
  [[ "$(long_addr "$owner")" == "$(long_addr "$ACTIVE_ADDRESS")" ]] \
    || { warn "ERROR: $label $id is owned by '${owner:-<not address-owned>}', not the active address."; exit 1; }
  if [[ -n "$want_pkg" ]]; then
    pkg="$(jq -r '.content.package // empty' <<<"$json")"
    [[ "$(long_addr "$pkg")" == "$want_pkg" ]] || { warn "ERROR: $label $id belongs to package '$pkg', not $PACKAGE_ID."; exit 1; }
  fi
  echo "OK    $label $id verified"
}

verify_object "${ACCESS_GATE_PLATFORM_ADMIN_CAP_ID:-}" "PlatformAdminCap" "${PKG_LONG}::access_gate::PlatformAdminCap"
verify_object "${ACCESS_GATE_PUBLISHER_ID:-}" "Publisher" "${FW}::package::Publisher" "$PKG_LONG"
verify_object "${ACCESS_GATE_DISPLAY_ACCESS_NFT_ID:-}" "Display<AccessNFT>" "${FW}::display::Display<${PKG_LONG}::access_gate::AccessNFT>"
verify_object "${ACCESS_GATE_DISPLAY_SOULBOUND_NFT_ID:-}" "Display<SoulboundAccessNFT>" "${FW}::display::Display<${PKG_LONG}::access_gate::SoulboundAccessNFT>"
IDS=("${ACCESS_GATE_PLATFORM_ADMIN_CAP_ID}" "${ACCESS_GATE_PUBLISHER_ID}" "${ACCESS_GATE_DISPLAY_ACCESS_NFT_ID}" "${ACCESS_GATE_DISPLAY_SOULBOUND_NFT_ID}")
LABELS=("PlatformAdminCap" "Publisher" "Display<AccessNFT>" "Display<SoulboundAccessNFT>")
if [[ -n "$INCLUDE_UPGRADE_CAP" ]]; then
  echo "NOTE: the package stays upgradeable under multisig control until the multisig burns the"
  echo "      UpgradeCap with scripts/make-immutable.sh on the planned date (CUSTODY.md)."
  verify_object "${ACCESS_GATE_UPGRADE_CAP_ID:-}" "UpgradeCap" "${FW}::package::UpgradeCap" "$PKG_LONG"
  IDS+=("${ACCESS_GATE_UPGRADE_CAP_ID}")
  LABELS+=("UpgradeCap")
fi

echo ""
echo "=== Transfer plan → $MULTISIG_ADDRESS ==="
for i in "${!IDS[@]}"; do echo "  ${LABELS[$i]}  ${IDS[$i]}"; done
echo ""

if [[ "$DRY_RUN" != "0" ]]; then
  echo "Dry run complete — nothing sent. Re-run with DRY_RUN=0 to execute."
  exit 0
fi

read -r -p "Transfer these objects to $MULTISIG_ADDRESS on $NETWORK? Type YES to confirm: " CONFIRM
[[ "$CONFIRM" == "YES" ]] || { warn "Aborted."; exit 1; }
if [[ -n "$INCLUDE_UPGRADE_CAP" ]]; then
  # Moving upgrade authority is its own decision: the YES above does not cover it.
  read -r -p "Also hand UpgradeCap ${ACCESS_GATE_UPGRADE_CAP_ID} to the multisig? Type UPGRADECAP to confirm: " CONFIRM_CAP
  [[ "$CONFIRM_CAP" == "UPGRADECAP" ]] || { warn "Aborted (nothing sent)."; exit 1; }
fi

for i in "${!IDS[@]}"; do
  if ! OUT="$(sui client transfer --object-id "${IDS[$i]}" --to "$MULTISIG_ADDRESS" --gas-budget 10000000 --json 2>&1)"; then
    warn "ERROR: transferring ${LABELS[$i]} failed:"; warn "$OUT"
    warn "Recovery: the objects before it were sent; re-run with only the remaining ones still owned by $ACTIVE_ADDRESS"
    warn "          (the script re-verifies ownership, so a re-run refuses anything already transferred)."
    exit 1
  fi
  echo "OK    ${LABELS[$i]} transferred (tx $(jq -r '.digest // "?"' <<<"$(awk '/^{/,0' <<<"$OUT")"))."
done
echo ""
echo "All transfers submitted. Verify ownership on-chain for $MULTISIG_ADDRESS ($NETWORK)."
DEPLOYMENTS="$(dirname "$0")/../deployments.json"
if [[ "$NETWORK" != "localnet" && -f "$DEPLOYMENTS" ]]; then
  jq --arg n "$NETWORK" --arg ms "$MULTISIG_ADDRESS" --arg cap "$INCLUDE_UPGRADE_CAP" \
    '.[$n].custody.multisigAddress = $ms
     | if $cap == "1" then .[$n].custody.upgradeCapOwner = $ms else . end' \
    "$DEPLOYMENTS" > "$DEPLOYMENTS.tmp" && mv "$DEPLOYMENTS.tmp" "$DEPLOYMENTS"
  echo "Recorded the multisig in deployments.json — set custody.plannedBurnDate and commit it."
fi
