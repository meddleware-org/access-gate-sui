# Security Audit — `access-gate-sui`

**Classification:** Internal security review (initial audit — awaiting external review)
**Project:** `repos/access-gate-sui` — permissionless NFT access-gate primitive (Sui Move)
**Project type:** Move package
**Template:** AUDIT_TEMPLATE.md (2026-09-28) + AUDIT_TEMPLATE_SUI.md (2026-09-28)
**Package:** `access_gate` v0.0.2; edition 2024; framework rev `b0535f1f3a33` (Move.lock, testnet)
**Deployment status:** testnet — package `0x1a81ca177db039585e575beeeee4759466e55910e936a6733e38dbb65025eea4` (published 2026-09-28 from `dcd2d3c`; `PlatformConfig` `0xe3b949ca…23f7`; UpgradeCap `0xf04a1d87…32bc` **live**, compatible policy, publisher EOA). Superseded: `0x0bedd0…d20d` (pre-policy source; still holds the live Walrus relay gate `0x0485…` until it migrates; UpgradeCap burned). Strays `0x692547…68bc`, `0x891cc2…985c`, `0xbd2b4f…7f79` (unused publishes; UpgradeCaps burned). Mainnet: unpublished.
**Review date:** 2026-09-18 (first pass) · re-verified and relocated 2026-09-28
**Reviewer:** Internal review (Move contract reviewer)
**Severity ceiling:** High — the package handles on-chain SUI payments and a platform commission split; a capability or accounting flaw could misroute funds. Realized ceiling: **Medium** (F1, F10, F12 — all RESOLVED in source/tooling).
**Status:** re-verified 2026-09-28 (third pass same day: platform fees, pause-blocks-access, republished)

Relocated from the workspace corpus (`docs/audit/access-gate-sui-audit.md`, now a pointer stub). All
`F#` / `OQ#` identifiers from the first pass are preserved.

---

## Executive summary

`access-gate-sui` is a small, dependency-free primitive (Sui framework only). Capability↔gate binding
is asserted on every privileged path; single-use spend takes the NFT by value (owner-only);
soulbound non-transferability is structural (`key` without `store`); abort codes are unique within
the module; emit-before-delete holds everywhere. **60/60** tests pass (sui 1.80.0), and every abort
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
- **F24** — per-gate, immutable `GatePolicy` (owner decision on OQ4/OQ5): gate-creating tools can
  forbid freezing a paused gate, lock the commission at freeze, and make pause block Seal
  decryption. Defaults are unrestricted, so existing behaviour is unchanged for direct callers.
- **F14, F21** — canonical address verified on-chain (`0x0bedd0…`; `Move.toml` no longer names the
  stray package); licence aligned to 0BSD everywhere.

A third pass the same day made the platform's revenue an on-chain guarantee (owner decision):
**F26** commission floor and minimum paid price, **F27** a one-off free-gate fee that no price
change can dodge, **F28** commission on airdrops; added **F29** `pause_blocks_access`; and the
companion gateway change **F30** (only access_gate passes of a required `GATE_ID` are accepted, so a
fungible token or foreign NFT can never stand in for a pass). The source was then published fresh as
`0x1a81ca…`, and every stray and superseded `UpgradeCap` burned (**F31**).

What remains is operational: custody of the new `UpgradeCap` and of platform authority (F2/F3 —
an **operator requirement before launch**; burn vs multisig still to be chosen), and migrating the
live Walrus relay gate and the apps to `0x1a81ca…` (they ship with the unpublished npm releases).

---

## Threat model / trust boundaries

