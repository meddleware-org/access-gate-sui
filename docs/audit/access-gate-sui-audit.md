# Security Audit — `access-gate-sui`

**Classification:** Internal security review (initial audit — awaiting external review)
**Project:** `repos/access-gate-sui` — permissionless NFT access-gate primitive (Sui Move)
**Project type:** Move package
**Template:** AUDIT_TEMPLATE.md (2026-09-28) + AUDIT_TEMPLATE_SUI.md (2026-09-28)
**Package:** `access_gate` v0.0.2; edition 2024; framework rev `b0535f1f3a33` (Move.lock, testnet)
**Deployment status:** testnet — canonical package `0x0bedd0b27d993d3292ca6a5315f7562de8bc0ff3752b445b4c53252c76f2d20d` (UpgradeCap `0x1ab9a455…4e89` **live**, compatible policy, publisher EOA); a second testnet package `0x692547ae…68bc` exists and is recorded as `published-at` in `Move.toml` but is used by no consumer (F14); mainnet: unpublished
**Review date:** 2026-09-18 (first pass) · re-verified and relocated 2026-09-28
**Reviewer:** Internal review (Move contract reviewer)
**Severity ceiling:** High — the package handles on-chain SUI payments and a platform commission split; a capability or accounting flaw could misroute funds. Realized ceiling: **Medium** (F1, F10, F12 — all RESOLVED in source/tooling).
**Status:** re-verified 2026-09-28

Relocated from the workspace corpus (`docs/audit/access-gate-sui-audit.md`, now a pointer stub). All
`F#` / `OQ#` identifiers from the first pass are preserved.

---

## Executive summary

`access-gate-sui` is a small, dependency-free primitive (Sui framework only). Capability↔gate binding
is asserted on every privileged path; single-use spend takes the NFT by value (owner-only);
soulbound non-transferability is structural (`key` without `store`); abort codes are unique within
the module; emit-before-delete holds everywhere. **36/36** tests pass (sui 1.80.0), and every abort
code has an `expected_failure` test on both the transferable and soulbound paths.

This pass fixed, inline:

- **F10 (Medium)** — the commission product `price_mist * commission_bps` was computed in u64 and
  aborted for prices above ~1.8×10¹⁶ MIST at 10%, which would brick `purchase` for such a gate (and
  a later commission increase could brick an already-frozen gate). Now widened to u128
  (`commission_for`), proven at `u64::MAX`.
