#!/usr/bin/env bash
# Offline tests for scripts/make-immutable.sh (dry run only). A stub `sui` on PATH answers from canned JSON, so no
# network or chain is needed; the real-chain rehearsal is in CUSTODY.md ("Rehearsal").
# Run: bash tests/scripts/make_immutable_test.sh
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

MS=0x$(printf 'a%.0s' {1..64})
V1=0x$(printf '1%.0s' {1..64}); V2=0x$(printf '2%.0s' {1..64}); OTHER=0x$(printf '3%.0s' {1..64})
CAP=0x$(printf 'e%.0s' {1..64})

# A checkout in a scratch dir whose Published.toml records V1 (as after a multisig-signed upgrade: the CLI only
# serialised it, so the record was not updated).
D="$WORK/repo"
mkdir -p "$D/scripts" "$D/bin"
cp "$SRC/scripts/make-immutable.sh" "$D/scripts/"
echo '{}' > "$D/deployments.json"
cat > "$D/Published.toml" <<TOML
[published.localnet]
published-at = "$V1"
original-id = "$V1"
version = 1
upgrade-capability = "$CAP"
TOML

# STUB_CAP_PACKAGE: the package the UpgradeCap names; STUB_ORIGIN: where that package's ACCESS_GATE type originates.
cat > "$D/bin/sui" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "--version") echo "sui 1.81.0-stub" ;;
  "client active-env") echo localnet ;;
  "client active-address") echo 0x1 ;;
  "client object "*)
    id="$3"
    if [ "$id" = "$STUB_CAP" ]; then
      echo "{\"objType\":\"0x0000000000000000000000000000000000000000000000000000000000000002::package::UpgradeCap\",\"owner\":{\"AddressOwner\":\"$STUB_MS\"},\"content\":{\"package\":\"$STUB_CAP_PACKAGE\"}}"
    elif [ "$id" = "$STUB_CAP_PACKAGE" ] && [ -n "${STUB_ORIGIN:-}" ]; then
      echo "{\"content\":{\"Package\":{\"type_origin_table\":[{\"module_name\":\"access_gate\",\"datatype_name\":\"ACCESS_GATE\",\"package\":\"$STUB_ORIGIN\"}]}}}"
    else
      echo "{\"content\":{\"Package\":{\"type_origin_table\":[]}}}"
    fi ;;
  *) echo "stub sui: unexpected: $*" >&2; exit 99 ;;
esac
STUB
chmod +x "$D/bin/sui"

run() { # run [script args]; the cap, its package and its origin come from the STUB_* variables
  env PATH="$D/bin:$PATH" NETWORK=localnet DRY_RUN=1 STUB_CAP="$CAP" STUB_MS="$MS" \
    STUB_CAP_PACKAGE="$STUB_CAP_PACKAGE" STUB_ORIGIN="${STUB_ORIGIN-}" \
    bash "$D/scripts/make-immutable.sh" "$@"
}

STUB_CAP_PACKAGE="$V1" STUB_ORIGIN="$V1" expect "the cap names the recorded package" 0 "Mode         : multisig" -- run
STUB_CAP_PACKAGE="$V2" STUB_ORIGIN="$V1" expect "the cap names a later version of the recorded package (multisig upgrade, record not updated)" 0 "a later version of access_gate $V1" -- run
STUB_CAP_PACKAGE="$V2" STUB_ORIGIN="$V1" expect "...and the dry run goes on to the multisig plan" 0 "Dry run — with DRY_RUN=0 this writes the unsigned make_immutable transaction" -- run
STUB_CAP_PACKAGE="$OTHER" STUB_ORIGIN="$OTHER" expect "the cap names an unrelated package" 1 "which is not access_gate $V1 or a later version of it" -- run
STUB_CAP_PACKAGE="$OTHER" STUB_ORIGIN="" expect "the cap's package has no ACCESS_GATE origin (another package family)" 1 "which is not access_gate $V1 or a later version of it" -- run

if [ "$FAILS" -ne 0 ]; then printf '\n%s test(s) failed.\n' "$FAILS"; exit 1; fi
printf '\nall make-immutable.sh tests passed.\n'
