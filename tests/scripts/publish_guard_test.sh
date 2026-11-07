#!/usr/bin/env bash
# Offline tests for the preflight of scripts/publish.sh (mainnet --create-gate guards). A stub `sui` on PATH answers the preflight
# calls from canned values, so no network or chain is needed; the script stops at the gas check, which the stub reports as empty.
# Run: bash tests/scripts/publish_guard_test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$HERE/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK:?}"' EXIT
command -v jq >/dev/null || { echo "jq is required"; exit 1; }

FAILS=0
ok()   { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; FAILS=$((FAILS + 1)); }
expect() { # expect <name> <expected-exit> <output-substring> -- cmd...
  local name="$1" want="$2" needle="$3" out rc; shift 4
  out="$("$@" 2>&1)"; rc=$?
  if [ "$rc" = "$want" ] && [[ "$out" == *"$needle"* ]]; then ok "$name"; else fail "$name (exit $rc, wanted $want, needle '$needle'): $out"; fi
}

SIGNER=0x$(printf 'a%.0s' {1..64})
MS=0x$(printf 'b%.0s' {1..64})
D="$WORK/repo"
mkdir -p "$D/scripts" "$D/bin"
cp "$SRC/scripts/publish.sh" "$D/scripts/"
cat > "$D/Published.toml" <<'TOML'
[published.testnet]
published-at = "0x1"
original-id = "0x1"
version = 1
toolchain-version = "1.82.2"
TOML
cat > "$D/bin/sui" <<STUB
#!/usr/bin/env bash
case "\$*" in
  "client active-env") echo mainnet ;;
  "client chain-identifier") echo "Hex: 35834a8a" ;;
  "--version") echo "sui 1.82.2-stub" ;;
  "client active-address") echo $SIGNER ;;
  "client gas --json") echo '{"gasCoins":[],"addressMistBalance":0}' ;;
  *) echo "stub sui: unexpected \$*" >&2; exit 99 ;;
esac
STUB
chmod +x "$D/bin/sui"
run() { env -i PATH="$D/bin:$PATH" HOME="$WORK" MAINNET_CONFIRM=1 EXPECTED_SIGNER="$SIGNER" "$@" bash "$D/scripts/publish.sh" mainnet --create-gate; }

expect "mainnet --create-gate without a recipient is refused" 1 "requires GATE_PAYMENT_RECIPIENT" -- run GATE_PAUSE_BLOCKS_ACCESS=true
expect "the deploy key is refused as the recipient" 1 "is the deploy key" -- run GATE_PAYMENT_RECIPIENT="$SIGNER" GATE_PAUSE_BLOCKS_ACCESS=true
expect "0x0 is refused as the recipient" 1 "must not be 0x0" -- run GATE_PAYMENT_RECIPIENT=0x0 GATE_PAUSE_BLOCKS_ACCESS=true
expect "a malformed recipient is refused" 1 "0x-prefixed address" -- run GATE_PAYMENT_RECIPIENT=banana GATE_PAUSE_BLOCKS_ACCESS=true
expect "an unset pause flag is refused" 1 "GATE_PAUSE_BLOCKS_ACCESS=true|false explicitly" -- run GATE_PAYMENT_RECIPIENT="$MS"
expect "a non-boolean pause flag is refused" 1 "GATE_PAUSE_BLOCKS_ACCESS=true|false explicitly" -- run GATE_PAYMENT_RECIPIENT="$MS" GATE_PAUSE_BLOCKS_ACCESS=yes
expect "explicit values pass the guard and reach the gas check" 1 "less than GAS_BUDGET" -- run GATE_PAYMENT_RECIPIENT="$MS" GATE_PAUSE_BLOCKS_ACCESS=true
expect "mainnet without MAINNET_CONFIRM is skipped" 78 "re-run with MAINNET_CONFIRM=1" -- env -i PATH="$D/bin:$PATH" HOME="$WORK" EXPECTED_SIGNER="$SIGNER" bash "$D/scripts/publish.sh" mainnet --create-gate
expect "mainnet without EXPECTED_SIGNER is refused" 1 "requires EXPECTED_SIGNER" -- env -i PATH="$D/bin:$PATH" HOME="$WORK" MAINNET_CONFIRM=1 bash "$D/scripts/publish.sh" mainnet --create-gate
# Without --create-gate the gate variables are irrelevant: the run reaches the gas check.
expect "no --create-gate: the gate guard does not apply" 1 "less than GAS_BUDGET" -- env -i PATH="$D/bin:$PATH" HOME="$WORK" MAINNET_CONFIRM=1 EXPECTED_SIGNER="$SIGNER" bash "$D/scripts/publish.sh" mainnet

if [ "$FAILS" = 0 ]; then echo "all publish guard tests passed"; else echo "$FAILS failed"; exit 1; fi