- **F12 (Medium)** — `scripts/transfer-platform-authority.sh`, the tooling for the blocking
  pre-mainnet custody handoff, could not work with Sui CLI 1.80 and, where it did match, discovered
  objects by unscoped patterns (it could move *another package's* `UpgradeCap`). Rewritten to use
  exact IDs recorded at publish and to verify type, package and owner on-chain before transferring;
  verified end-to-end on localnet, including a tampered-ID refusal.
- **F11, F13, F16, F17** — zero-address treasury rejected; `publish.sh` defects; a `SECURITY.md`
  claim that the UpgradeCap is burned (it is not); README/API doc drift.

What remains is governance and operational: the live testnet `UpgradeCap` and single-EOA custody of
platform authority (F2/F3, pre-mainnet blocking), which package address is canonical (F14, OQ7),
and product decisions on frozen/paused gates, commission on frozen gates, dust pricing, auto-burn
semantics and licensing (OQ4–OQ11). **The deployed testnet package predates the F10/F11 fixes;
a republish is required for them to take effect on-chain.**

---

## Threat model / trust boundaries

| Authority / actor | Holds / proves | Can do | Bounded by |
| --- | --- | --- | --- |
| Anyone (permissionless) | nothing | `create_gate`; `purchase` (pay ≥ price); `consume*` / `burn*` on **own** NFT; all views | Sui ownership (by-value NFT); `E_PAUSED`, `E_INSUFFICIENT_PAYMENT`, `E_WRONG_GATE`, `E_NOT_SINGLE_USE`, `E_NO_USES_REMAINING`, `E_INVALID_NONCE` |
| Gate creator / `AdminCap` holder | `AdminCap { gate_id }` | `airdrop`; gate setters; `make_gate_immutable` | `cap.gate_id == id(gate)` (`E_WRONG_GATE`) and `!frozen` (`E_GATE_FROZEN`) |
| Platform operator / `PlatformAdminCap` holder | `PlatformAdminCap` | `set_platform_treasury` (≠ `@0x0`); `set_commission_bps` (≤ 1000) — for **every** gate of this package, frozen or not | `E_COMMISSION_TOO_HIGH`, `E_ZERO_ADDRESS`; no per-gate authority |
| Package publisher | `UpgradeCap`, `Publisher`, both `Display` | upgrade bytecode; edit NFT Display templates | nothing on-chain today — single EOA (F2/F3) |
| Off-chain verifier / gateway | reads events + owned objects | grant/deny access by matching `AccessConsumedEvent` | its own nonce issuance, uniqueness and freshness (F1, B.5) |

**Primary trust anchor:** the per-gate `AdminCap` binding and Sui object ownership. The consume
`nonce` is not a trust anchor on its own — replay protection is a verifier obligation (F1).

### Capabilities & shared objects (Move lens)

| Object / type | Minted / created by | Holder / custodian | Authority it confers | Compromise / misuse impact | Immutability / rotation plan |
| --- | --- | --- | --- | --- | --- |
| `UpgradeCap` (`0x1ab9…4e89`, testnet) | publish | publisher EOA `0xa991…864a` | replace package code | arbitrary logic change for every gate, pass and payment | burn (`publish.sh --make-immutable`) or multisig (`transfer-platform-authority.sh --include-upgrade-cap`) — pre-mainnet blocking (F3) |
| `PlatformAdminCap` | `init` | publisher EOA | treasury + commission (≤ 10%) for all gates | redirect all commission; raise commission to 10% | multisig via `transfer-platform-authority.sh` — pre-mainnet blocking (F2) |
| `Publisher` + `Display<AccessNFT>` + `Display<SoulboundAccessNFT>` | `init` (OTW) | publisher EOA | wallet-visible name/image/description templates for every NFT of both types | metadata spoofing / phishing images across all gates | multisig (same script) — pre-mainnet blocking (F2) |
| `PlatformConfig` (shared) | `init` | shared; `treasury = publisher` | read by every `purchase` | — (mutable only via `PlatformAdminCap`) | per-package-version object |
| `AdminCap` (per gate) | `create_gate` | gate creator | one gate's config + airdrop + freeze | that gate's price/payout/pause changed | renounced by `make_gate_immutable` |
| `Gate` (shared) | `create_gate` | shared | — | — | frozen by `make_gate_immutable` |
| External shared objects | — | — | none used (`Clock`/`Random` not used; timestamps are `ctx.epoch_timestamp_ms()`) | — | n/a |

## Severity scale

Critical / High / Medium / Low / Info / Positive.

## Scope

- **In scope:** `sources/access_gate.move`, `tests/access_gate_tests.move`, `Move.toml`, `Move.lock`,
  `scripts/publish.sh`, `scripts/transfer-platform-authority.sh`, `SECURITY.md`, `README.md`,
  `CLAUDE.md`, `docs/onchain/*`; on-chain state of the testnet packages and caps (read via gRPC).
- **Out of scope:** the Sui framework; verifier implementations (`nft-gate` gateways — own audit);
  downstream apps.
- **Environment:** Sui CLI 1.80.0 (`sui move test --build-env testnet` → 36/36); throwaway localnet
  (`sui start --with-faucet --force-regenesis`) for `publish.sh` and
  `transfer-platform-authority.sh` end-to-end runs; testnet gRPC reads of `0x0bedd0…`, `0x692547…`,
  `0x1ab9…`, the live gate `0x0485…`.

---

## Findings

### F1 — Consume `nonce` unvalidated and unbound on-chain; replay safety is a verifier obligation
**Severity:** Medium   **Disposition:** RESOLVED (first pass)
**Where:** `access_gate.move::consume_data`
**Issue:** the nonce was caller-supplied, unchecked and not bound to the sender.
**Impact:** integrators could build a replayable gateway believing the chain enforced one-time use.
**Remediation / evidence:** `MIN_NONCE_LENGTH = 8` / `E_INVALID_NONCE = 8` asserted first in
`consume_data`; `consumer: address` (tx sender) emitted in `AccessConsumedEvent`; normative verifier
tuple documented in `SECURITY.md` and `docs/onchain/dev-guide.md`. Nonce **uniqueness/freshness**
remains off-chain by design (B.5). Tests: `test_consume_short_nonce_aborts`,
`test_consume_soulbound_short_nonce_aborts`.

### F2 — Platform authority + NFT Display custodied by one publisher EOA
**Severity:** Low   **Disposition:** DEFERRED (tooling RESOLVED in F12; the transfer itself is a pre-mainnet blocking gate)
**Where:** `init` sends `PlatformAdminCap`, `Publisher`, both `Display` to the sender.
**Impact:** key compromise → redirect all commission; rewrite every NFT's wallet display.
**Remediation:** `DRY_RUN=0 NETWORK=<net> MULTISIG_ADDRESS=0x… bash scripts/transfer-platform-authority.sh`
before mainnet (see Section D).

### F3 — Upgrade authority: intended immutable, testnet cap still live
**Severity:** Low   **Disposition:** DEFERRED (policy ADJUDICATED; execution pending — OQ1)
**Where:** publish; testnet `UpgradeCap 0x1ab9…4e89` verified on-chain 2026-09-28: owned by the
publisher EOA, `policy = 0` (compatible).
**Issue / impact:** until burned or moved to a multisig, one key can replace the package's logic
under every live gate and pass.
**Remediation:** burn with `publish.sh --make-immutable` (new publishes) or
`sui client call --package 0x2 --module package --function make_immutable --args <cap>` (existing),
or transfer with `transfer-platform-authority.sh --include-upgrade-cap`. Versioning caveats for
integrators (per-version `PlatformConfig`, multi-address event monitoring, NFTs bound to the version
that minted them, voluntary migration) are in `SECURITY.md`.

### F4 — `commission_bps` still applies to a frozen gate
**Severity:** Low/Info   **Disposition:** ADJUDICATED (intended platform/gate split; OQ4)
Bounded by the 10% cap; documented in `SECURITY.md` and the user guide.

### F5 — `airdrop` blocked by freeze while `purchase` continues
**Severity:** Info   **Disposition:** ADJUDICATED — intentional; `test_airdrop_on_frozen_gate_aborts` added.

### F6 — Abort-code uniqueness (module) and arithmetic
**Severity:** Positive — codes 1–9 distinct within `access_gate`; after F10 no reachable arithmetic
can overflow; `operator_share` cannot underflow. Codes repeat across packages (`seal_policies`
uses 1–3) — clients key on `(module, code)`.

### F7 — Emit-before-delete ordering
**Severity:** Positive — `consume*`, `burn*`, `make_gate_immutable` capture the ID, emit, then delete.

### F8 — Soulbound non-transferability structurally enforced
**Severity:** Positive — `SoulboundAccessNFT has key` (no `store`).

### F9 — Capability provenance
**Severity:** Positive — `AdminCap` minted only in `create_gate`; test constructors are `#[test_only]`.

### F10 — Commission product overflowed u64 at extreme prices
**Severity:** Medium   **Disposition:** RESOLVED (source; on-chain after republish)
**Where:** `purchase` computed `gate.price_mist * platform.commission_bps / 10000` in u64.
**Issue:** the product aborts (Move arithmetic abort) when `price_mist > u64::MAX / commission_bps`
(≈ 1.84×10¹⁶ MIST at 10%, ≈ 9.2×10¹⁷ at 0.2%).
**Impact:** such a gate can never sell; because `commission_bps` is platform-wide and not frozen with
a gate, raising it could newly brick a frozen gate permanently.
**Remediation / evidence:** commit `bfb48cd` — `commission_for(price, bps)` multiplies in u128 and
floors; `MAX_COMMISSION_BPS` / `BPS_DENOMINATOR` constants.
`test_purchase_max_price_max_commission_does_not_overflow` (u64::MAX at 1000 bps) and
`test_commission_dust_rounds_to_zero`. The deployed `0x0bedd0…` still has the u64 form (Section D).

### F11 — Platform treasury could be set to the zero address
**Severity:** Low   **Disposition:** RESOLVED (source; on-chain after republish)
**Where:** `set_platform_treasury`.
**Impact:** every paid purchase's commission sent to `@0x0` (unrecoverable) after one mistaken call.
**Remediation / evidence:** commit `bfb48cd` — `E_ZERO_ADDRESS = 9`;
`test_set_platform_treasury_zero_address_aborts`, `test_set_platform_treasury_updates`. (The same
check for a gate's `payment_recipient` is a product choice — OQ12.)

### F12 — Custody-transfer tooling non-functional and unsafe
**Severity:** Medium   **Disposition:** RESOLVED
**Where:** `scripts/transfer-platform-authority.sh` (first-pass F2 tooling).
**Issue:** (a) parsed `.data.type` / `.data.objectId` from `sui client objects --json`, which Sui CLI
1.80 no longer emits — nothing was ever found; (b) "not found" warnings were printed to stdout inside
`$(…)` and became the "object ID"; (c) `Publisher` / `UpgradeCap` discovery was not scoped to this
package (`head -n1` of *any* owned cap); (d) `Display<.*AccessNFT>` also matched
`SoulboundAccessNFT`; (e) required `PACKAGE_ID` while `publish.sh` writes `ACCESS_GATE_PACKAGE_ID`;
(f) no confirmation before executing.
**Impact:** the blocking pre-mainnet custody handoff could not run, or could transfer the wrong
package's `UpgradeCap`.
**Remediation / evidence:** commit `bfb48cd` — `publish.sh` records every authority object ID by
exact type from `objectChanges`; the transfer script uses those IDs only, verifies each object's
exact long-form type, package (`Publisher` / `UpgradeCap`) and ownership on-chain before any transfer,
rejects unknown flags, checks the active env, and requires `YES`. Verified on localnet: dry run,
tampered-ID refusal (`Display` presented as `Publisher` → abort before sending), real transfer
(ownership confirmed on-chain).

### F13 — `publish.sh` defects
**Severity:** Low   **Disposition:** RESOLVED
**Issue:** `log` used by the ERR trap and argument check before being defined; unknown flags
silently ignored (a typo such as `--make-imutable` would publish without burning); network not
validated; localnet `UpgradeCap` picked by position among five sender-owned objects.
**Remediation / evidence:** commit `bfb48cd`; exercised on localnet (`--create-gate`) and with bad
arguments.

### F14 — Package address drift
**Severity:** Low   **Disposition:** DEFERRED (OQ7)
**Issue:** `Move.toml published-at = 0x692547ae…` (a second, unused testnet deployment) while
`SECURITY.md`, every consumer (`walrus-relay`, `access-gate-ui`, `treasury-ui`, `dao-ui`, `seal-ui`,
`nft-gate-client` tests), the docs sites and the live gate type use `0x0bedd0…`. A Move package
depending on this repo at a revision whose manifest carries `published-at 0x692547…` links against
the unused package and cannot read live `Gate` objects. Local `Pub.testnet.toml` / `.env.localnet`
add two more addresses.
**Remediation:** decide the canonical address (OQ7) and make `Move.toml` agree with it; downstream
Move packages pin a commit SHA whose manifest resolves to it (seal-policies does — `f191c2d`).

### F15 — Mutable release tags
**Severity:** Low   **Disposition:** MITIGATED (dependants now pin commit SHAs) — OQ8
**Issue:** `v0.0.1` on the remote now points to `e6d63c6`, while the dependant lockfile resolved it
to `f191c2d`; local tags `v0.0.2` / `v0.0.3` are older than `v0.0.1` and absent from the remote.
**Remediation:** dependency docs now require SHA pins (README); tag hygiene is OQ8.

### F16 — `SECURITY.md` claimed the UpgradeCap is burned on publish
**Severity:** Low   **Disposition:** RESOLVED (statement corrected; underlying custody → F3)
**Evidence:** commit `bfb48cd` — states the live testnet cap and the pre-mainnet gate; also
corrected the stale "nonce unvalidated" text (F1).

### F17 — Documentation drift
**Severity:** Info   **Disposition:** RESOLVED
**Issue:** README listed a non-existent `mint_to`, outdated signatures (`create_gate`, `purchase`),
16 tests, a moved tag and an out-of-repo link; source doc comments mentioned `mint_to` and
misdescribed `set_auto_burn_at_zero`; docs./dev. sites listed only abort codes 1–5 and a
non-existent `buy`.
**Evidence:** commit `bfb48cd` (README, CLAUDE.md, source comments); canonical
`docs/onchain/*` now imported by both sites — docs `e311020` (Move tables replaced by links to the
canonical pages), dev `19499e0` (`buy` → `purchase` with the correct argument order).

### F18 — `auto_burn_at_zero` is read at consume time
**Severity:** Low   **Disposition:** ADJUDICATED (behaviour documented + tested; OQ9)
Changing the flag affects already-minted passes (`test_auto_burn_change_applies_to_existing_nfts`).

### F19 — Freezing a paused gate disables purchase forever
**Severity:** Low   **Disposition:** ADJUDICATED (documented + tested; OQ5)
`test_frozen_while_paused_gate_cannot_be_purchased`.

### F20 — Setters emit no events
**Severity:** Info   **Disposition:** ACCEPTED-RISK (suggestion S1) — configuration history is not
indexable; current state is readable from the objects.

### F21 — Licence inconsistency
**Severity:** Info   **Disposition:** DEFERRED (OQ10) — `LICENSE` and `Move.toml`: 0BSD; source
SPDX headers: CC0-1.0.

### F22 — `init` defaults verified
**Severity:** Positive — `test_init_creates_platform_objects`: `PlatformConfig {treasury: publisher,
commission_bps: 20}` shared; `PlatformAdminCap`, `Publisher` (from this module), both `Display` to the
publisher.

### F23 — docs./dev. sites import the canonical on-chain docs only after npm publication
**Severity:** Info   **Disposition:** DEFERRED (exact remediation below)
**Where:** `repos/docs` and `repos/dev` — `scripts/gen-onchain.mjs` resolves `@meddleware/access-gate-sui` from
`node_modules`.
**Issue:** the canonical `docs/onchain/*` pages ship in `@meddleware/access-gate-sui` from version `0.0.2`. Until
that version is on npm and installed in both sites, their builds render placeholder pages for this
package (by design — builds never fail). Verified locally with `ONCHAIN_DOCS_ROOT=..` (all pages
imported, no dead links, lint/type-check green).
**Remediation:** publish `@meddleware/access-gate-sui@0.0.2` (push the release tag; `npm-publish.yml`), then in both
`repos/docs` and `repos/dev`: `npm install -D @meddleware/access-gate-sui@0.0.2` → commit `package.json` +
`package-lock.json` → `npm run build` and confirm the `[gen:onchain]` log shows imported pages
(no placeholder) → release the site images.

---

## Section A — Invariant verification matrix

| # | Invariant | Enforced / asserted at | Proven by | Status |
| --- | --- | --- | --- | --- |
| I1 | Purchase atomic, permissionless, overpay refunded | `access_gate.move::purchase` | `test_purchase_*` (overpay/free/exact/underpay/paused) | HOLDS |
| I2 | **Ownership:** single-use spent only by the holder (by-value NFT); decrement + event | `::consume*`, `::consume_data` | `test_single_use_consume_*`, `test_soulbound_mint_and_consume` | HOLDS |
| I3 | Replay binding: nonce ≥ 8 bytes, `consumer` recorded; uniqueness/freshness off-chain | `::consume_data` | `test_consume_short_nonce_aborts`, `test_consume_soulbound_short_nonce_aborts` | HOLDS (on-chain part; see B.5) |
| I4 | **Gating / isolation:** NFT and cap bound to one gate | `::consume_data`, `::assert_admin` | `test_consume_wrong_gate_aborts`, `test_consume_soulbound_wrong_gate_aborts`, `test_setter_with_foreign_admin_cap_aborts` | HOLDS |
| I5 | Exhaustion policy per gate (`auto_burn_at_zero`, read at consume) | `::consume_data` | `test_single_use_auto_burn_*`, `test_auto_burn_change_applies_to_existing_nfts` | HOLDS |
| I6 | **Event ordering:** emit before delete | `::consume*`, `::burn*`, `::make_gate_immutable` | `test_burn_voluntary`, `test_burn_soulbound`, auto-burn tests | HOLDS |
| I7 | **Capability binding:** `AdminCap` non-forgeable, per-gate | `::create_gate`, `::assert_admin` | `test_setter_with_foreign_admin_cap_aborts`, `test_admin_setters` | HOLDS |
| I8 | Frozen gate: no setter/airdrop; purchase/consume continue | `::assert_admin_mutable`, `::make_gate_immutable` | `test_make_gate_immutable_*`, `test_setter_on_frozen_gate_aborts`, `test_airdrop_on_frozen_gate_aborts` | HOLDS |
| I9 | **Arithmetic:** commission ≤ 10%, no overflow/underflow, floor rounding, dust = 0 | `::commission_for`, `::purchase`, `::set_commission_bps` | `test_purchase_nonzero_commission_splits_payment`, `test_purchase_max_price_max_commission_does_not_overflow`, `test_commission_dust_rounds_to_zero`, `test_set_commission_*` | HOLDS (source; deployed `0x0bedd0…` predates F10) |
| I10 | **Abilities:** soulbound cannot be `public_transfer`'d | `SoulboundAccessNFT has key` | type system; `test_soulbound_mint_and_consume` | HOLDS |
| I11 | Package immutable ⇒ semantics fixed for existing gates | `UpgradeCap` burned | on-chain read: testnet cap live | GAP (F3) |
| I12 | **Funds routing:** payment = commission + operator share + refund; treasury ≠ `@0x0` | `::purchase`, `::set_platform_treasury` | `test_purchase_overpay_refunds_remainder`, split tests, `test_set_platform_treasury_zero_address_aborts` | HOLDS |
| I13 | **Abort codes:** unique within module; map published | constants `E_*` 1–9 | every code has an `expected_failure` test; map in `docs/onchain/api-reference.md` | HOLDS |
| I14 | Side-effect-freedom | — | no dry-run policy functions in this package | N/A |
| I15 | Identity / byte layout | — | no client-built bytes decoded (nonce is opaque) | N/A |

---

## Section B — Supply-chain, publish-authority & capability matrix

### B.1 Dependency, liveness & coupling

| Dependency | Exact object ID / rev | Fails open or closed if unavailable? | Paths it can block | Notes |
| --- | --- | --- | --- | --- |
| Sui framework / MoveStdlib | `b0535f1f3a33…` (Move.lock, testnet) | n/a | build only | only dependency |
| Sui network (fullnodes) | — | closed (no tx) | purchase, consume | chain liveness only |
| Off-chain verifier (e.g. nft-gate) | — | closed (no grant) | access to the gated resource | integrator-operated |

**Wire / format coupling**

| Format | Exact layout | On-chain | Off-chain | Conformance |
| --- | --- | --- | --- | --- |
| `AccessConsumedEvent` | `{nft_id, gate_id, nonce, consumer, uses_after, timestamp_ms}` | emitted by `consume_data` | `nft-gate` gateways (Workers + Rust), `@meddleware/nft-gate-client` | gateway conformance vectors (`nft-gate/conformance/vectors.json`) cover the proof token; event field set is asserted by the gateways' integration tests |
| Access-proof message | `nft-gate:access:<nonce>` | — (off-chain only) | `nft-gate-client`, gateways | as above |

### B.2 Publish authority, capabilities & secret custody

| Authority / capability | Where minted / held | Custody | Gates | Immutability / rotation plan |
| --- | --- | --- | --- | --- |
| npm publish (`@meddleware/access-gate-sui`) | CI (`npm-publish.yml`, OIDC) | GitHub OIDC → npm | docs/source package releases | n/a (no secrets) |
| `UpgradeCap` | publish | publisher EOA | package code | F3 / B.3 |
| `PlatformAdminCap`, `Publisher`, `Display ×2` | `init` | publisher EOA | commission, NFT display | F2 — multisig pre-mainnet |
| `AdminCap` (per gate) | `create_gate` | gate creator | gate config | `make_gate_immutable` |

### B.3 `UpgradeCap` custody & immutability policy

| Network | Package ID | `UpgradeCap` ID | Status | Intended policy | Tooling |
| --- | --- | --- | --- | --- | --- |
| testnet | `0x0bedd0…d20d` (canonical) | `0x1ab9…4e89` | **held** by publisher EOA (policy 0) | immutable (burn) | `make_immutable` call or `transfer-platform-authority.sh --include-upgrade-cap` (dry-run default, `YES` confirm) |
| testnet | `0x692547…68bc` (unused) | not recorded | unknown | — | resolve with F14 / OQ7 |
| mainnet | — | — | unpublished | immutable (burn at publish: `publish.sh --make-immutable`) | `publish.sh` (typed `YES` confirm) |

**Versioning to integrators:** each release is a new package ID; old gates and passes stay valid under
their version; verifiers subscribe to every trusted package ID (see `SECURITY.md`).

### B.4 Permissionless & griefing surfaces

| Function | Attacker controls | Confidentiality | Discoverability / UX | Gas / state growth | Mitigation |
| --- | --- | --- | --- | --- | --- |
| `create_gate` | all gate fields incl. NFT name/image/description | none | look-alike gates / phishing NFT metadata | one shared object per call, paid by the attacker | UIs list gates by known `AdminCap` owner / curated IDs; never trust `nft_name` |
| `purchase` | payment amount | none | — | NFT per call, paid by buyer | — |
| `consume*` / `burn*` | own NFTs; nonce bytes (≥ 8, unbounded) | none | spam `AccessConsumedEvent`s for own passes | events paid by caller | verifiers match exact nonce + gate + consumer (S2: nonce max length) |

### B.5 Replay protection & event semantics

- **On-chain:** nonce length ≥ 8; `consumer = tx sender`; no uniqueness or freshness.
- **Verifier MUST:** issue a random single-use nonce with expiry; accept only an `AccessConsumedEvent`
  from a finalised transaction whose `nonce`, `gate_id` (and `nft_id` of that gate) and `consumer`
  match the signed access proof; bind the grant to the consume tx digest; accept each digest and nonce
  once.

| Event | Emitted by | Verifier MUST check | Before/after structural change | Consumers |
| --- | --- | --- | --- | --- |
| `GateCreatedEvent` | `create_gate` | — | before share | indexers (dao/treasury use AdminCap discovery instead) |
| `AccessMintedEvent` | `purchase`, `airdrop` | — | before transfer | treasury-ui activity feed |
| `AccessConsumedEvent` | `consume*` | `nonce`, `gate_id`, `consumer` (+ tx digest) | after decrement, before delete | nft-gate gateways, treasury-ui |
| `AccessBurnedEvent` | auto-burn, `burn*` | — | before delete | indexers |
| `GateFrozenEvent` | `make_gate_immutable` | — | after `frozen = true`, before cap delete | UIs |

---

## Section C — Test-coverage & hermetic/live split

### C.1 Coverage grade — A (36/36, sui 1.80.0)

| Dimension | Assessment |
| --- | --- |
| Happy-path | A — init defaults, create, purchase (exact/overpay/free), commission split, single-use decrement + receipt, auto-burn, soulbound mint+consume, airdrop, burns, setters, freeze, platform setters |
| Error-path / abort codes | A — codes 1–9 each have `expected_failure` tests; 3/4/5/8 also on the soulbound path |
| Boundary / edge | A — `u64::MAX` price at 10%, dust rounding, 7-byte nonce, zero uses, exhausted vs unlimited, foreign cap, frozen-while-paused, auto-burn changed after mint |
| Security-relevant | A — cross-gate consume/approve (both variants), frozen guards, cap binding, short nonce, consumer field, zero treasury |

### C.2 Hermetic vs. live paths

| Path | Hermetic unit test? | Deferred to | Tracking |
| --- | --- | --- | --- |
| All accounting / consume / freeze logic | yes | — | `tests/access_gate_tests.move` |
| `publish.sh` object-ID extraction, `transfer-platform-authority.sh` | no | localnet | run 2026-09-28 (F12/F13) |
| Wallet `Display` rendering; wallets refusing soulbound transfer | no | testnet smoke | manual |
| Verifier replay discipline | no | gateway integration tests | `nft-gate` audit |

---

## Section D — Deployment-readiness gates

### pre-localnet

- [x] compiles; 36/36 hermetic tests green (sui 1.80.0) — CI `move-ci.yml`
- [x] every abort code tested; no unchecked u64 products; all caps bound (F6, F9, F10)
- [x] `SECURITY.md` present and consistent with this audit (F16)

### pre-testnet

- [ ] docs./dev. sites install the published `@meddleware/access-gate-sui` and import its on-chain docs — F23
- [x] published — canonical `0x0bedd0…` (predates F10/F11)
- [ ] package ID recorded consistently across `Move.toml` / `SECURITY.md` / consumers — F14 (OQ7)
- [x] dependants pin commit SHAs (seal-policies `f191c2d`) — F15
- [x] custody/immutability tooling with dry-run default + explicit confirmation — F12/F13
- [ ] republish with the F10/F11 fixes and migrate consumers — tracked with OQ7

### pre-mainnet

- [ ] `UpgradeCap` policy executed on mainnet (burn at publish) — **blocking** (F3)
- [ ] `PlatformAdminCap` / `Publisher` / `Display` moved to multisig — **blocking** (F2)
- [ ] testnet `UpgradeCap` burned or moved — non-blocking (F3, OQ1)
- [x] full Section A coverage except I11 (custody); abort-code map published (`docs/onchain/api-reference.md`)
- [ ] live-only paths (C.2) exercised on testnet
- [ ] external audit

---

## Cross-project themes

- **Supply chain & release integrity:** framework-only dependency, lockfile committed; npm package
  (docs/source) published via OIDC; git tags are mutable and have been moved (F15) — dependants pin
  SHAs.
- **Wire-format coupling:** `AccessConsumedEvent` fields and the `nft-gate:access:<nonce>` proof are
  shared with `nft-gate` / `nft-gate-client` (B.1).
- **On-chain-truth boundary:** payments, commission and pass validity are decided on-chain; UIs only
  preview prices.
- **Deployment readiness:** Section D.

---

## Normative requirements (MUST)

1. Commission arithmetic MUST NOT overflow for any `price_mist` — **holds in source** (F10); the
   deployed testnet package MUST be republished before mainnet parity is claimed.
2. Every privileged path MUST check `cap.gate_id == id(gate)` and `!frozen` — holds (I4, I7, I8).
3. Consume MUST take the NFT by value and require a ≥ 8-byte nonce; verifiers MUST enforce nonce
   uniqueness/freshness and bind `(nonce, gate_id, consumer, tx digest)` — on-chain part holds (I3).
4. Soulbound passes MUST remain non-transferable (`key` without `store`) — holds (I10).
5. The platform treasury MUST NOT be `@0x0` — holds in source (F11).
6. Before mainnet: the `UpgradeCap` MUST be burned or held by a multisig, and `PlatformAdminCap` /
   `Publisher` / `Display` MUST be held by a multisig — **not yet** (F2, F3).
7. The canonical package address MUST be the one recorded in `Move.toml`, `SECURITY.md` and every
   consumer — **not yet** (F14).
8. Downstream Move packages MUST pin this dependency to a commit SHA — holds for seal-policies.

## Implementation suggestions (SHOULD / MAY)

- **S1** SHOULD emit events from gate and platform setters (config history for indexers) — F20.
- **S2** MAY cap the nonce length (e.g. ≤ 256 bytes) to bound event size.
- **S3** SHOULD add a view returning `(price, commission, operator_share)` so UIs never recompute the
  split client-side.
- **S4** MAY add a testnet integration script that publishes, creates a gate, purchases, consumes and
  asserts events, run before each release.

## Open questions (`OQ#`)

1. **OQ1** When will the testnet `UpgradeCap` (`0x1ab9…4e89`) be burned or moved, and when will the
   versioning/migration policy be announced to integrators?
2. **OQ2** *(first pass — decided: multisig is the target custody)* Which multisig address (and
   M-of-N) will hold platform authority, and when will `transfer-platform-authority.sh` be run?
3. **OQ3** *(first pass — decided: on-chain min length + `consumer` field; uniqueness off-chain)*
   Should the minimum nonce length be raised from 8 to 16 bytes to match the recommended verifier
   nonce?
4. **OQ4** Is it acceptable that `set_commission_bps` changes the economics of frozen gates (≤ 10%)?
5. **OQ5** Should `make_gate_immutable` refuse to freeze a paused gate (or unpause it), rather than
   allow a permanently unsellable gate?
6. **OQ6** Is per-gate metadata (copied at mint) the source of truth, with the global `Display` a
   passthrough — and who may change the `Display` templates?
7. **OQ7** Which testnet package is canonical — `0x0bedd0…` (every consumer, live gates) or
   `0x692547…` (`Move.toml published-at`)? Should the F10/F11 fixes be republished as a new canonical
   package, and consumers migrated?
8. **OQ8** Tag hygiene: will release tags be made immutable (never moved) and reconciled with the
   remote (`v0.0.2` / `v0.0.3` exist only locally and predate `v0.0.1`)?
9. **OQ9** Should `auto_burn_at_zero` be snapshotted per NFT at mint instead of read from the gate at
   consume time?
10. **OQ10** Which licence applies — 0BSD (`LICENSE`, `Move.toml`) or CC0-1.0 (source headers)?
11. **OQ11** Dust pricing: at 0.2% any price below 500 MIST pays no commission. Enforce a minimum
    price, or accept?
12. **OQ12** Should `create_gate` / `set_payment_recipient` also reject `@0x0` (it would break
    free-gate creators who pass the zero address today)?

## Risks (residual)

- **Key custody:** until F2/F3 execute, one publisher key controls package code, commission routing
  and NFT display for every gate.
- **Verifier correctness:** replay protection depends on each gateway implementing B.5; a careless
  integrator can still build a replayable service.
- **Version fragmentation:** each immutable release is a new address with its own `PlatformConfig`;
  gates and passes never migrate automatically.
- **Mutable git tags** remain a supply-chain hazard for any dependant that pins a tag instead of a SHA.
- **Metadata phishing:** anyone can create gates with arbitrary names/images.

---

## Re-verification log

- 2026-09-18 — first-pass baseline (18 → 22 tests; F1–F9; OQ1–OQ6).
- 2026-09-28 — relocated to the package repo; re-verified under the updated template + Sui lens.
  Added F10–F22; F10–F13, F16, F17 RESOLVED in `bfb48cd` (36/36 tests; scripts verified on localnet);
  on-chain reads confirmed `0x0bedd0…` canonical for consumers, `0x692547…` also exists, testnet
  `UpgradeCap` live (compatible policy). Package made npm-consumable for the docs sites.
