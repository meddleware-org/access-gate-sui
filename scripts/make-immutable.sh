#!/usr/bin/env bash
# Burn this package's UpgradeCap, making the published package PERMANENTLY IMMUTABLE.
#
# This is step 5 of the release lifecycle in CUSTODY.md (publish → transfer to the multisig →
# launch → verify → burn on the planned date). It works for either owner of the cap:
#   - the active address owns the cap   → burns it directly (after a "YES" confirmation);
#   - a multisig owns the cap           → writes the unsigned make_immutable transaction and prints
#                                         the exact steps to sign, combine and execute it.
#
# Usage:
#   NETWORK=testnet bash scripts/make-immutable.sh            # dry run (default): verify and explain
#   NETWORK=testnet DRY_RUN=0 bash scripts/make-immutable.sh  # execute (IRREVERSIBLE) / write the tx
#
# Inputs:
#   NETWORK          target network; the active `sui client` env must equal it (never switched here)
#   UPGRADE_CAP_ID   optional; defaults to Published.toml [published.<network>].upgrade-capability,
#                    then ACCESS_GATE_UPGRADE_CAP_ID in .env.<network>
#   PACKAGE_ID       optional; defaults to Published.toml [published.<network>].published-at,
#                    then ACCESS_GATE_PACKAGE_ID in .env.<network>
#   GAS_BUDGET       optional; default 100000000 MIST
#   MAINNET_CONFIRM  must be 1 for mainnet (a skipped mainnet run exits 78)
#   OUT_DIR          multisig path only: where the unsigned transaction is written (default ./custody-out)

set -euo pipefail

NETWORK="${NETWORK:-testnet}"
DRY_RUN="${DRY_RUN:-1}"
GAS_BUDGET="${GAS_BUDGET:-100000000}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PUBLISHED_TOML="$REPO_ROOT/Published.toml"
PACKAGE_LABEL="access_gate"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/custody-out}"
UPGRADE_CAP_TYPE="0x0000000000000000000000000000000000000000000000000000000000000002::package::UpgradeCap"

log() { printf '%s\n' "$*" >&2; }

# Read one key from the [published.<network>] section of Published.toml.
published_field() {
  awk -v section="[published.${NETWORK}]" -v key="$1" '
    $0 == section { in_section = 1; next }
    /^\[/         { in_section = 0 }
    in_section && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      gsub(/.*=[[:space:]]*"/, ""); gsub(/".*/, ""); print; exit
    }
  ' "$PUBLISHED_TOML"
}

# Record a completed burn in deployments.json (localnet has no record). Published.toml is written by
# Sui and is left untouched; its upgrade-capability then names a consumed object.
record_burn() {
  local deployments="$REPO_ROOT/deployments.json" recorded
  [ "$NETWORK" != "localnet" ] && [ -f "$deployments" ] || return 0
  # deployments.json describes the current publication only: a superseded package's cap (passed as
  # UPGRADE_CAP_ID) leaves it untouched.
  recorded="$(published_field upgrade-capability 2>/dev/null || true)"
  if [ "$(long_addr "${recorded:-0x0}")" != "$(long_addr "$UPGRADE_CAP_ID")" ]; then
    log "Not the current publication's UpgradeCap — deployments.json left unchanged."
    return 0
  fi
  jq --arg n "$NETWORK" --arg d "$(date -u +%Y-%m-%d)" \
    '.[$n].custody.upgradeCapOwner = null | .[$n].custody.burnedAt = $d | .[$n].custody.plannedBurnDate = null' \
    "$deployments" > "$deployments.tmp" && mv "$deployments.tmp" "$deployments"
  log "Recorded the burn in $deployments — commit it."
}

long_addr() { local h="${1#0x}"; printf '0x%064s' "${h,,}" | tr ' ' 0; }

# Hard failures before anything is signed: the active env must be NETWORK, testnet/mainnet must report
# their chain identifier, the CLI major.minor must match Published.toml `toolchain-version`, and
# mainnet needs MAINNET_CONFIRM=1.
preflight() {
  local env chain want tool cli
  env="$(sui client active-env 2>/dev/null || true)"
  [ "$env" = "$NETWORK" ] || { log "ERROR: active Sui env is '${env:-<none>}', expected '$NETWORK' (sui client switch --env $NETWORK)."; exit 1; }
  case "$NETWORK" in testnet) want=4c78adac ;; mainnet) want=35834a8a ;; *) want="" ;; esac
  if [ -n "$want" ]; then
    chain="$(sui client chain-identifier 2>/dev/null | awk '/^Hex:/{print $2; exit} !/:/{print $1; exit}')"
    [ "$chain" = "$want" ] || { log "ERROR: chain identifier is '${chain:-<unreachable>}', expected $want for $NETWORK."; exit 1; }
  fi
  tool="$(published_field toolchain-version || true)"
  cli="$(sui --version | awk '{print $2}' | cut -d- -f1)"
  if [ -n "$tool" ] && [ "${cli%.*}" != "${tool%.*}" ]; then
    log "ERROR: sui CLI $cli does not match Published.toml toolchain-version $tool (major.minor)."; exit 1
  fi
  if [ "$NETWORK" = "mainnet" ] && [ "${MAINNET_CONFIRM:-}" != "1" ]; then
    log "SKIPPED: mainnet — re-run with MAINNET_CONFIRM=1 to proceed."; exit 78
  fi
}

# IDs: explicit env vars, then Published.toml, then the .env.<network> record written by publish.sh
# (the only record on localnet, which has no Published.toml section).
ENV_FILE="$REPO_ROOT/.env.${NETWORK}"
if [ -f "$ENV_FILE" ]; then
  REC_CAP="$(sed -n 's/^ACCESS_GATE_UPGRADE_CAP_ID=//p' "$ENV_FILE")"
  REC_PKG="$(sed -n 's/^ACCESS_GATE_PACKAGE_ID=//p' "$ENV_FILE")"
