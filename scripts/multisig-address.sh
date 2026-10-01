#!/usr/bin/env bash
# Derive a Sui multisig address from its members' public keys, weights and threshold.
#
# The multisig is the custody address for this package's UpgradeCap and admin capabilities
# (CUSTODY.md). With one maintainer today, a 1-of-1 multisig of that maintainer's key works; add
# signers later by creating a new multisig and transferring the capabilities to it.
#
# Usage:
#   MULTISIG_PKS="<base64 pk1> <base64 pk2>" MULTISIG_WEIGHTS="1 1" MULTISIG_THRESHOLD=1 \
#     bash scripts/multisig-address.sh
#
# A public key comes from `sui keytool list` (field publicBase64Key, which already starts with the
# scheme flag). Record the exact pks, weights and threshold next to the address: every later
# signature combination needs them.

set -euo pipefail

: "${MULTISIG_PKS:?set MULTISIG_PKS to the space-separated base64 public keys (with flag)}"
: "${MULTISIG_WEIGHTS:?set MULTISIG_WEIGHTS to one weight per key, space-separated}"
: "${MULTISIG_THRESHOLD:?set MULTISIG_THRESHOLD to the total weight needed to sign}"

read -r -a pks <<<"$MULTISIG_PKS"
read -r -a weights <<<"$MULTISIG_WEIGHTS"
[ "${#pks[@]}" -eq "${#weights[@]}" ] || { echo "ERROR: ${#pks[@]} keys but ${#weights[@]} weights." >&2; exit 1; }

total=0
for w in "${weights[@]}"; do total=$((total + w)); done
if [ "$MULTISIG_THRESHOLD" -lt 1 ] || [ "$MULTISIG_THRESHOLD" -gt "$total" ]; then
  echo "ERROR: threshold $MULTISIG_THRESHOLD must be between 1 and the total weight $total." >&2; exit 1
fi

sui keytool multi-sig-address --pks "${pks[@]}" --weights "${weights[@]}" --threshold "$MULTISIG_THRESHOLD"