| Authority / actor | Holds / proves | Can do | Bounded by |
| --- | --- | --- | --- |
| Anyone (permissionless) | nothing | `create_gate`; `purchase` (pay ≥ price); `consume*` / `burn*` on **own** NFT; all views | Sui ownership (by-value NFT); `E_PAUSED`, `E_INSUFFICIENT_PAYMENT`, `E_WRONG_GATE`, `E_NOT_SINGLE_USE`, `E_NO_USES_REMAINING`, `E_INVALID_NONCE` |
| Gate creator / `AdminCap` holder | `AdminCap { gate_id }` | `airdrop`; gate setters; `make_gate_immutable` | `cap.gate_id == id(gate)` (`E_WRONG_GATE`), `!frozen` (`E_GATE_FROZEN`), and the gate's immutable `GatePolicy` (`E_FREEZE_WHILE_PAUSED`) |
| Gate-creating tool (e.g. `access-gate-ui`) | operator build config | chooses the `GatePolicy` and minimum price of the gates **it** creates | nothing on-chain for other callers — policy binds the gate, not the creator (F24, F25) |
| Platform operator / `PlatformAdminCap` holder | `PlatformAdminCap` | `set_platform_treasury` (≠ `@0x0`); `set_commission_bps` (≤ 1000) — for every gate of this package except frozen gates whose policy locked the commission | `E_COMMISSION_TOO_HIGH`, `E_ZERO_ADDRESS`; no per-gate authority |
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
  `transfer-platform-authority.sh` end-to-end runs; testnet gRPC/GraphQL reads of `0x0bedd0…`,
  `0x692547…`, `0x1ab9…`, `0x6b6cd7…`, the live gate `0x0485…`, and every object of each package's
  types.

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
**Severity:** Low/Info   **Disposition:** RESOLVED (configurable per gate — F24; OQ4 answered)
By default the live platform rate (≤ 10%) still applies to frozen gates. A gate created with
`lock_commission_on_freeze` snapshots the rate at freeze and `purchase` uses
`effective_commission_bps` from then on. Tests: `test_lock_commission_on_freeze_uses_snapshot`,
`test_frozen_gate_without_lock_follows_live_commission`.

### F5 — `airdrop` blocked by freeze while `purchase` continues
**Severity:** Info   **Disposition:** ADJUDICATED — intentional; `test_airdrop_on_frozen_gate_aborts` added.

### F6 — Abort-code uniqueness (module) and arithmetic
**Severity:** Positive — codes 1–12 distinct within `access_gate`; after F10 no reachable arithmetic
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
**Remediation / evidence:** commit `c835520` — `commission_for(price, bps)` multiplies in u128 and
floors; `MAX_COMMISSION_BPS` / `BPS_DENOMINATOR` constants.
`test_purchase_max_price_max_commission_does_not_overflow` (u64::MAX at 1000 bps) and
`test_commission_dust_rounds_to_zero`. The deployed `0x0bedd0…` still has the u64 form (Section D).

### F11 — Platform treasury could be set to the zero address
**Severity:** Low   **Disposition:** RESOLVED (source; on-chain after republish)
**Where:** `set_platform_treasury`.
**Impact:** every paid purchase's commission sent to `@0x0` (unrecoverable) after one mistaken call.
**Remediation / evidence:** commit `c835520` — `E_ZERO_ADDRESS = 9`;
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
**Remediation / evidence:** commit `c835520` — `publish.sh` records every authority object ID by
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
**Remediation / evidence:** commit `c835520`; exercised on localnet (`--create-gate`) and with bad
arguments.

### F14 — Package address drift
**Severity:** Low   **Disposition:** RESOLVED (source + docs; OQ7 answered — `0x0bedd0…` is canonical)
**Issue:** `Move.toml published-at = 0x692547ae…` (a second, unused testnet deployment) while
`SECURITY.md`, every consumer (`walrus-relay`, `access-gate-ui`, `treasury-ui`, `dao-ui`, `seal-ui`,
`nft-gate-client` tests), the docs sites and the live gate type use `0x0bedd0…`. A Move package
depending on this repo at a revision whose manifest carries `published-at 0x692547…` links against
the unused package and cannot read live `Gate` objects. Local `Pub.testnet.toml` / `.env.localnet`
add two more addresses.
**On-chain verification (2026-09-28, testnet GraphQL):** `0x0bedd0…` (published 2026-08-28) owns
the live `Gate` `0x0485…`, two `SoulboundAccessNFT`s, an `AdminCap`, `PlatformConfig 0x7c5aed…` and
`PlatformAdminCap`, and is the `access_gate` linked by `seal_policies 0x9f0563…`. `0x692547…`
(published 2026-09-20 23:45, UpgradeCap `0x6b6cd7d451151e53716cf7b781133c2eb9b90aa35c8a84b00fde2881e487b9a2`,
held by the publisher EOA) has only its `init` objects — no gate or pass has ever been created on it.
**Remediation / evidence:** commit `22fe6d7` removes `published-at` from `Move.toml` (with a comment
naming the canonical and stray IDs); the next publish records itself in `Published.toml`. The stray
package is harmless but its `UpgradeCap` is live — burning it is OQ13.