fi
UPGRADE_CAP_ID="${UPGRADE_CAP_ID:-$(published_field upgrade-capability 2>/dev/null || true)}"
UPGRADE_CAP_ID="${UPGRADE_CAP_ID:-${REC_CAP:-}}"
PACKAGE_ID="${PACKAGE_ID:-$(published_field published-at 2>/dev/null || true)}"
PACKAGE_ID="${PACKAGE_ID:-${REC_PKG:-}}"
[ -n "$UPGRADE_CAP_ID" ] || { log "ERROR: no UpgradeCap for '$NETWORK' (set UPGRADE_CAP_ID, or publish first)."; exit 1; }
[ -n "$PACKAGE_ID" ] || { log "ERROR: cannot determine this package's id (set PACKAGE_ID, or publish first)."; exit 1; }

preflight

# The cap must be an UpgradeCap for THIS package (the deploy key may hold other packages' caps).
json="$(sui client object "$UPGRADE_CAP_ID" --json 2>/dev/null)" || { log "ERROR: UpgradeCap $UPGRADE_CAP_ID not found on $NETWORK (already burned?)."; exit 1; }
typ="$(jq -r '.objType // empty' <<<"$json")"
owner="$(jq -r '.owner.AddressOwner // empty' <<<"$json")"
cap_pkg="$(jq -r '.content.package // empty' <<<"$json")"
[ "$typ" = "$UPGRADE_CAP_TYPE" ] || { log "ERROR: $UPGRADE_CAP_ID is a '$typ', not an UpgradeCap."; exit 1; }
[ "$(long_addr "$cap_pkg")" = "$(long_addr "$PACKAGE_ID")" ] \
  || { log "ERROR: UpgradeCap $UPGRADE_CAP_ID controls package $cap_pkg, not $PACKAGE_LABEL $PACKAGE_ID."; exit 1; }
[ -n "$owner" ] || { log "ERROR: UpgradeCap $UPGRADE_CAP_ID is not owned by an address."; exit 1; }
active="$(sui client active-address)"
if [ "$(long_addr "$owner")" = "$(long_addr "$active")" ]; then mode="direct"; else mode="multisig"; fi

log "Network      : $NETWORK"
log "Package      : $PACKAGE_LABEL $PACKAGE_ID"
log "UpgradeCap   : $UPGRADE_CAP_ID (owner $owner)"
log "Mode         : $mode $( [ "$mode" = multisig ] && echo '(the owner is not the active address; it must sign)')"
log "Dry run      : $DRY_RUN"
log ""
log "WARNING: make_immutable is PERMANENTLY IRREVERSIBLE. $PACKAGE_LABEL can never be upgraded again;"
log "         future changes ship as a NEW package with a new original id."
log ""

if [ "$mode" = "direct" ]; then
  if [ "$DRY_RUN" != "0" ]; then
    log "Dry run — would execute: sui client call --package 0x2 --module package --function make_immutable --args $UPGRADE_CAP_ID"
    log "Re-run with DRY_RUN=0 to execute."
    exit 0
  fi
  read -r -p "Type YES to permanently burn the UpgradeCap: " CONFIRM
  [ "$CONFIRM" = "YES" ] || { log "Aborted."; exit 1; }
  sui client call --json --gas-budget "$GAS_BUDGET" \
    --package 0x2 --module package --function make_immutable --args "$UPGRADE_CAP_ID" >/dev/null
else
  # Multisig: build the unsigned transaction with the cap's owner as sender (that address pays gas).
  if [ "$DRY_RUN" != "0" ]; then
    log "Dry run — with DRY_RUN=0 this writes the unsigned make_immutable transaction (sender $owner)"
    log "to $OUT_DIR and prints the signing steps. The multisig address must hold SUI for gas."
    exit 0
  fi
  mkdir -p "$OUT_DIR"
  tx_file="$OUT_DIR/make-immutable-$NETWORK-$(date -u +%Y%m%dT%H%M%SZ).txbytes"
  sui client ptb \
    --move-call 0x2::package::make_immutable "@$UPGRADE_CAP_ID" \
    --sender "@$owner" --gas-budget "$GAS_BUDGET" --serialize-unsigned-transaction > "$tx_file"
  log "Unsigned transaction written to: $tx_file"
  log ""
  log "Next (each required signer, then once to combine and execute):"
  log "  1. sui keytool sign --address <signer address> --data \"\$(cat $tx_file)\""
  log "     → copy suiSignature from each signer (in the --json output)."
  log "  2. sui keytool multi-sig-combine-partial-sig --pks <all pks> --weights <weights> \\"
  log "       --threshold <threshold> --sigs <suiSignature …>"
  log "     → copy multisigSerialized (the same --pks/--weights/--threshold used to create $owner)."
  log "  3. sui client execute-signed-tx --tx-bytes \"\$(cat $tx_file)\" --signatures <multisigSerialized>"
  log "  4. Record the burn: set custody.upgradeCapOwner to null and custody.burnedAt to the date in"
  log "     deployments.json [$NETWORK], and commit it. (Published.toml is Sui's file; leave it as is.)"
  exit 0
fi

# The UpgradeCap being consumed is the only proof of immutability (a package object is always
# "Immutable"-owned).
if sui client object "$UPGRADE_CAP_ID" --json >/dev/null 2>&1; then
  log "ERROR: UpgradeCap $UPGRADE_CAP_ID still exists after make_immutable."
  exit 1
fi
log "Package is now permanently immutable (UpgradeCap consumed)."
record_burn