### F15 — Mutable release tags
**Severity:** Low   **Disposition:** MITIGATED (dependants now pin commit SHAs) — OQ8
**Issue:** `v0.0.1` on the remote now points to `e6d63c6`, while the dependant lockfile resolved it
to `f191c2d`; local tags `v0.0.2` / `v0.0.3` are older than `v0.0.1` and absent from the remote.
**Remediation:** dependency docs now require SHA pins (README); tag hygiene is OQ8.

### F16 — `SECURITY.md` claimed the UpgradeCap is burned on publish
**Severity:** Low   **Disposition:** RESOLVED (statement corrected; underlying custody → F3)
**Evidence:** commit `c835520` — states the live testnet cap and the pre-mainnet gate; also
corrected the stale "nonce unvalidated" text (F1).

### F17 — Documentation drift
**Severity:** Info   **Disposition:** RESOLVED
**Issue:** README listed a non-existent `mint_to`, outdated signatures (`create_gate`, `purchase`),
16 tests, a moved tag and an out-of-repo link; source doc comments mentioned `mint_to` and
misdescribed `set_auto_burn_at_zero`; docs./dev. sites listed only abort codes 1–5 and a
non-existent `buy`.
**Evidence:** commit `c835520` (README, CLAUDE.md, source comments); canonical
`docs/onchain/*` now imported by both sites — docs `193ef22` (Move tables replaced by links to the
canonical pages), dev `4492c3c` (`buy` → `purchase` with the correct argument order).

### F18 — `auto_burn_at_zero` is read at consume time
**Severity:** Low   **Disposition:** ADJUDICATED (behaviour documented + tested; OQ9)
Changing the flag affects already-minted passes (`test_auto_burn_change_applies_to_existing_nfts`).

### F19 — Freezing a paused gate disables purchase forever
**Severity:** Low   **Disposition:** RESOLVED (configurable per gate — F24; OQ5 answered)
Default behaviour is unchanged (`test_frozen_while_paused_gate_cannot_be_purchased`). A gate created
with `freeze_requires_unpaused` refuses the freeze while paused (`E_FREEZE_WHILE_PAUSED = 10`,
`test_freeze_requires_unpaused_blocks_freezing_paused_gate`; unpaused path
`test_freeze_requires_unpaused_allows_freezing_unpaused_gate`).

### F20 — Setters emit no events
**Severity:** Info   **Disposition:** ACCEPTED-RISK (suggestion S1) — configuration history is not
indexable; current state is readable from the objects.

### F21 — Licence inconsistency
**Severity:** Info   **Disposition:** RESOLVED (OQ10 answered: 0BSD) — commit `22fe6d7` changes the
source and test SPDX headers from CC0-1.0 to 0BSD, matching `LICENSE`, `Move.toml` and `package.json`.

### F22 — `init` defaults verified
**Severity:** Positive — `test_init_creates_platform_objects`: `PlatformConfig {treasury: publisher,
commission_bps: 20}` shared; `PlatformAdminCap`, `Publisher` (from this module), both `Display` to the
publisher.

### F23 — docs./dev. sites import the canonical on-chain docs only after npm publication
**Severity:** Info   **Disposition:** RESOLVED (2026-09-28: `@meddleware/access-gate-sui@0.0.2` published and installed in both sites; builds import the real pages)
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

### F24 — Gate policies: freeze-while-paused, commission lock, pause blocks decryption
**Severity:** Info (design)   **Disposition:** RESOLVED (commit `22fe6d7`; on-chain after a fresh publish)
**Where:** `GatePolicy { freeze_requires_unpaused, lock_commission_on_freeze, pause_blocks_decryption }`
stored on `Gate` with `locked_commission_bps: Option<u64>`; `create_gate_with_policy`,
`new_gate_policy`, `default_gate_policy`; `make_gate_immutable(cap, gate, platform, ctx)`;
`effective_commission_bps`; `GateCreatedEvent.policy`, `GateFrozenEvent.locked_commission_bps`.
**Decision (owner):** freezing while paused should be supported, but configurable by the operator of
the gate-creating tool so re-users can restrict their deployment while Meddleware's does not; the
commission-lock and pause-blocks-decryption behaviours follow the same pattern.
**Design:** the policy is per gate and immutable (no setter), so buyers can rely on what they read.
`create_gate` keeps its signature and applies the all-false default. `pause_blocks_decryption` is
enforced by `seal_policies::nft_gate` (`E_GATE_PAUSED = 4`), not here.
**Evidence:** tests `test_create_gate_uses_default_unrestricted_policy`, `test_create_gate_with_policy_stores_policy`,
`test_freeze_requires_unpaused_blocks_freezing_paused_gate`,
`test_freeze_requires_unpaused_allows_freezing_unpaused_gate`, `test_lock_commission_on_freeze_uses_snapshot`,
`test_frozen_gate_without_lock_follows_live_commission` (42/42). Client: `nft-gate-client` `80f652e`;
tool config: `access-gate-ui` `e91781a` (`VITE_GATE_*`, all default `false`).
**Impact on release:** the `Gate` struct layout and the public `make_gate_immutable` signature
changed, which a compatible upgrade forbids — the release is a **new package**; gates of `0x0bedd0…`
(including the live paywall gate) stay on the old version.

### F25 — Dust prices pay no commission
**Severity:** Info   **Disposition:** RESOLVED at the tool layer (OQ11 answered)
**Issue:** commission rounds down, so a non-zero price below `⌈10000 / commission_bps⌉` MIST
(500 MIST at 20 bps) pays the platform nothing.
**Decision (owner):** the minimum is operator-configurable; Meddleware's deployment uses the minimum
profitable amount.
**Remediation / evidence:** first at the tool layer (`nft-gate-client` `80f652e`/`4f60283`,
`access-gate-ui` `e91781a`); **superseded by F26**, which enforces the floor on-chain for every
caller and makes it worthwhile rather than merely non-zero.

### F26 — Commission floor and minimum paid price (on-chain)
**Severity:** Medium (revenue integrity)   **Disposition:** RESOLVED (`6bdf8a6`; live in `0x1a81ca…`)
**Issue:** with a pure 0.2% commission, cheap passes paid the platform almost nothing (1 MIST at
the old 500 MIST floor), and any floor lived only in Meddleware's own tool, so a direct contract call
could create a dust-priced gate on Meddleware's package.
**Decision (owner):** the amount received should cover the service and leave a small profit that is
trivial per user but measurable across a small-to-medium user base, assuming every sale is at the
minimum price.
**Design:** `PlatformConfig.min_commission_mist`: commission = `max(⌊price × bps / 10000⌋,
min_commission)`, capped at 10% of the price (the existing promise to creators). A paid price must be
≥ `min_paid_price_mist` = 10 × the floor (`E_PRICE_TOO_LOW = 11` in `create_gate`/`set_price`), so
the floor always fits under the cap. Defaults: 20 bps, floor 1,000,000 MIST (0.001 SUI) ⇒ minimum
paid price 0.01 SUI. Raising the floor later never breaks existing gates: their commission stays
capped at 10%. Governed by `PlatformAdminCap` (`set_min_commission_mist`, event
`PlatformConfigUpdatedEvent`), so it can be tuned without a republish.
**Sizing:** at the minimum price each sale yields 0.001 SUI of commission, plus ~0.00098 SUI of
storage deposit in the commission coin that the treasury recovers when it merges coins — about
0.002 SUI per sale: ~2 SUI/month at 1,000 minimum-price sales, ~20 SUI at 10,000. The buyer pays
0.01 SUI (a few cents), comparable to a couple of transactions' gas. A higher floor was not needed for
spam deterrence: every sale already costs the buyer the price plus gas, and gate creation is
covered by F27.
**Evidence:** `test_min_commission_applies_to_cheap_purchases`, `test_percentage_applies_above_the_floor`,
`test_commission_capped_at_ten_percent_after_floor_raise`, `test_min_paid_price_is_ten_times_the_floor`,
`test_commission_for_price_formula`, `test_create_gate_below_min_price_aborts`,
`test_set_price_below_min_aborts`, `test_locked_terms_keep_the_floor`, `test_platform_fee_setters_update`.

### F27 — Free gates pay a one-off fee that no price change avoids
**Severity:** Medium (revenue integrity)   **Disposition:** RESOLVED (`6bdf8a6`)
**Decision (owner):** free gates are allowed if their creator pays an initial amount and the gate
cannot later be re-configured to escape it.
**Design:** `create_free_gate` pays `PlatformConfig.free_gate_fee_mist` (default 0.1 SUI — the
commission of 100 minimum-price sales) to the treasury; `create_gate` rejects price 0; a paid gate
becomes free only through `make_gate_free`, which charges the fee once (`free_fee_paid`); `set_price(0)`
aborts `E_FREE_FEE_UNPAID = 12` until then. Once paid, the gate may move freely between free and paid —
every paid sale carries the commission, so no transition loses revenue.
**Evidence:** `test_create_free_gate_pays_fee_and_refunds_excess`, `test_create_free_gate_underpaid_fee_aborts`,
`test_create_gate_zero_price_aborts`, `test_set_price_zero_without_fee_aborts`,
`test_make_gate_free_charges_once_then_price_can_toggle`.

### F28 — Airdrops could replace sales and bypass the commission
**Severity:** Medium (revenue integrity)   **Disposition:** RESOLVED (`6bdf8a6`)
**Issue:** a creator could sell passes off-chain and `airdrop` them, paying the platform nothing.
**Remediation / evidence:** `airdrop(cap, gate, platform, payment, recipient)` charges the commission
a purchase at the current price would carry (`gate_commission_mist`; 0 for a free gate, whose fee is
already paid); `AccessMintedEvent.commission_mist` records it. `test_airdrop_pays_commission_on_paid_gate`,
`test_airdrop_underpaid_commission_aborts`.

### F29 — `pause_blocks_access`: pausing can stop pass use, independently of decryption
**Severity:** Info (design)   **Disposition:** RESOLVED (`6bdf8a6`; gateways F30)
**Decision (owner):** relay uploads should be blockable as part of pausing, optionally and
independently of decryption, with the single best-practice mechanism.
**Design:** a fourth immutable `GatePolicy` flag. While paused, `consume*` aborts `E_PAUSED` (so a
single-use holder never spends a use that a gateway would then refuse), and the nft-gate gateways
read the gate live and deny holders (`403 the gate is paused`), checked before a single-use
redemption is leased so an earlier consume stays redeemable after unpausing.
**Evidence:** `test_pause_blocks_access_stops_consume`, `test_pause_without_access_policy_allows_consume`;
gateway tests in `nft-gate` `bbf8665`.

### F30 — A gateway could gate on a fungible token or foreign NFT (cross-project)
**Severity:** Low (revenue/scope)   **Disposition:** RESOLVED in `nft-gate` (`bbf8665`)
**Issue:** the gateways accepted any `NFT_TYPE` and treated `GATE_ID` as optional: a `Coin<T>` type
would admit holders of a fungible token (never sold through access_gate, so no commission), and
without `GATE_ID` any pass of the package — including passes of someone else's free gate — admitted.
access_gate itself only takes SUI and mints non-fungible passes, so there is no fungible-token path in
the contract.
**Remediation:** both gateways reject at startup an `NFT_TYPE` other than
`<pkg>::access_gate::(Soulbound)AccessNFT` and require `GATE_ID`. The 0BSD gateway code can of course
be modified by others; this keeps Meddleware's deployments and faithful re-users on the paid path.

### F31 — Republish and UpgradeCap burns
**Severity:** Info   **Disposition:** RESOLVED (owner-authorised, 2026-09-28)
Published `0x1a81ca…` from `dcd2d3c` (fresh package: the `Gate` layout and public signatures changed).
Burned (`0x2::package::make_immutable`): stray `0x692547…` cap `0x6b6cd7…` (`FXF4nU6K…`), stray
`0x891cc2…` cap `0xb0c90e…` (`4RRvo6Qr…`), stray `0xbd2b4f…` cap `0xe81b451c…` (`Fi65BSZA…`), and the
superseded `0x0bedd0…` cap `0x1ab9a455…` (`HB7XxxQz…`); packages keep working, only upgrades are
gone. The new relay gate `0xcb8206…5f50` (soulbound, 10 uses, 0.01 SUI) was created with
`publish.sh --create-gate`, whose PTB path was rewritten for the new ABI.

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
| I8b | **Policy:** `GatePolicy` immutable; `freeze_requires_unpaused` ⇒ no paused freeze; `pause_blocks_access` ⇒ no paused consume; locked terms are the only terms applied afterwards | `::create_gate`, `::create_free_gate`, `::make_gate_immutable`, `::consume_data`, `::effective_commission_terms` | F24, F29 tests | HOLDS |
| I16 | **Platform always paid:** paid price ≥ `min_paid_price_mist`; price 0 only after the free-gate fee; every paid mint (purchase or airdrop) pays `max(bps share, floor)` ≤ 10% of the price | `::create_gate`, `::create_free_gate`, `::set_price`, `::make_gate_free`, `::airdrop`, `::commission_for_price` | F26–F28 tests | HOLDS |
| I9 | **Arithmetic:** commission ≤ 10%, no overflow/underflow, floor rounding, dust = 0 | `::commission_for`, `::purchase`, `::set_commission_bps` | `test_purchase_nonzero_commission_splits_payment`, `test_purchase_max_price_max_commission_does_not_overflow`, `test_commission_dust_rounds_to_zero`, `test_set_commission_*` | HOLDS (source; deployed `0x0bedd0…` predates F10) |
| I10 | **Abilities:** soulbound cannot be `public_transfer`'d | `SoulboundAccessNFT has key` | type system; `test_soulbound_mint_and_consume` | HOLDS |
| I11 | Package immutable ⇒ semantics fixed for existing gates | `UpgradeCap` burned | on-chain read: testnet cap live | GAP (F3) |
| I12 | **Funds routing:** payment = commission + operator share + refund; treasury ≠ `@0x0` | `::purchase`, `::set_platform_treasury` | `test_purchase_overpay_refunds_remainder`, split tests, `test_set_platform_treasury_zero_address_aborts` | HOLDS |
| I13 | **Abort codes:** unique within module; map published | constants `E_*` 1–12 | every code has an `expected_failure` test; map in `docs/onchain/api-reference.md` | HOLDS |
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
| testnet | `0x1a81ca…eea4` (current) | `0xf04a1d87…32bc` | **held** by publisher EOA (policy 0) | burn or multisig — operator requirement before launch | `make_immutable` call or `transfer-platform-authority.sh --include-upgrade-cap` (dry-run default, `YES` confirm) |
| testnet | `0x0bedd0…d20d` (superseded) | `0x1ab9…4e89` | **burned** 2026-09-28 | — | — |
| testnet | `0x692547…`, `0x891cc2…`, `0xbd2b4f…` (strays) | `0x6b6cd7…`, `0xb0c90e…`, `0xe81b451c…` | **burned** 2026-09-28 | — | — |
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
| `GateCreatedEvent` | `create_gate*` | `policy` (buyers/indexers) | before share | indexers (dao/treasury use AdminCap discovery instead) |
| `AccessMintedEvent` | `purchase`, `airdrop` | — | before transfer | treasury-ui activity feed |
| `AccessConsumedEvent` | `consume*` | `nonce`, `gate_id`, `consumer` (+ tx digest) | after decrement, before delete | nft-gate gateways, treasury-ui |
| `AccessBurnedEvent` | auto-burn, `burn*` | — | before delete | indexers |
| `GateFrozenEvent` | `make_gate_immutable` | `locked_commission_bps` | after `frozen = true`, before cap delete | UIs |

---

## Section C — Test-coverage & hermetic/live split

### C.1 Coverage grade — A (60/60, sui 1.80.0)

| Dimension | Assessment |
| --- | --- |
| Happy-path | A — init defaults, create, purchase (exact/overpay/free), commission split, single-use decrement + receipt, auto-burn, soulbound mint+consume, airdrop, burns, setters, freeze, platform setters |
| Error-path / abort codes | A — codes 1–12 each have `expected_failure` tests; 3/4/5/8 also on the soulbound path |
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

- [x] compiles; 60/60 hermetic tests green (sui 1.80.0) — CI `move-ci.yml`
- [x] every abort code tested; no unchecked u64 products; all caps bound (F6, F9, F10)
- [x] `SECURITY.md` present and consistent with this audit (F16)

### pre-testnet

- [x] docs./dev. sites install the published `@meddleware/access-gate-sui` and import its on-chain docs — F23
- [x] published — `0x1a81ca…` (all fixes through F31; `Published.toml`)
- [x] package ID recorded consistently across `Move.toml` / `SECURITY.md` / consumers — F14
- [x] dependants pin commit SHAs (seal-policies `f191c2d`) — F15
- [x] custody/immutability tooling with dry-run default + explicit confirmation — F12/F13
- [x] fresh publish; seal-policies republished against it (`0x42cc18…`); consumer defaults and docs
  point at the new IDs (in each repo, unreleased)
- [ ] push access-gate-sui, then regenerate seal-policies' `Move.lock` (CI red until then)
- [ ] release the npm packages and apps that target the new ABI, and migrate the live Walrus relay
  gate (walrus-ui `VITE_ACCESS_GATE_ID_TESTNET` + Worker `GATE_ID`/`NFT_TYPE`) in one step

### pre-mainnet

- [ ] **Operator requirement before launch:** choose burn vs multisig for the `UpgradeCap` and
  execute it at publish — **blocking** (F3, OQ1)
- [ ] **Operator requirement before launch:** `PlatformAdminCap` / `Publisher` / `Display` moved to
  a multisig — **blocking** (F2, OQ2)
- [ ] current testnet `UpgradeCap` (`0xf04a…`) burned or moved — non-blocking (F3, OQ1); strays and superseded caps burned (F31)
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
7. The canonical package address MUST be the one recorded in `Published.toml`, `SECURITY.md` and
   every consumer — holds (`0x0bedd0…`; `Move.toml` carries no `published-at`) (F14).
9. A gate's `GatePolicy` MUST be immutable after creation, and locked commission terms MUST be the
   only terms applied to that gate — holds (I8b).
10. Every gate of the package MUST yield platform revenue: paid mints (purchases and airdrops) pay
    the commission floor or more, and a free gate pays the free-gate fee once — holds (I16).
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
   versioning/migration policy be announced to integrators? *(2026-09-28, owner: design as if a multisig holds authority — for now a single key. New versions with crucial changes stay upgradeable under that authority while being tested; once ready for regular users the same authority burns the cap. No burn yet unless the cap goes stale.)* *(2026-09-28, owner: burn vs multisig
   not yet decided; recorded as an operator requirement before launch — Section D.)*
2. **OQ2** *(first pass — decided: multisig is the target custody)* Which multisig address (and
   M-of-N) will hold platform authority, and when will `transfer-platform-authority.sh` be run?
   *(2026-09-28, owner: multisig to be configured later; operator requirement before launch.)*
3. **OQ3** *(first pass — decided: on-chain min length + `consumer` field; uniqueness off-chain)*
   Should the minimum nonce length be raised from 8 to 16 bytes to match the recommended verifier
   nonce?
4. **OQ4** Is it acceptable that `set_commission_bps` changes the economics of frozen gates (≤ 10%)?
   *(2026-09-28, owner: make it configurable per deployment — implemented as F24's
   `lock_commission_on_freeze`; Meddleware's tool leaves it off.)*
5. **OQ5** Should `make_gate_immutable` refuse to freeze a paused gate (or unpause it), rather than
   allow a permanently unsellable gate? *(2026-09-28, owner: support it, configurable — F24's
   `freeze_requires_unpaused`; Meddleware's tool leaves it off.)*
6. **OQ6** Is per-gate metadata (copied at mint) the source of truth, with the global `Display` a
   passthrough — and who may change the `Display` templates?
7. **OQ7** Which testnet package is canonical — `0x0bedd0…` (every consumer, live gates) or
   `0x692547…` (`Move.toml published-at`)? Should the F10/F11 fixes be republished as a new canonical
   package, and consumers migrated? *(2026-09-28: on-chain reads show `0x0bedd0…` is canonical (F14);
   owner will republish once the off-chain changes are in, so they can be tested together.)*
8. **OQ8** Tag hygiene: will release tags be made immutable (never moved) and reconciled with the
   remote (`v0.0.2` / `v0.0.3` exist only locally and predate `v0.0.1`)?
9. **OQ9** Should `auto_burn_at_zero` be snapshotted per NFT at mint instead of read from the gate at
   consume time?
10. **OQ10** Which licence applies — 0BSD (`LICENSE`, `Move.toml`) or CC0-1.0 (source headers)?
    *(2026-09-28, owner: 0BSD — F21.)*
11. **OQ11** Dust pricing: at 0.2% any price below 500 MIST pays no commission. Enforce a minimum
    price, or accept? *(2026-09-28, owner: operator-configurable, minimum profitable amount in
    Meddleware's deployment — F25, tool layer.)*
12. **OQ12** Should `create_gate` / `set_payment_recipient` also reject `@0x0` (it would break
    free-gate creators who pass the zero address today)?
13. **OQ13** Burn the stray package's `UpgradeCap` (`0x6b6cd7…a9a2`, for `0x692547…`) — and the
    `seal_policies` stray `0x67520f…`'s cap — so no one can ever upgrade them into something
    consumers might mistake for the real package? *(2026-09-28, owner: yes — done, with every other
    stray and superseded cap (F31).)*
14. **OQ14** Free (price 0) gates earn no commission. Should Meddleware's deployment allow them
    (`VITE_GATE_ALLOW_FREE`, currently `true`)? *(2026-09-28, owner: yes, if creation is charged and
    cannot be dodged by re-configuration — F27; the tool default stays `true`.)*
15. **OQ15** Should the `nft-gate` gateways also honour `pause_blocks_decryption` (i.e. deny relay
    access with existing passes while a gate is paused), or does it stay Seal-only as named?
    *(2026-09-28, owner: make it optional and independent — F29's `pause_blocks_access`.)*
16. **OQ16** Are the default platform terms right for Meddleware's deployment — 0.2% with a 0.001 SUI
    floor (minimum paid price 0.01 SUI) and a 0.1 SUI free-gate fee? All are adjustable on-chain
    without a republish (F26, F27).

## Risks (residual)

- **Key custody:** until F2/F3 execute, one publisher key controls package code, commission routing
  and NFT display for every gate.
- **Verifier correctness:** replay protection depends on each gateway implementing B.5; a careless
  integrator can still build a replayable service.
- **Version fragmentation:** each immutable release is a new address with its own `PlatformConfig`;
  gates and passes never migrate automatically.
- **Mutable git tags** remain a supply-chain hazard for any dependant that pins a tag instead of a SHA.
- **Metadata phishing:** anyone can create gates with arbitrary names/images.
- **Tool-level policy:** `GatePolicy` is chosen by the creating tool; gates created by calling the
  contract directly can be unrestricted. Buyers must read the gate's policy, not assume a tool's
  defaults. (Prices, fees and commission are enforced on-chain for everyone — F26–F28.)
- **Effective rate on cheap passes:** the commission floor makes the platform's share 10% at the
  minimum price, falling to the 0.2% rate at 0.5 SUI and above; creators of cheap passes keep 90%.
- **Revenue depends on coin sweeping:** about half of each minimum-price sale's value to the treasury
  is the storage deposit of the commission coin, recovered only when the treasury merges its coins.
- **Commission lock and platform revenue:** a gate that locks its commission at freeze is immune to
  later platform rate changes, in either direction.

---

## Re-verification log

- 2026-09-18 — first-pass baseline (18 → 22 tests; F1–F9; OQ1–OQ6).
- 2026-09-28 — relocated to the package repo; re-verified under the updated template + Sui lens.
  Added F10–F22; F10–F13, F16, F17 RESOLVED in `c835520` (36/36 tests; scripts verified on localnet);
  on-chain reads confirmed `0x0bedd0…` canonical for consumers, `0x692547…` also exists, testnet
  `UpgradeCap` live (compatible policy). Package made npm-consumable for the docs sites.
- 2026-09-28 (second pass) — owner answers to OQ1/2/4/5/7/10/11 recorded. F24 (gate policies) and
  F21 (0BSD) RESOLVED in `22fe6d7`; F14 RESOLVED (on-chain GraphQL reads: `0x0bedd0…` canonical,
  `0x692547…` holds only init objects, its UpgradeCap `0x6b6cd7…` live); F4/F19 RESOLVED via
  policy; F25 (dust pricing) RESOLVED at the tool layer (`nft-gate-client` `80f652e`/`4f60283`,
  `access-gate-ui` `e91781a`). 42/42 tests. OQ13–OQ15 added.
- 2026-09-28 (third pass) — F26 (commission floor, minimum paid price), F27 (free-gate fee), F28
  (airdrop commission), F29 (`pause_blocks_access`) RESOLVED in `6bdf8a6`; F30 in `nft-gate`
  `bbf8665`; published fresh as `0x1a81ca…` (`dcd2d3c`) and every stray/superseded UpgradeCap burned
  (F31). 60/60 tests. OQ13–OQ15 answered; OQ16 added. Live checks: `nft-gate-client` gRPC read tests
  against the new `PlatformConfig` pass; seal timelock round-trip on the republished `seal_policies`
  passes.
