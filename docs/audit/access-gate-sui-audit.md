# Security Audit — `access-gate-sui`

**Classification:** Internal security review (initial audit — awaiting external review)
**Project:** access-gate-sui  (`access_gate` — permissionless NFT access-gate primitive on Sui: gates,
  transferable/soulbound passes, on-chain single-use spend, platform commission and fees, version
  gating; plus the publish/custody scripts and the npm package that ships the source, records and
  on-chain docs)
**Project type:** Move package (+ on-chain operations scripts + npm package)
**Template:** AUDIT_TEMPLATE.md (2026-10-08) + AUDIT_TEMPLATE_SUI.md (2026-09-28) +
  AUDIT_TEMPLATE_OPS.md (2026-10-08) + AUDIT_TEMPLATE_TS.md (2026-10-08, npm-package rows only — the
  package ships no TypeScript) + AUDIT_TEMPLATE_SUI_CLIENT.md (2026-10-08, applied only to the
  `publish.sh --create-gate` PTB)
**Package:** `access_gate` v0.0.6; edition 2024; framework rev `b0535f1f3a3310e71790e90d8ae4e8ca840c897e`
  (`Move.lock`, testnet and localnet)
**Deployment status:**

| Network | Package (original-id = published-at) | Version | UpgradeCap | Status |
| --- | --- | --- | --- | --- |
| testnet (current) | `0xd7ddaa94b74330979b2b618fc81206d160a264f1c9ca148a77fa2144301388c9` | 1 | `0x7d63f6230dc3d711345f23dc1354d4a7d5beeb85aa7dbc80b1ab8df92dfddf92` — **live**, held by publisher EOA `0xa991ae11…164864a` (read on-chain 2026-10-09) | republished 2026-10-09 (0.0.6; record commit `7906954`, docs `83dbf25`), toolchain 1.81.0, version-gated |
| testnet | `0xa55789d77b8ae41e604c1c2e9ad9f7b034ca69b028ad0f1eee7d7cc8ad886d41` (superseded, 0.0.5) | — | `0x70be984f…e0ba` burned 2026-10-09 (object no longer exists, read on-chain 2026-10-09) | immutable |
| testnet | `0x1a81ca177db039585e575beeeee4759466e55910e936a6733e38dbb65025eea4` (superseded) | — | `0xf04a1d87…32bc` burned 2026-10-02 | immutable |
| testnet | `0x0bedd0b27d993d3292ca6a5315f7562de8bc0ff3752b445b4c53252c76f2d20d` (superseded, pre-policy) | — | `0x1ab9a455…` burned 2026-09-28 | immutable |
| testnet | strays `0x692547ae…68bc`, `0x891cc27c…985c`, `0xbd2b4f…7f79` | — | burned 2026-09-28 | immutable |
| mainnet | — | — | — | unpublished |

`PlatformConfig` (testnet, current) is `0x3f81489df58233d96798f34ad44de325e1b4df7e4d615affe72ca181969ee7b5`.
The live Walrus relay gate is `0x316f1bf9764db352e925bb598aff44ea77be4ab652f0bd2eb3fdcc0a378faddc`, a
`0xd7ddaa94…::access_gate::Gate` (soulbound, 10 uses, 0.01 SUI, all policy flags `false`; admin cap
`0x8e51e9f1…5b78`) created 2026-10-09, per `access-gate-gateway/gateway-workers/wrangler.toml` and a live GraphQL
read. The earlier relay gates `0xfd6c3b…b8a6` (on `0xa55789…`), `0xcb8206…5f50` (on `0x1a81ca…`) and
`0x0485…` (on `0x0bedd0…`) are superseded.
npm `@meddleware/access-gate-sui` 0.0.6 was published 2026-10-09T12:45Z (tag `v0.0.6` → `83dbf25`); 0.0.5
(2026-10-02) carried the earlier, stale audit and remains on the registry (F43). Checked 2026-10-18: 0.0.6 is
still `latest` (no newer release; `main` has only audit commits since the tag, `83dbf25`), SLSA v1 provenance present.
Consumers: `@meddleware/access-gate-client` 0.0.9 pins `0.0.6` exactly (devDependency); the docs and dev sites depend on `^0.0.6`.
**Review date:** 2026-09-18 (first pass) · relocated 2026-09-28 · re-verified 2026-10-03 · **re-verified 2026-10-09** · release status 2026-10-18
**Reviewer:** Internal review (Move contract reviewer)
**Severity ceiling:** High — the package moves SUI on every paid mint (price, commission, fees) and
  holds upgrade and platform authority, so a capability or accounting flaw could misroute funds for
  every gate. Realised ceiling at this pass: **Low** (the two Low custody findings F2/F3 are
  mainnet-blocked). F10, F12, F26–F28 and, since 2026-10-08, F34 (the Medium verifier-contract finding)
  are resolved.
**Status:** re-verified 2026-10-09 (fifth pass: the 0.0.6 fixes verified against the source, the tests, the
  scripts, the docs and the live republish)

**CLI tools:** sui **1.81.0**, pinned in `move-ci.yml` via `suiup@v0.0.14` (sha256-pinned) and, since
  0.0.6, a sha256 check of the installed `sui` binary itself (`npm-publish.yml` runs `move-ci.yml` as its
  verify job), matching `Published.toml` `toolchain-version = "1.81.0"`. The scripts hard-fail on a
  major.minor mismatch (`ALLOW_TOOLCHAIN_CHANGE=1` for a deliberate move); `jq` is required.
**Networks targetable:**

- `publish.sh`: localnet, testnet, mainnet (mainnet needs `MAINNET_CONFIRM=1`).
- `transfer-platform-authority.sh` and `make-immutable.sh`: the same three, with the same guard.
- `multisig-address.sh`: offline.

**Key material:** the operator's local `sui` keystore (active address) for every signing script. A
  multisig signs from members' keystores per `CUSTODY.md`. **No keys in CI**: no workflow signs on a
  chain.

**Package manager / lockfile:** npm; `package-lock.json` committed (no dependencies)
**Module format / publish model:** no JavaScript. The npm tarball ships the Move source, `Move.toml`,
  `Move.lock`, `Published.toml`, `deployments.json`, `docs/`, `README.md`, `SECURITY.md`, `CUSTODY.md`
  and `LICENSE` (15 files). It is consumed at build time by the docs/dev sites (`gen-onchain.mjs`) and
  by `@meddleware/access-gate-client` (`gen-deployments.mjs`).
**Runtime targets / peer dependencies:** none / none (`engines.node` `^22.18.0 || >=24.12.0`)

The audit lives in the package at `docs/audit/access-gate-sui-audit.md` (in the repository; since 0.0.6 it
is no longer in the npm tarball — F43). The workspace corpus keeps a pointer stub. All `F#`/`OQ#` IDs
since the first pass are preserved.

---

## Executive summary

`access_gate` is a single dependency-free Move module of 1,278 lines; its only dependency is the Sui
framework. The core guarantees hold:

- Capability↔gate binding is asserted on every privileged path.
- Single-use spend takes the NFT by value, so only the owner can spend it.
- Soulbound non-transferability is structural (`key` without `store`).
- Commission is computed in u128, floored, and capped at 10%.
- Every paid mint, airdrops included, pays the platform. Free gates pay a one-off fee.
- Since 2026-10-02 (D22), **version gating** names the one package version allowed to act:
  `PlatformConfig.version`, enforced by `check_version` in every state-changing, minting or consuming
  function, with a forward-only `migrate`. An upgrade during the custody window can therefore retire
  faulty code for every caller at once.

At this pass, **94/94 tests pass** on sui 1.81.0. Every abort code 1–16 has an `expected_failure` test,
including 20 wrong-version tests, and module line coverage is **100%** (`sui move coverage summary`).
`sui move build --lint --warnings-are-errors` is clean. shellcheck 0.9 is clean on the four scripts
(commit `9defe35`; shellcheck is not installed in the review sandbox, so it was not re-run here, but CI
runs it on every push).

**What changed since the 2026-10-03 pass.** The 2026-10-03 pass recorded findings only (F34–F44). Almost
all of them were fixed on 2026-10-08 in `7b75da3` (0.0.6) and the package was republished on testnet on
2026-10-09 (`7906954`, `83dbf25`) at `0xd7ddaa94…88c9`; the previous package `0xa55789…` is now
immutable. This pass re-verified every finding against that code:

- **F34 (Medium)** — the verifier contract. Decided: digest-first redemption is canonical (OQ17).
  The six statements (module doc, `SECURITY.md`, `dev-guide.md` rule 2, the api-reference event row,
  `CLAUDE.md` invariant 2, B.5) now describe it.
- **F35/F36** — the pass kind and the pause policy are fixed at creation: `set_soulbound` is removed,
  `set_default_uses` cannot cross zero (`E_USES_KIND_IMMUTABLE` = 16), and `new_gate_policy` refuses a
  policy that lets a paused gate be frozen while pause blocks access or decryption
  (`E_POLICY_COMBINATION` = 15).
- **F37** — the coverage gaps are closed by new tests (100% line coverage).
- **F38/F39/F43** — the docs, `SECURITY.md` and the npm file list match the code (the audit is no longer
  shipped in the tarball).
- **F40/F41** — authority object IDs are committed (`deployments.json` `authorityObjects`), the scripts
  check the expected signer and the balance, verify the burn, and re-read ownership after a transfer.
- **F44** — the `sui` binary is checksum-pinned, and CI builds with lints as errors.

**Dispositions (49 findings):** RESOLVED 34 · Positive 7 · ADJUDICATED 3 · MITIGATED 1 · ACCEPTED-RISK 2 ·
DEFERRED 2 (F2, F3, mainnet-blocked).

**Open items, most important first (both mainnet-blocked):**

1. **F2/F3 (Low)** — custody is decided (2026-10-01, `CUSTODY.md`: multisig, then a verification window,
   then a multisig burn) and the tooling is complete and now verifies its own result. On testnet the live
   UpgradeCap `0x7d63f623…ddf92` and all platform authority are with the publisher EOA (read on-chain
   2026-10-09; `deployments.json` `multisigAddress: null`). Execution is the pre-mainnet process in
   `OPERATOR_TASKS.md` "Mainnet release custody — every full release".
2. **External review** — awaited (Section D).

**Posture:** sound contract, disciplined tooling, documentation consistent with the code and the deployed
verifiers. The residual work is the maintainer-run custody process and external review before mainnet.
Two new records this pass: F47 (the base template's 2026-10-08 release-integrity rows, met in 0.0.6) and
F48 (the republish orphans gates and passes on the superseded package; accepted under the pre-v0.2
policy).

---

## Threat model / trust boundaries

| Authority / actor | Holds / proves | Can do | Bounded by |
| --- | --- | --- | --- |
| Anyone (permissionless) | nothing | `create_gate` (price ≥ `min_paid_price_mist`), `create_free_gate` (pays the free-gate fee), `purchase`, `consume*`/`burn*` on **own** NFTs, all views | `check_version` (13); Sui ownership (by-value NFT); codes 1–5, 8, 11 |
| Gate creator / `AdminCap` holder | `AdminCap { gate_id }` | `airdrop` (pays commission), price/recipient/pause/uses-count/auto-burn/display setters, `make_gate_free`, `make_gate_immutable` | `cap.gate_id == id(gate)` (5); `!frozen` (6); immutable `GatePolicy` and pass kind (10, 15, 16; no `soulbound` setter); price rules (11, 12) |
| Gate-creating tool (e.g. access-gate-ui) | its build config | chooses the `GatePolicy` and pass kind of the gates **it** creates | the policy-combination rule (15) for every caller; otherwise policy binds the gate, not the creator |
| Platform operator / `PlatformAdminCap` holder | `PlatformAdminCap` | `set_platform_treasury` (≠ `@0x0`), `set_commission_bps` (≤ 1000), `set_min_commission_mist`, `set_free_gate_fee_mist` (**unbounded**, F42), **`migrate`** (retires every older package version) | codes 7, 9, 14; the 10% commission cap per mint; no per-gate authority |
| Package publisher | `UpgradeCap`, `Publisher`, both `Display` | upgrade bytecode; edit wallet display templates | `CUSTODY.md` lifecycle (multisig, then burn); today a single EOA (F2/F3, mainnet-blocked) |
| Off-chain verifier / gateway | reads events and owned objects | grant or deny access | digest-first redemption: its own redemption store and freshness window (B.5, F34) |
| Dependent Move package (`seal_policies`) | links `access_gate` at commit `790695489fc4` (`7906954`) | calls ungated views (`is_valid_for*`, `gate_*`, policy reads) | read-only; unaffected by version gating |
| Operator running the scripts | local keystore + active env | publish, transfer authority, burn | OPS preflight + confirmations (OPS matrix below) |

**Primary trust anchor:** the per-gate `AdminCap` binding, Sui object ownership and, for upgrades and
platform terms, the custody of `UpgradeCap` and `PlatformAdminCap`. The consume `nonce` is not a trust
anchor on its own: replay protection is a verifier obligation, met by digest-first redemption (F1, B.5, F34).

### Capabilities & shared objects (Move lens)

| Object / type | Minted / created by | Holder / custodian | Authority it confers | Compromise / misuse impact | Immutability / rotation plan |
| --- | --- | --- | --- | --- | --- |
| `UpgradeCap` `0x7d63f623…ddf92` (testnet) | publish | publisher EOA `0xa991…864a` (on-chain read 2026-10-09) | replace package code; with `migrate`, retire every older version | arbitrary logic for every gate, pass and payment | `CUSTODY.md`: transfer to the multisig (`transfer-platform-authority.sh --include-upgrade-cap`), verification window, multisig burn (`make-immutable.sh`) on `plannedBurnDate` — **pre-mainnet blocking** (F3; `OPERATOR_TASKS.md` "Mainnet release custody") |
| `PlatformAdminCap` | `init` | publisher EOA | treasury, commission, floor, free-gate fee, **`migrate`** | redirect all commission; raise rates to the 10% cap; block new paid gates (F42); retire versions | multisig permanently (`CUSTODY.md`) — pre-mainnet blocking (F2) |
| `Publisher` + `Display<AccessNFT>` + `Display<SoulboundAccessNFT>` | `init` (OTW) | publisher EOA | wallet name/image/description templates for every pass | metadata spoofing / phishing across all gates | multisig permanently — pre-mainnet blocking (F2) |
| `PlatformConfig` (shared) | `init` | shared | read by every gated call; holds `version` | — (mutable only via `PlatformAdminCap`) | one per package lineage (survives upgrades) |
| `AdminCap` (per gate) | `create_gate` / `create_free_gate` | gate creator | one gate's configuration, airdrop, freeze | that gate's price, payout, pause, use count and display changed; the pass kind and policy cannot be (F35/F36) | renounced by `make_gate_immutable` |
| `Gate` (shared) | `create_*` | shared | — | — | frozen by `make_gate_immutable` |
| External shared objects | — | — | none (`Clock` and `Random` unused; timestamps are `ctx.epoch_timestamp_ms()`) | — | n/a |

### Operations matrix (OPS lens)

| Actor / asset | Power | Bounded by |
| --- | --- | --- |
| Operator EOA / keystore (`0xa991…`) | signs every publish, transfer and direct burn | preflight (env, chain id, CLI version, `EXPECTED_SIGNER` — required on mainnet — and a balance check, F41); custody plan |
| Multisig (planned; none configured) | co-signs the burn, `migrate`, platform setters | `CUSTODY.md`; `make-immutable.sh` writes unsigned transactions only |
| CI runner | none — no workflow signs on a chain | — |
| Env files sourced (`.env.<network>`) | parameters and authority object IDs the transfer script acts on | git-ignored (`.gitignore` covers `.env.localnet/testnet/mainnet`, `.env.*.bak`); the authority IDs are also committed in `deployments.json` `authorityObjects`, which the transfer script prefers (F40) |
| CLI binaries / installers | what executes | suiup sha256-pinned and the installed `sui` binary sha256-checked in CI (F44) |
| Operator's global CLI state | which network and signer is used | scripts never switch env; `chain-identifier` caches the id in `client.yaml` (documented) |
| Downstream consumers of written IDs | trust `Published.toml` / `deployments.json` | record-keeping (OPS §A) — verified consistent this pass (B.SC-1) |

### Script inventory (OPS lens)

| Script / job | Signs? | Objects touched | Irreversible? | Dry-run default | Confirmation | Network guard | Writes IDs to |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `scripts/publish.sh <net>` | yes | new package + init objects | publish: effectively (new IDs) | **no** (publish runs immediately after preflight; F41e) | none for publish; mainnet `MAINNET_CONFIRM=1` and `EXPECTED_SIGNER` | active env + chain id + CLI major.minor + expected signer + balance ≥ `GAS_BUDGET`; `--replace-published` required to republish over a record | `.env.<net>` (all IDs; previous kept as `.bak`), `deployments.json` (`platformConfigId`, `authorityObjects`, custody), `Published.toml` (by sui) |
| `publish.sh --create-gate` | yes | new `Gate` + `AdminCap` (free gate pays the fee) | no | no | none | as above | `.env.<net>` (`ACCESS_GATE_GATE_ID`, `ACCESS_GATE_ADMIN_CAP_ID`) |
| `publish.sh --make-immutable` | yes | `UpgradeCap` (burn) | **yes** | n/a (flag) | typed `BURN <cap prefix>` | as above; skipped on localnet | `deployments.json` `burnedAt`; removes the cap from `.env` only after re-reading that the cap no longer exists (F41) |
| `scripts/transfer-platform-authority.sh` | yes | `PlatformAdminCap`, `Publisher`, `Display×2` (+ `UpgradeCap` with `--include-upgrade-cap`) | yes (custody) | **yes** (`DRY_RUN=1`) | `YES`, plus `UPGRADECAP` for the cap | env + chain id + CLI + `EXPECTED_SIGNER` (mainnet-required); mainnet double guard; on-chain type/package/owner re-check before, new-owner re-read after | `deployments.json` `custody.multisigAddress` (+ `upgradeCapOwner`); reads IDs from `authorityObjects` |
| `scripts/make-immutable.sh` | direct: yes; multisig: writes an unsigned transaction | `UpgradeCap` | **yes** | **yes** | `YES` (direct) | env + chain id + CLI; mainnet double guard; cap type + package + owner check | `deployments.json` (direct path, current cap only); `custody-out/*.txbytes` (git-ignored) |
| `scripts/multisig-address.sh` | no | — | no | n/a | n/a | n/a | stdout |
| `.github/workflows/move-ci.yml` | no | — | — | — | — | — | — |
| `.github/workflows/npm-publish.yml` | npm only (OIDC) | npm package | npm version | — | tag-gated; its verify job is `move-ci.yml` | — | — |

---

## Severity scale

Critical / High / Medium / Low / Info / Positive.

## Scope

**In scope (`main` = `83dbf25` = tag `v0.0.6`; fixes `7b75da3`, publish record `7906954`):**

- `sources/access_gate.move` (1,278 lines), `tests/access_gate_tests.move` (1,924 lines, 94 tests)
- `Move.toml`, `Move.lock`, `Published.toml`, `deployments.json`, `package.json`, `package-lock.json`,
  `.gitignore`, `.github/dependabot.yml`
- `scripts/{publish,transfer-platform-authority,make-immutable,multisig-address}.sh`
- `.github/workflows/{move-ci,npm-publish}.yml`
- `SECURITY.md`, `CUSTODY.md`, `README.md`, `CLAUDE.md`, `AGENTS.md`, `docs/onchain/*`

**Cross-repo evidence (read-only):**

- `sealed-storage-sui` `Move.toml`/`Move.lock` (pins `790695489fc4`)
- `@meddleware/access-gate-client` `src/deployments.ts` (generated from access-gate-sui 0.0.6) and
  `src/ptb.ts` (exact payment splits)
- `access-gate-gateway/gateway-workers/wrangler.toml` (`NFT_TYPE`/`GATE_ID`) and both gateways' consume
  verification

**Out of scope:** the Sui framework; verifier implementations (nft-gate's own audits); downstream apps.

**Environment / commands (2026-10-09):**

| Command | Result |
| --- | --- |
| `sui --version` | `sui 1.81.0-bf0c491c17b8` — the release CI and `Published.toml` pin; its sha256 `c86c0481…22f7f1` equals the checksum `move-ci.yml` enforces |
| `sui move test --build-env testnet` (on a `git archive` copy of `83dbf25`) | **94 passed, 0 failed** |
| `sui move build --build-env testnet --lint --warnings-are-errors` | clean |
| `sui move test --coverage` + `sui move coverage summary` | **100.00%** module coverage |
| `shellcheck -x -P SCRIPTDIR scripts/*.sh` | **not re-run** (shellcheck is not installed in the review sandbox); `9defe35` records "shellcheck 0.9 clean" and CI runs it on every push |
| `npm pack --dry-run` | 15 files, 33.4 kB; no `docs/audit/`, tests, scripts or env files |
| `npm view @meddleware/access-gate-sui` | 0.0.6 published 2026-10-09T12:45Z; 0.0.5 (2026-10-02) not deprecated |
| On-chain reads (GraphQL `graphql.testnet.sui.io`, read-only, 2026-10-09) | `0xd7ddaa94…` exists (v1); the caps `0x70be984f…` (of `0xa55789…`) and `0xf04a1d87…` (of `0x1a81ca…`) no longer exist (a package object always reads `Immutable`, so the missing cap is the evidence); the new cap `0x7d63f623…` is `AddressOwner` `0xa991…864a`; relay gate `0x316f1bf9…` is a `0xd7ddaa94…::access_gate::Gate` (soulbound, `default_uses` 10, price 10,000,000 MIST, admin cap `0x8e51e9f1…`, all policy flags `false`) |
| Consumer trace (read-only files) | `access-gate-client/src/deployments.ts`, `sealed-storage-sui/Move.toml`+`Move.lock`, `access-gate-gateway/gateway-workers/wrangler.toml` all name `0xd7ddaa94…` / commit `7906954` / gate `0x316f1bf9…` (B.SC-1) |

---

## Findings

### F1 — Consume `nonce` unvalidated and unbound on-chain; replay safety is a verifier obligation

**Severity:** Medium   **Disposition:** RESOLVED (first pass; on-chain part)
**Where:** `sources/access_gate.move::consume_data` (`:797-826`).

**Issue (2026-09-18):** The nonce was caller-supplied, unchecked and not bound to the sender.

**Impact:** An integrator could build a replayable gateway believing the chain enforced one-time use.

**Remediation / evidence:**

- `MIN_NONCE_LENGTH = 8` / `E_INVALID_NONCE = 8` is asserted first (`:805`).
- `consumer` (the transaction sender) is emitted in `AccessConsumedEvent`.
- Tests: `test_consume_short_nonce_aborts`, `test_consume_soulbound_short_nonce_aborts`.
- Uniqueness and freshness stay off-chain by design (B.5).

Re-verified 2026-10-09 (`83dbf25`; both tests pass). The verifier contract documented for it now matches
the deployed verifiers: digest-first redemption (F34, resolved).

### F2 — Platform authority and NFT Display custodied by one publisher EOA

**Severity:** Low   **Disposition:** DEFERRED (mainnet-blocked: process decided — OQ2 / `CUSTODY.md`;
execution is the maintainer's `OPERATOR_TASKS.md` item "Mainnet release custody — every full release")
**Where:** `init` (`:394`) sends `PlatformAdminCap`, `Publisher` and both `Display`s to the sender.

**Issue / Impact:** A key compromise could redirect all commission, change platform terms (F42),
`migrate`, and rewrite every pass's wallet display.

**Remediation / evidence:**

- `CUSTODY.md` (2026-10-01): these objects are held by the multisig **permanently**.
- Tooling: `transfer-platform-authority.sh` (dry run by default, `YES`, on-chain re-verification) and
  `multisig-address.sh`.
- Testnet today (2026-10-09, on-chain read): all four objects of `0xd7ddaa94…` —
  `PlatformAdminCap` `0x6debe232…4aa0`, `Publisher` `0x603ab7bf…111f`, the two `Display`s
  `0xfde18772…ebdd` and `0x27e9642e…453d` — are owned by the EOA `0xa991…864a`, and `deployments.json`
  records `multisigAddress: null`. Their IDs are now committed in `deployments.json` `authorityObjects`
  (F40).
- The transfer script now re-reads each object's new owner after sending (F41d).

### F3 — Upgrade authority: testnet UpgradeCap live with the publisher EOA

**Severity:** Low   **Disposition:** DEFERRED (mainnet-blocked: policy decided 2026-10-01 — OQ1;
execution is the maintainer's `OPERATOR_TASKS.md` item "Mainnet release custody"; testnet timing OQ21)
**Where:** `Published.toml` `upgrade-capability = 0x7d63f623…ddf92`; `deployments.json`
`custody.upgradeCapOwner = 0xa991…864a`, `plannedBurnDate: null`; on-chain the cap is `AddressOwner`
`0xa991…864a` (2026-10-09).

**Issue / Impact:** Until it is moved and burned, one key can replace the logic under every live gate
and pass. Together with `migrate` it can also force every caller onto the new code.

**Remediation / evidence:** Each full release follows `CUSTODY.md`:

1. publish;
2. transfer with `--include-upgrade-cap` (separate `UPGRADECAP` confirmation);
3. set `plannedBurnDate`;
4. verify;
5. a multisig-signed `make_immutable` via `make-immutable.sh`, which writes the unsigned transaction
   and checks the cap's type and package.

The lifecycle was rehearsed on localnet on 2026-10-01 per `CUSTODY.md`; this pass did not re-run it. The
transfer and burn scripts gained post-checks in `7b75da3` (F41). The superseded caps, including
`0x70be984f…e0ba` of `0xa55789…`, are burned (F31).

### F4 — `commission_bps` still applies to a frozen gate

**Severity:** Low/Info   **Disposition:** RESOLVED (configurable per gate — F24; OQ4 decided)
**Where:** `make_gate_immutable` (`:883-903`), `effective_commission_terms` (`:702-706`).

With `lock_commission_on_freeze`, the freeze snapshots the full `CommissionTerms` (bps **and** floor).
Tests: `test_lock_commission_on_freeze_uses_snapshot`,
`test_frozen_gate_without_lock_follows_live_commission`, `test_locked_terms_keep_the_floor`
(pass at `83dbf25`).

### F5 — `airdrop` blocked by freeze while `purchase` continues

**Severity:** Info   **Disposition:** ADJUDICATED — intentional; `test_airdrop_on_frozen_gate_aborts`.

### F6 — Abort-code uniqueness and arithmetic

**Severity:** Positive

- Codes **1–16** are distinct within `access_gate` (map in C.1; 15 and 16 are new in 0.0.6, F35/F36).
- After F10 no reachable product overflows: `commission_for_price` (`:715`) and `min_paid_price_mist`
  (`:727`) are in u128, and the latter saturates at `u64::MAX`.
- `operator_share = price − commission` cannot underflow (commission ≤ 10% of price).
- Codes repeat across packages (`seal_policies` `config` uses 1–2, `sealed_content` 1–3,
  `nft_gate` 4), so clients key on `(module, code)`.

### F7 — Emit-before-delete ordering

**Severity:** Positive

`consume` (`:751-771`), `consume_soulbound` (`:774-794`), `burn*` (`:832-856`) and
`make_gate_immutable` (`:883-903`) capture the ID, emit, then delete. The soulbound auto-burn branch is
now tested too (F37): `test_soulbound_auto_burn_consume_to_zero_emits_burn_and_deletes`.

### F8 — Soulbound non-transferability is structural

**Severity:** Positive — `SoulboundAccessNFT has key` (no `store`) (`:259`).

### F9 — Capability provenance

**Severity:** Positive — `AdminCap` is minted only in `share_new_gate` (`:541`, reached from
`create_gate` / `create_free_gate`). `PlatformAdminCap` is minted only in `init`. Test constructors are
`#[test_only]`.

### F10 — Commission product overflowed u64 at extreme prices

**Severity:** Medium   **Disposition:** RESOLVED (live since `0x1a81ca…`; current in `0xd7ddaa94…`)
**Where:** `commission_for_price` (`:715-723`).

Computed in u128 and floored. Tests: `test_purchase_max_price_max_commission_does_not_overflow`,
`test_commission_for_price_formula`. Residual: the immutable superseded `0x0bedd0…` keeps the u64 form
for gates still on it.

### F11 — Platform treasury could be set to the zero address

**Severity:** Low   **Disposition:** RESOLVED
**Where:** `set_platform_treasury` (`:1031`, assert at `:1037`), `E_ZERO_ADDRESS = 9`.

Tests: `test_set_platform_treasury_zero_address_aborts`. The equivalent check for a gate's
`payment_recipient` is still OQ12.

### F12 — Custody-transfer tooling non-functional and unsafe

**Severity:** Medium   **Disposition:** RESOLVED (re-verified 2026-10-03)
**Where:** `scripts/transfer-platform-authority.sh`.

The script now:

- uses IDs recorded by `publish.sh`;
- re-reads each object and checks the exact long-form type, the package (for `Publisher`/`UpgradeCap`)
  and that the active address owns it;
- rejects unknown flags;
- runs the shared preflight;
- defaults to dry run, with `YES` + `UPGRADECAP`.

shellcheck is clean (CI; `9defe35`). The residual gaps recorded on 2026-10-03 (F40/F41) were closed in
`7b75da3`: the script now also re-reads each object's new owner after sending and refuses to continue on a
mismatch, reads the IDs from the committed `authorityObjects`, and checks `EXPECTED_SIGNER`.

### F13 — `publish.sh` defects

**Severity:** Low   **Disposition:** RESOLVED (re-verified 2026-10-09)

The script now has:

- `log` defined before the trap;
- unknown flags rejected;
- network validated;
- exact-type `objectChanges` extraction (`created_id`);
- previous records backed up;
- preflight (env, chain id, CLI major.minor, `EXPECTED_SIGNER`, balance ≥ `GAS_BUDGET` — F41);
- `--replace-published` required to republish over a record (used for the 2026-10-09 republish).

### F14 — Package address drift

**Severity:** Low   **Disposition:** RESOLVED (re-verified 2026-10-09; canonical now `0xd7ddaa94…`)

`Move.toml` carries no `published-at`, and its comment lists the current, superseded and stray IDs.
`Published.toml` records `0xd7ddaa94…88c9` (chain-id `4c78adac`, toolchain 1.81.0). Every consumer agrees
(B.SC-1):

- `SECURITY.md` and `docs/onchain/*` (`83dbf25`);
- access-gate-client `deployments` (generated from 0.0.6);
- `sealed-storage-sui` (pins `7906954`);
- nft-gate `NFT_TYPE` and `GATE_ID`.

The OQ7 decision (2026-09-28, `0x0bedd0…` canonical) was superseded by the 2026-10-02 republish
(`0xa55789…`) and again by the 2026-10-09 one (`0xd7ddaa94…`).

### F15 — Mutable release tags

**Severity:** Low   **Disposition:** MITIGATED (dependants pin commit SHAs) — OQ8

Re-verified 2026-10-09. Tags `v0.0.1`–`v0.0.6` exist, in chronological order (`v0.0.5` → `b445876`;
`v0.0.6` → `83dbf25`, the commit that points the docs at the 0.0.6 publication). Tags remain mutable: no
tag protection is evidenced (the review token cannot read the repository's rulesets, so the setting is a
maintainer item). `sealed-storage-sui` pins the SHA (`790695489fc4`).

### F16 — `SECURITY.md` claimed the UpgradeCap is burned on publish

**Severity:** Low   **Disposition:** RESOLVED

`SECURITY.md` states the live testnet cap `0x7d63f623…ddf92` and the custody process (`83dbf25`); the
superseded caps are listed as burned. The content drift recorded in F39 is closed.

### F17 — Documentation drift (first pass)

**Severity:** Info   **Disposition:** RESOLVED (first-pass items). The later drift (F38, F39, F43) is
resolved too.

### F18 — `auto_burn_at_zero` is read at consume time

**Severity:** Low   **Disposition:** ADJUDICATED (documented + `test_auto_burn_change_applies_to_existing_nfts`;
OQ9 remains a maintainer choice; behaviour unchanged at `83dbf25`).

### F19 — Freezing a paused gate disables purchase forever

**Severity:** Low   **Disposition:** RESOLVED (configurable per gate — F24; OQ5 decided)

`freeze_requires_unpaused` → `E_FREEZE_WHILE_PAUSED = 10` (`:891`). The interaction with
`pause_blocks_access` and `pause_blocks_decryption` is now closed by `E_POLICY_COMBINATION` (F36).

### F20 — Setters emit no events

**Severity:** Info   **Disposition:** ACCEPTED-RISK (gate setters); partly superseded (confirmed ACCEPTED 2026-10-22)

Platform setters now emit `PlatformConfigUpdatedEvent`, `migrate` emits `PlatformMigratedEvent`, and
`make_gate_free` emits `GateMadeFreeEvent`. The gate setters (price, recipient, pause, uses,
auto-burn, display) remain silent. Suggestion S1; the reasons that made this matter for verifiers (F35)
are gone now that the pass kind cannot change.

### F21 — Licence inconsistency

**Severity:** Info   **Disposition:** RESOLVED (OQ10 decided: 0BSD)

The source and test SPDX headers, `LICENSE`, `Move.toml` and `package.json` all say 0BSD.

### F22 — `init` defaults verified

**Severity:** Positive

- `PlatformConfig { version: 1, treasury: publisher, commission_bps: 20, min_commission_mist: 1_000_000,
  free_gate_fee_mist: 100_000_000 }` is shared (the published 0.0.6 source; the live testnet object still
  holds these values).
- From 0.0.7 (2026-10-19, OQ16) the source defaults are `min_commission_mist: 500_000` and
  `free_gate_fee_mist: 1_000_000_000`, taken from the workspace cost model; they take effect only at the
  mainnet publish. `test_init_creates_platform_objects` pins them.
- `PlatformAdminCap`, `Publisher` and both `Display`s go to the publisher.
- Tests: `test_init_creates_platform_objects`, `test_init_and_test_configs_start_at_the_package_version`.

### F23 — docs/dev sites import the on-chain docs only after npm publication

**Severity:** Info   **Disposition:** RESOLVED (`@meddleware/access-gate-sui` 0.0.2 → 0.0.6 published)

### F24 — Gate policies

**Severity:** Info (design)   **Disposition:** RESOLVED

`GatePolicy { freeze_requires_unpaused, lock_commission_on_freeze, pause_blocks_decryption,
pause_blocks_access }` is immutable per gate, set through `new_gate_policy` / `default_gate_policy`
and stored on `Gate` with `locked_commission: Option<CommissionTerms>`. Tests are in the F24/F29
sets. Unsafe policy combinations are refused at creation (F36, `E_POLICY_COMBINATION`).

### F25 — Dust prices pay no commission

**Severity:** Info   **Disposition:** RESOLVED (superseded by F26).

### F26 — Commission floor and minimum paid price (on-chain)

**Severity:** Medium (revenue integrity)   **Disposition:** RESOLVED

The commission is `max(⌊price × bps / 10000⌋, min_commission)`, capped at 10%, and a paid price must
be ≥ `min_paid_price_mist` (10 × the floor). Tests: the F26 set (`test_min_commission_applies_to_cheap_purchases`
… `test_platform_fee_setters_update`). The setter's lack of an upper bound is F42.

### F27 — Free gates pay a one-off fee that no price change avoids

**Severity:** Medium (revenue integrity)   **Disposition:** RESOLVED

`create_free_gate` / `make_gate_free` charge it once (`free_fee_paid`), and `set_price(0)` aborts with
12 until it is paid. Tests: the F27 set.

### F28 — Airdrops could replace sales and bypass the commission

**Severity:** Medium (revenue integrity)   **Disposition:** RESOLVED

`airdrop` pays `gate_commission_mist` (`:626-641`), and `AccessMintedEvent.commission_mist` records it.
Tests: `test_airdrop_pays_commission_on_paid_gate`, `test_airdrop_underpaid_commission_aborts`.

### F29 — `pause_blocks_access`

**Severity:** Info (design)   **Disposition:** RESOLVED

While a gate with `pause_blocks_access` is paused, `consume*` aborts with `E_PAUSED` (`:807`), and
the gateways deny holders. Tests: `test_pause_blocks_access_stops_consume`,
`test_pause_without_access_policy_allows_consume`.

### F30 — A gateway could gate on a fungible token or foreign NFT

**Severity:** Low   **Disposition:** RESOLVED in nft-gate

Both gateways accept only `<pkg>::access_gate::(Soulbound)AccessNFT` and require `GATE_ID`. This was
re-verified in the nft-gate audits (2026-10-03); `wrangler.toml` now names
`0xd7ddaa94…::access_gate::SoulboundAccessNFT` and gate `0x316f1bf9…` (2026-10-09).

### F31 — Republish and UpgradeCap burns

**Severity:** Info   **Disposition:** RESOLVED (owner-authorised)

- 2026-09-28: the stray caps and the `0x0bedd0…` cap were burned.
- **2026-10-02:** `0x1a81ca…`'s cap `0xf04a1d87…32bc` was burned after the version-gated publish
  `0xa55789…`, per `SECURITY.md` and commit `32597c9` ("superseded caps burned").
- **2026-10-09:** `0xa55789…`'s cap `0x70be984f…e0ba` was burned after the 0.0.6 republish
  `0xd7ddaa94…`. Read on-chain this pass: the cap object no longer exists (a package object always
  reads `Immutable`, so the missing cap is the evidence). The same read confirms `0xd7ddaa94…`'s own cap `0x7d63f623…` is live with the EOA.

The 2026-10-02 cap `0xf04a1d87…32bc` was re-read on 2026-10-09 and no longer exists; the 2026-09-28 burns
are taken from `SECURITY.md` and the dated earlier passes (not re-read).

### F32 — Version gating (D22)

**Severity:** Info (design)   **Disposition:** RESOLVED (`120a407`; live in `0xd7ddaa94…`, `PlatformConfig.version` = 1 read on-chain 2026-10-09)
**Where:**

- `PlatformConfig.version` (`:183`)
- `VERSION = 1` (`:170`)
- `check_version` (`:434-436`), called first in every state-changing, minting or consuming function
  (20 call sites)
- `migrate` (`:441-446`; `&PlatformAdminCap`, forward only, `E_NOT_UPGRADE = 14`, emits
  `PlatformMigratedEvent`)

Views and holder burns are ungated by design, so dependants such as `seal_policies` and holders keep
working.

**Issue addressed:** Old package versions stay callable forever. Without a gate, a fix shipped in an
upgrade could be bypassed by calling the old `published-at`.

**Evidence:**

- 20 `test_wrong_version_blocks_*` tests, one per gated entry point (21 before `set_soulbound` was removed).
- `test_migrate_moves_an_older_config_forward`, `test_migrate_at_current_version_aborts`,
  `test_migrate_never_moves_backwards`, `test_init_and_test_configs_start_at_the_package_version`.

**Notes:**

- `migrate` is a `PlatformAdminCap` power, which increases the weight of F2.
- The gate applies within one upgrade lineage; a fresh publish (new original-id) has its own
  `PlatformConfig`.
- `SECURITY.md`'s integrator advice now says which applies (F39, resolved).

### F33 — Custody lifecycle and tooling

**Severity:** Info (process)   **Disposition:** RESOLVED (process + tooling; execution is F2/F3)
**Where:**

- `CUSTODY.md`
- `scripts/make-immutable.sh` (direct or multisig; dry run by default; cap type, package and owner
  checks; direct path verifies the cap is consumed and records the burn only for the current
  publication's cap)
- `scripts/multisig-address.sh` (threshold validated)
- `transfer-platform-authority.sh` (`UPGRADECAP` confirmation; records the custody owner)
- `deployments.json` `custody`

**Evidence:**

- Decision 2026-10-01 (OQ1/OQ2): transfer, verify, then a multisig burn on a planned date.
- Localnet rehearsal 2026-10-01, per `CUSTODY.md` (not re-run here).
- 0.0.6 (`7b75da3`): `transfer-platform-authority.sh` re-reads every object's owner after sending and
  fails if it is not the multisig; `publish.sh` and the transfer script check `EXPECTED_SIGNER` (`make-immutable.sh` checks that the active
  address owns the cap); the IDs come from the
  committed `authorityObjects`.
- shellcheck clean (CI).

### F34 — The package's verifier contract contradicts the deployed verifiers

**Severity:** Medium   **Disposition:** RESOLVED (`7b75da3`, 0.0.6; decision OQ17: digest-first
redemption is canonical; shared with nft-gate `gateway-rust-audit.md` / `gateway-workers-audit.md` F23
and F1)
**Where:** as of 2026-10-03 this package stated, in six places, that a verifier MUST bind the
server-issued challenge `nonce` (and `nft_id`) carried by `AccessConsumedEvent`:

- module doc `sources/access_gate.move:23-30` ("The server then binds one grant to one on-chain
  consumption by matching that nonce — replay-proof");
- `SECURITY.md` "It does not cover" (`(gate_id, nft_id, consumer, server-issued nonce, consume tx
  digest)`);
- `docs/onchain/dev-guide.md` rule 2 ("accept a consumption only if its event carries **that**
  nonce…");
- `docs/onchain/api-reference.md` event table ("verifiers MUST check `nonce`, `gate_id`, `consumer`");
- `CLAUDE.md` invariant 2;
- B.5 of the previous audit.

Both access-gate gateways, the only verifiers in the workspace and the live relay paywall, deliberately
**do not** bind the nonce or `nft_id`.

- They verify the consume transaction digest-first: exact event type, `sender` = signer, `gate_id`.
- They enforce single use with a redemption store keyed by the digest (lease, then commit or release).
- This lets an interrupted upload resume with a fresh challenge.

**Impact:**

- Integrators following this package's normative docs build a different protocol from the reference
  gateways.
- The documented MUST is not met by the deployment that earns the platform's revenue.
- The gateways' choice, any fresh signature from the consumer redeeming any of that consumer's unspent
  consumes, is the precondition of the phishing-relay variant in nft-gate F1.

**Remediation / evidence:** Decided: option (a), keep the gateways' digest-first redemption (OQ17). The
six statements were rewritten in `7b75da3` to say that the digest plus the event `sender`/`consumer` plus
`gate_id` is the binding, that single use is enforced by a redemption store keyed on the digest, that the
signed message names the verifier's own audience and the digest (nft-gate access message v2), and that the
event `nonce` is optional:

- module doc `sources/access_gate.move:23-34`;
- `SECURITY.md` "It does not cover" (digest-first binding, bounded consumption age);
- `docs/onchain/dev-guide.md` rule 2;
- `docs/onchain/api-reference.md` event row;
- `CLAUDE.md` invariant 2 (and the deferred `dev.` composition note);
- B.5 below, which now records one protocol instead of two.

`README.md` and `docs/onchain/overview.md` were aligned in the same commit. Live evidence (workspace
record, 2026-10-09): the operator-relay paywall e2e passes against the live dashboard (a pass bought on
gate `0x316f1bf9…`, consumed, `nft-gate:access:v2` proof, upload through the Worker; indexer
minted=1 consumed=1). No on-chain change was needed, so the contract bytecode is unaffected.

### F35 — `set_soulbound` / `set_default_uses` change what new passes are, under verifiers pinned to one type

**Severity:** Low   **Disposition:** RESOLVED (`7b75da3`, 0.0.6; decision OQ18: the pass kind is fixed at
creation)
**Where:** as of 2026-10-03 `set_soulbound` and `set_default_uses`; now `set_default_uses`
(`:966-977`) and `mint_and_transfer` (`:656-694`).

**Issue:** An `AdminCap` holder can switch a live gate:

- from soulbound to transferable, which changes the minted type from `SoulboundAccessNFT` to
  `AccessNFT`;
- from N uses to 0, so new mints are `UnlimitedPass`.

The gateways are configured with one `NFT_TYPE`, and the live relay runs `SINGLE_USE=true` (consume
required). After such a switch:

- purchases still succeed and pay;
- the new passes are of a type the gateway does not accept, or a variant that cannot be consumed
  (`E_NOT_SINGLE_USE`);
- buyers are denied access.

**Impact:** Buyers lose the price paid, through an admin action that nothing on-chain or in the
gateways flags. The gate's existing passes are unaffected. Seal's `nft_gate` has entry points for both
types and is unaffected.

**Remediation / evidence:** Decided and applied (OQ18): the soulbound flag and the kind of pass
(unlimited or single-use) are immutable after creation, as `GatePolicy` is.

- `set_soulbound` is removed (no occurrence in `sources/`, `tests/` or the docs).
- `set_default_uses` asserts `(default_uses == 0) == (gate.default_uses == 0)` and aborts with the new
  `E_USES_KIND_IMMUTABLE = 16` (`:974`); only the count of a single-use gate can change.
- Tests: `test_set_default_uses_cannot_turn_unlimited_into_single_use`,
  `test_set_default_uses_cannot_turn_single_use_into_unlimited` (both abort 16),
  `test_set_default_uses_may_change_the_count`, `test_set_default_uses_keeps_unlimited_unlimited`.
- Docs aligned: README, api-reference, `SECURITY.md`, `CLAUDE.md` invariant 7.
- Live: the relay gate `0x316f1bf9…` is soulbound with 10 uses and cannot become anything else.

Residual (adjudicated): the use count of a single-use gate can still change for future mints. Every such
pass is the same type and variant, so a `SINGLE_USE` gateway accepts it.

### F36 — A paused gate frozen with `pause_blocks_access` or `pause_blocks_decryption` permanently disables sold passes

**Severity:** Low   **Disposition:** RESOLVED (`7b75da3`, 0.0.6; decision OQ19: refuse the combination at
creation)
**Where:** `new_gate_policy` (`:471-489`; no combination rules on 2026-10-03), `make_gate_immutable`
(`:891`), `consume_data` (`:807`); `seal_policies::nft_gate` (pause blocks decryption).

**Issue:** F19 made "freezing a paused gate" configurable for **purchases**. With
`pause_blocks_access = true` and `freeze_requires_unpaused = false`, the admin can pause and freeze:

- the gate can never be unpaused;
- every already-sold single-use pass can never be consumed again;
- with `pause_blocks_decryption`, every sealed item gated on it can never be decrypted.

**Impact:** Holders' paid but unused entitlements are destroyed by one admin action. The policy is
visible on-chain, so an attentive buyer could see the combination. The access-gate-ui defaults (all
`false`) do not produce it.

**Remediation / evidence:** `new_gate_policy` (and so `create_gate` / `create_free_gate`) now asserts
`freeze_requires_unpaused || !(pause_blocks_decryption || pause_blocks_access)` and aborts with the new
`E_POLICY_COMBINATION = 15` (`:477-480`). With the guard, a gate whose pause blocks access or decryption
can never be frozen while paused, so the admin can always unpause it.

- Tests: `test_policy_pause_blocks_access_without_freeze_guard_aborts`,
  `test_policy_pause_blocks_decryption_without_freeze_guard_aborts` (both abort 15),
  `test_policy_combinations_that_are_allowed`.
- Docs aligned: api-reference code 15, `SECURITY.md`, `CLAUDE.md` invariant 7.
- The live relay gate's policy is all `false` (read on-chain), so it was never exposed.

Residual (adjudicated): an admin can still pause an unfrozen gate and leave it paused. That is
reversible by the same admin and is the ordinary `AdminCap` trust (F5, B.4).

### F37 — Coverage gaps on paths other packages and the live relay rely on

**Severity:** Low   **Disposition:** RESOLVED (`7b75da3`, 0.0.6; 94 tests, 100.00% module coverage,
2026-10-09)
**Where:** `tests/access_gate_tests.move`; coverage was 92.70% on 2026-10-03.

**Issue (2026-10-03):** Lines never executed, or exercised only by aborting tests:

- the `consume_soulbound` auto-burn branch: no test created a soulbound gate with
  `auto_burn_at_zero = true`, so that branch's emit-before-delete (F7) was unproven;
- `is_valid_for` / `is_valid_for_soulbound`, the API `seal_policies::nft_gate` depends on;
- the success paths of `set_nft_name`, `set_nft_image_url` and `set_nft_description`, covered only by
  `test_wrong_version_blocks_*`, which abort first;
- the copy of display fields into minted passes: every test gate uses empty strings;
- several views (`gate_id`, `gate_id_soulbound`, `gate_admin_cap_id`, `admin_cap_gate_id`,
  `gate_nft_*`, `policy_pause_blocks_access`, `terms_min_mist`).

**Impact:** A regression in a cross-package API or in the soulbound burn path, which the live relay
gate uses (soulbound, 10 uses), would pass CI.

**Remediation / evidence:** Added in `7b75da3`:

- `test_soulbound_auto_burn_consume_to_zero_emits_burn_and_deletes` (asserts `AccessBurnedEvent` and
  deletion);
- `test_is_valid_for_is_true_only_for_the_passes_own_gate` (true/false across two gates, both pass types);
- `test_display_setters_and_views` (the setters, the views, and the display copy into the next minted
  pass).

`sui move test --coverage` on a `git archive` of `83dbf25` reports 100.00% module coverage. The figure is
recorded in C.1.

### F38 — `docs/onchain/dev-guide.md` `consume` snippet omits the `PlatformConfig` argument

**Severity:** Low   **Disposition:** RESOLVED (`7b75da3`, 0.0.6; the snippet. A CI check of snippets
against the ABI stays a suggestion, S6)
**Where:** `docs/onchain/dev-guide.md:94-98` (2026-10-03) —
`arguments: [tx.object(NFT_ID), tx.object(GATE_ID), tx.pure.vector('u8', nonceBytes)]`. The signature
is `consume(nft, gate, platform, nonce, ctx)` (`:751-757`). This page is published to the dev site
(`manifest.json`).

**Issue / Impact:** Integrators copying the snippet build a transaction that fails argument
resolution. It is the one PTB example on the dev site that drifted when version gating added the
`platform` argument (the `purchase` and `create_gate` snippets are correct).

**Remediation / evidence:** The snippet now reads `[tx.object(NFT_ID), tx.object(GATE_ID),
tx.object(PLATFORM_CONFIG_ID), tx.pure.vector('u8', nonceBytes)]`, with a note that `PKG` must be the
latest `published-at` (from access-gate-client `deployments`) and the nonce at least 8 bytes. The drift
test that matters lives in access-gate-client (ABI-drift suite, passing against the new package on
2026-10-09). A docs-side snippet check is optional (S6).

### F39 — `SECURITY.md` and integrator guidance blur upgrades with fresh packages; scope omits the custody scripts

**Severity:** Info   **Disposition:** RESOLVED (`7b75da3`, 0.0.6)
**Where:** `SECURITY.md` "For integrators and gateway operators", Scope.

**Issue (2026-10-03):**

- "An NFT minted under v1 cannot be consumed by a v2 `consume` call. Route each consume transaction to
  the package version that minted the NFT" is true for a **fresh package** (new original-id). Within
  one upgrade lineage the NFT type is defined at the original-id, and after `migrate` the old
  `published-at` **aborts** (`E_WRONG_VERSION`), so callers must use the latest `published-at`.
- The Scope names only `scripts/publish.sh`, although `transfer-platform-authority.sh` and
  `make-immutable.sh` move and burn authority.

**Impact:** Integrators may route consumes to an old `published-at` after an upgrade, and their
transactions will abort.

**Remediation / evidence:** `SECURITY.md` now has two bullets, "Upgrade (same original id)": always call
the latest `published-at` from `Published.toml` / the client `deployments`; "Fresh package (new original
id)": route each consume to the package that minted the pass and subscribe to every original id you
trust. Its Scope names `publish.sh`, `transfer-platform-authority.sh`, `make-immutable.sh` and
`multisig-address.sh`. `docs/onchain/dev-guide.md` item 5 says the same.

### F40 — Authority object IDs are recorded only in git-ignored `.env.<network>`

**Severity:** Low   **Disposition:** RESOLVED (`7b75da3`, 0.0.6; recorded for the current publication)
**Where:** `publish.sh:203-213` (2026-10-03) wrote `ACCESS_GATE_{PUBLISHER,PLATFORM_ADMIN_CAP,DISPLAY_*}_ID` only
to `.env.<network>`. `deployments.json` holds `platformConfigId` and `custody`; `Published.toml` holds
the package and UpgradeCap. `transfer-platform-authority.sh` reads the authority IDs only from
`.env.<network>`.

**Issue:** The IDs that the pre-mainnet blocking transfer (F2) acts on exist only on the operator's
machine, and the record is not committed. Losing that file means rediscovering the objects by type,
which is the unsafe pattern F12 removed. OPS §A *Record-keeping* calls for the latest IDs to be written
consistently to the committed records.

**Impact:** A lost workstation turns the custody handoff into manual discovery, with the F12 risk.

**Remediation / evidence:**

- `publish.sh` now writes `authorityObjects { platformAdminCap, publisher, displayAccessNft,
  displaySoulboundNft, upgradeCap }` into `deployments.json` (`:236-250`); `--make-immutable` nulls
  `upgradeCap` after the burn is verified.
- `transfer-platform-authority.sh` prefers `authorityObjects` over `.env.<network>`.
- Testnet is recorded in `deployments.json` for the 2026-10-09 publication; the five IDs match the
  on-chain objects and their owner (read this pass). The 0.0.5 publication's IDs were not backfilled: its
  caps are burned or superseded and no longer need a handoff.

### F41 — OPS preflight and verification gaps

**Severity:** Low   **Disposition:** RESOLVED (a–d, `7b75da3`, 0.0.6; (e) ADJUDICATED)
**Where:** the scripts named below.

**Issue (2026-10-03):**

- **(a) No expected-signer check.** `publish.sh:127` only logs the signer. OPS §A *Preflight*
  requires the active address to be the expected one; an `EXPECTED_SIGNER` env var or
  `deployments.json` `custody.upgradeCapOwner` would serve. The transfer and burn scripts check
  object ownership against the active address, which covers them.
- **(b) No balance or gas sufficiency check** before signing, in any script.
- **(c) `publish.sh --make-immutable` does not verify the burn.** It removes the cap from `.env` and
  records `burnedAt` without checking that the UpgradeCap was consumed. `make-immutable.sh` does
  check (`:166-169`).
- **(d) Transfers are one transaction per object and are not checked afterwards.**
  `transfer-platform-authority.sh` sends one transaction per object, so it is non-atomic (recovery is
  documented), and ends with "Verify ownership on-chain" rather than checking it.
- **(e) Publish has no confirmation.** `publish.sh` publishes to testnet without a typed confirmation
  (mainnet has `MAINNET_CONFIRM=1`).

**Impact:** A wrong active key, an under-funded gas coin, or a failed burn recorded as done.

**Remediation / evidence:**

- **(a)** `publish.sh` and `transfer-platform-authority.sh` hard-fail when the active address differs from
  `EXPECTED_SIGNER` (addresses normalised to long form); mainnet requires `EXPECTED_SIGNER`.
  `make-immutable.sh` compares the active address with the cap's owner and otherwise writes an unsigned
  multisig transaction.
- **(b)** `publish.sh` reads `sui client gas --json` (coins plus address balance) and fails when the
  total is below `GAS_BUDGET`. The transfer and burn scripts do not: a short gas balance fails the
  transaction without changing state.
- **(c)** `publish.sh --make-immutable` re-reads the cap and refuses to record a burn while the object
  still exists.
- **(d)** The transfer script re-reads every object's owner after sending and exits non-zero on a
  mismatch, without recording the handoff. Still one transaction per object, so non-atomic; recovery is
  documented and the pre-send ownership check makes a re-run safe.
- **(e)** ADJUDICATED: a testnet publish yields new IDs and a record that `--replace-published` guards, so
  no typed confirmation is added. Mainnet is gated by `MAINNET_CONFIRM=1` and a required
  `EXPECTED_SIGNER`.

shellcheck 0.9 is clean (`9defe35`; CI). Not re-run in this sandbox.

### F42 — Platform floor and free-gate fee setters are unbounded

**Severity:** Info   **Disposition:** ADJUDICATED (platform-authority trust; pending OQ20)
**Where:** `set_min_commission_mist` (`:1042-1050`), `set_free_gate_fee_mist` (`:1053-1061`).

**Issue:**

- Only `commission_bps` is capped (≤ 1000).
- Raising `min_commission_mist` raises `min_paid_price_mist` (10×, saturating at `u64::MAX`), so the
  platform can block every new paid gate and every `set_price` re-price on every gate of the package.
- `free_gate_fee_mist` can be made prohibitive.
- The per-mint 10% cap still protects creators' existing sales.

**Impact:** The platform admin can halt the marketplace's growth or repricing without upgrading. This is
bounded by `PlatformAdminCap` custody (F2), and clients split exact amounts, so a fee raise between
preview and execution aborts rather than overcharging (access-gate-client `ptb.ts:52`).

**Remediation / evidence:** The trust assumption is now recorded in `SECURITY.md` ("Platform-authority
parameters": a multisig before mainnet, no on-chain ceilings, not a defect). Whether to add ceilings
instead stays with the maintainer (OQ20); the setters are unchanged at `83dbf25` (`:1056`, `:1067`).
The new defaults (OQ16, 0.0.7) do not change this: the setters stay unbounded, and the cost model's
re-pricing policy (`docs/economics/COST_MODEL.md` §2) is the documented basis for any future setter call.

### F43 — The stale audit was published in npm 0.0.5

**Severity:** Info   **Disposition:** RESOLVED (`7b75da3`, 0.0.6, published 2026-10-09)
**Where:** `package.json` `files` included `docs/`; the 0.0.5 tarball contains
`docs/audit/access-gate-sui-audit.md` (52 kB).

**Issue / Impact:** The published audit misstates:

- the canonical package (`0x0bedd0…`);
- the live caps;
- the relay gate;
- test counts and abort codes.

It also omits version gating. Readers of the npm package or its unpkg view get wrong security
information.

**Remediation / evidence:** 0.0.6 narrowed `files` to `docs/onchain/` (no `docs/audit/`): `npm pack
--dry-run` lists 15 files, 33.4 kB, with no audit, tests, scripts or env files. The audit is read in the
repository. Residual: 0.0.5 stays installable and carries the stale audit; it is not deprecated on the
registry. That text describes a package that is now immutable and superseded. Deprecating it
(`npm deprecate @meddleware/access-gate-sui@0.0.5 …`) is optional and needs the maintainer's npm login; the
same mechanism is described in `OPERATOR_TASKS.md` "npm housekeeping", which lists only the `0.0.0`
placeholders today (a maintainer item if wanted). Nothing depends on 0.0.5.

### F44 — CI supply-chain details

**Severity:** Info   **Disposition:** RESOLVED (`7b75da3`, 0.0.6)
**Where:** `move-ci.yml:20-47`, `npm-publish.yml` (2026-10-03: `:62-93`).

**Issue (2026-10-03):**

- suiup is sha256-pinned, but the sui release it downloads is not checksum-verified by the workflow.
- `npm-publish.yml` runs `type-check --if-present` and `build --if-present` for scripts that do not
  exist (noise).
- `npm audit` runs on an empty dependency tree (harmless).
- No CI step fails on `sui move build --lint` warnings (lint is clean today).

**Impact:** A compromised sui release asset would run in CI. CI holds no secrets except the npm OIDC
token in the publish job, which runs `sui move test` in a separate `verify` job before publishing.

**Remediation / evidence:**

- `move-ci.yml` checks the installed binary: `sha256sum -c` against `c86c0481…22f7f1`, which is the
  checksum of the `sui 1.81.0` binary used in this review.
- The `--if-present` no-ops are gone: `npm-publish.yml`'s `verify` job is now `uses: ./.github/workflows/move-ci.yml`.
- CI builds with `sui move build --build-env testnet --lint --warnings-are-errors` (clean here).

### F45 — Positive: script safety and record-keeping core

**Severity:** Positive

- `set -euo pipefail` everywhere; shellcheck-clean (in CI and re-run locally).
- Preflight hard-fails on active env, **chain identifier** and CLI major.minor.
- Mainnet double guard (`MAINNET_CONFIRM=1`); a skip exits 78 with "SKIPPED", never a pass.
- Separate typed confirmations per irreversible step (`BURN <prefix>`, `YES`, `UPGRADECAP`).
- Exact-type JSON parsing that aborts on missing IDs.
- Previous records kept (`.env.*.bak`, `Published.toml.*.bak`; both ignored by `.gitignore`).
- Recovery instructions printed after publish.
- The scripts never switch the operator's env.
- `deployments.json` and `Published.toml` drive the client `deployments` export (OPS-M6), and the
  consumer bump and seal-policies re-pin were done for `0xd7ddaa94…` (B.SC-1).
- Since 0.0.6: `EXPECTED_SIGNER`, a balance check, a verified burn and a post-transfer ownership check
  (F41), and committed authority IDs (F40).

### F46 — Positive: release chain

**Severity:** Positive

- Actions SHA-pinned; `permissions: contents: read`; `id-token: write` only on the publish job.
- Tag-gated (`v*`), with a tag == `package.json` version check.
- Idempotent publish.
- npm client pinned (`11.20.0`).
- OIDC `--provenance` (SLSA v1 attestation present on the registry for 0.0.5 and 0.0.6).
- The `files` whitelist excludes `tests/`, `scripts/`, `docs/audit/` and `.env*` (15 files).
- Move CI and shellcheck run on every push and PR, and the tag-triggered verify job is the same workflow
  (F47).

### F47 — Release gate equals CI, and automated dependency updates (base template 2026-10-08 rows)

**Severity:** Info   **Disposition:** RESOLVED (`7b75da3`, `a5ea133`; 0.0.6)
**Where:** `.github/workflows/npm-publish.yml`, `.github/workflows/move-ci.yml`, `.github/dependabot.yml`.

**Issue (2026-10-03 pass, against the then-current rows):** The tag-triggered `verify` job was a hand-copied
second pipeline (type-check, audit, `npm test`, build), so a tag could ship what branch CI would refuse. No
committed update configuration covered the npm lockfile or the pinned Action SHAs.

**Impact:** Drift between the two pipelines, and stale pins.

**Remediation / evidence:**

- `move-ci.yml` gained `workflow_call`; `npm-publish.yml`'s `verify` job is `uses:
  ./.github/workflows/move-ci.yml`, so the tagged commit runs the same Move build (lints as errors), Move
  tests and shellcheck as every push.
- `.github/dependabot.yml` (`a5ea133`): weekly, grouped updates for npm (minor/patch) and GitHub Actions.
  The Move framework pin (`Move.lock`) and the `sui` release are deliberate, reviewed moves (the scripts
  hard-fail on a toolchain mismatch).
- Real funds are manual and test-only modes are compiler-excluded (B.2 table).

### F48 — The 2026-10-09 republish orphans gates and passes on the superseded package

**Severity:** Info   **Disposition:** ACCEPTED-RISK (testnet only; pre-v0.2 policy prefers a fresh package
to compatibility shims; confirmed ACCEPTED 2026-10-22)
**Where:** `0xa55789…` (immutable) and its relay gate `0xfd6c3b…`; `access-gate-gateway/gateway-workers/wrangler.toml`
(`NFT_TYPE`, `GATE_ID`, `0xd7ddaa94…` / `0x316f1bf9…`).

**Issue:** Version gating applies within one upgrade lineage (F32). A fresh publish has a new original-id,
its own `PlatformConfig` and its own types, so gates and passes on `0xa55789…` cannot move. The live
gateway accepts only `0xd7ddaa94…::access_gate::SoulboundAccessNFT` on gate `0x316f1bf9…`.

**Impact:** Any pass bought on the old relay gate no longer opens the live relay, and any third-party
gate created on `0xa55789…` stays on frozen, ungated-by-upgrade code. No mainnet value is involved.

**Remediation / evidence:** Accepted: the republish was needed to ship the pass-kind and policy rules
(F35/F36), which cannot be added to a published struct layout's behaviour without new code under an
upgradeable cap, and the old cap was burned. For mainnet the lifecycle in `CUSTODY.md` keeps the
upgradeable window open for exactly this reason. The B.3 versioning guidance for integrators (subscribe to
every trusted original-id) still applies.

### F49 — `make-immutable.sh` refused the UpgradeCap of an upgraded package (found by the 2026-10-22 testnet rehearsal)

**Severity:** Low   **Disposition:** RESOLVED (0.0.8, commit pending: the script accepts a later version of the recorded package; `tests/scripts/make_immutable_test.sh`; `CUSTODY.md` upgrade steps)
**Where:** `scripts/make-immutable.sh` (the cap's package against the recorded `published-at`); `CUSTODY.md` "Upgrading during the verification window".

**Issue:** after an upgrade the `UpgradeCap` names the LATEST package. `CUSTODY.md` signs the upgrade as a multisig transaction
(`sui client upgrade --serialize-unsigned-transaction`), which the CLI does not record, so `Published.toml` still named the version this
checkout was published at, and the script stopped with "UpgradeCap … controls package `0x12d5…`, not access_gate `0x47fd…`" at the very
step the verification window exists for (the burn after an upgrade). Found on the testnet rehearsal below. A second trap, from the same
run: `sui client upgrade` on the pinned CLI 1.81.0 stops with `protocol version 139 is newer than the maximum version 138 supported by
this CLI` once the network's protocol version outgrows the CLI that published; a CLI of the current testnet line (1.82.2) built it.

**Impact:** the burn (and so the whole B.3 sequence) would have failed at a moment of the maintainer's choosing, on mainnet; fail-closed, no
funds at risk. The workaround was to hand-edit `Published.toml`, which `CUSTODY.md` did not say.

**Remediation / evidence:** the script accepts the cap when it names the recorded package or a later version of it: the package it names
must have its `ACCESS_GATE` one-time-witness type originate at the recorded `original-id` (read from the package's `type_origin_table`);
any other package is refused. `CUSTODY.md` now tells the operator to use the current CLI for the upgrade step and to record the new
`published-at` and `version` in `Published.toml`. Tests: `tests/scripts/make_immutable_test.sh` (5 cases, a stub `sui`; 4 of them fail
on the previous script), run with shellcheck in `move-ci.yml`. Real-chain proof: the rehearsal below, burn `Eui26pAVBmeicw9P9chig8eqzR1jrDHnPi7iewK1p1Zo`.

---

## Section A — Invariant verification matrix

| # | Invariant | Enforced / asserted at | Proven by | Status |
| --- | --- | --- | --- | --- |
| I1 | Purchase atomic, permissionless; price ≥; overpay refunded; commission + operator share routed | `access_gate.move::purchase` (`:600-624`) | `test_purchase_*`, `test_purchase_overpay_refunds_remainder`, `test_purchase_nonzero_commission_splits_payment` | HOLDS |
| I2 | **Ownership:** single use spent only by the holder (by-value NFT); decrement + event | `::consume`, `::consume_soulbound`, `::consume_data` (`:751-829`) | `test_single_use_consume_*`, `test_soulbound_mint_and_consume` | HOLDS |
| I3 | Replay: nonce ≥ 8 bytes, `consumer` recorded; uniqueness/freshness off-chain | `::consume_data:805` | `test_consume_short_nonce_aborts`, `test_consume_soulbound_short_nonce_aborts` | HOLDS (on-chain part); the verifier contract is digest-first and now documented as such (F34, resolved) |
| I4 | **Gating / isolation:** an NFT and a cap are bound to one gate | `::consume_data:806`, `::assert_admin:858-860` | `test_consume_wrong_gate_aborts`, `test_consume_soulbound_wrong_gate_aborts`, `test_setter_with_foreign_admin_cap_aborts` | HOLDS |
| I4b | `is_valid_for*` reports gate membership for dependants | `::is_valid_for*` (`:1103-1110`) | `test_is_valid_for_is_true_only_for_the_passes_own_gate` (F37), and `sealed-storage-sui` tests | HOLDS |
| I5 | Exhaustion policy per gate (`auto_burn_at_zero`, read at consume) | `::consume_data:809,821` | `test_single_use_auto_burn_*`, `test_auto_burn_change_applies_to_existing_nfts`, `test_soulbound_auto_burn_consume_to_zero_emits_burn_and_deletes` | HOLDS (both pass types; F37 resolved) |
| I6 | **Event ordering:** emit before delete | `::consume*`, `::burn*`, `::make_gate_immutable` | `test_burn_voluntary`, `test_burn_soulbound`, auto-burn tests (both pass types) | HOLDS |
| I7 | **Capability binding:** `AdminCap` non-forgeable, per gate | `::share_new_gate`, `::assert_admin` | `test_setter_with_foreign_admin_cap_aborts`, `test_admin_setters` | HOLDS |
| I8 | Frozen gate: no setter/airdrop; purchase/consume continue | `::assert_admin_mutable`, `::make_gate_immutable` | `test_make_gate_immutable_*`, `test_setter_on_frozen_gate_aborts`, `test_airdrop_on_frozen_gate_aborts` | HOLDS |
| I8b | **Policy:** `GatePolicy` immutable; `freeze_requires_unpaused` ⇒ no paused freeze; `pause_blocks_access` ⇒ no paused consume; locked terms the only terms after freeze | `::create_*`, `::make_gate_immutable:891`, `::consume_data:807`, `::new_gate_policy:477-480`, `::effective_commission_terms` | F24/F29 tests, `test_locked_terms_keep_the_floor`, `test_policy_*` (E15) | HOLDS — the combination hazard is refused at creation (F36, resolved) |
| I8c | Holders' sold entitlements cannot be destroyed by admin configuration; the pass kind cannot change under a verifier | `::new_gate_policy:477-480` (E15), `::set_default_uses:966-977` (E16); no `set_soulbound` | `test_policy_pause_blocks_access_without_freeze_guard_aborts`, `test_policy_pause_blocks_decryption_without_freeze_guard_aborts`, `test_set_default_uses_cannot_turn_*` | HOLDS (F35, F36 resolved in 0.0.6) |
| I9 | **Arithmetic:** commission ≤ 10%, no overflow/underflow, floor rounding, floor ≤ cap via min paid price | `::commission_for_price:715-723`, `::min_paid_price_mist:727-733`, `::set_commission_bps` | `test_purchase_max_price_max_commission_does_not_overflow`, `test_commission_for_price_formula`, `test_min_paid_price_is_ten_times_the_floor`, `test_commission_capped_at_ten_percent_after_floor_raise`, `test_set_commission_*` | HOLDS |
| I10 | **Abilities:** soulbound cannot be `public_transfer`'d | `SoulboundAccessNFT has key` | type system; `test_soulbound_mint_and_consume` | HOLDS |
| I11 | Upgrade authority under target custody / package immutable | `UpgradeCap` custody | records: the cap `0x7d63f623…` is live with the EOA (on-chain read 2026-10-09); the superseded caps `0x70be984f…` and `0xf04a1d87…` no longer exist | GAP — F3, DEFERRED (mainnet-blocked: `CUSTODY.md` process, `OPERATOR_TASKS.md` "Mainnet release custody") |
| I12 | **Funds routing:** payment = commission + operator share + refund; fees to treasury; treasury ≠ `@0x0` | `::purchase`, `::pay_to:643`, `::refund_or_destroy`, `::set_platform_treasury:1031` | split/refund tests, `test_create_free_gate_pays_fee_and_refunds_excess`, `test_set_platform_treasury_zero_address_aborts` | HOLDS (gate recipient ≠ `@0x0` is OQ12) |
| I13 | **Abort codes:** unique within the module; map published | constants `E_*` 1–16 (`:131-167`) | every code has an `expected_failure` test (C.1); map in `docs/onchain/api-reference.md` | HOLDS |
| I14 | Side-effect-freedom | — | no dry-run policy functions in this package (`seal_policies` holds them) | N/A |
| I15 | Identity / byte layout | — | no client-built bytes decoded (the nonce is opaque) | N/A |
| I16 | **Platform always paid:** paid price ≥ `min_paid_price_mist`; price 0 only after the fee; every paid mint pays `max(bps, floor)` ≤ 10% | `::create_gate:493` (price ≥ minimum), `::create_free_gate`, `::set_price:908-915`, `::make_gate_free`, `::airdrop`, `::commission_for_price` | F26–F28 tests | HOLDS |
| I17 | **Version gating:** every state-changing, minting or consuming function aborts under any version but `PlatformConfig.version`; `migrate` forward only, `PlatformAdminCap`-only | `::check_version:434-436` (20 call sites), `::migrate:441-446` | 20 `test_wrong_version_blocks_*`, 4 migrate/init tests | HOLDS |
| I18 | **OPS preflight:** env, chain id and CLI version hard-fail; mainnet double guard; expected signer; balance | scripts' `preflight` | shellcheck (CI); localnet runs (2026-09-28/30, 2026-10-01); the 2026-10-09 testnet republish ran through it | HOLDS (signer and balance checks added in `7b75da3`, F41) |
| I19 | **OPS irreversible ops:** dry run by default, separate typed confirmation each | `transfer-platform-authority.sh`, `make-immutable.sh`, `publish.sh --make-immutable` | shellcheck (CI); localnet rehearsal (2026-10-01); the 2026-10-09 burn of `0x70be984f…` is confirmed on-chain | HOLDS (the publish-side burn is verified after the fact — F41c) |
| I20 | **OPS record-keeping:** latest original-id/published-at, `PlatformConfig` and custody committed; consumers bumped; Move dependants re-pinned | `Published.toml`, `deployments.json`, access-gate-client `gen-deployments`, seal-policies `Move.toml` | B.SC-1 trace 2026-10-09 | HOLDS (package, config and authority object IDs committed — F40) |
| I21 | `SECURITY.md` and the published docs match the code | `SECURITY.md`, `docs/onchain/*` | review at `83dbf25`; access-gate-client ABI-drift suite passes against the new package | HOLDS (F34, F38, F39, F43 resolved) |

---

## Section B — Supply-chain, publish-authority & capability matrix

### B.1 Dependency, liveness & coupling

| Dependency | Exact object ID / rev / version | Fails open or closed? | Paths it can block | Notes |
| --- | --- | --- | --- | --- |
| Sui framework / MoveStdlib | `b0535f1f3a3310e71790e90d8ae4e8ca840c897e` (`Move.lock`, testnet + localnet) | n/a | build only | the only Move dependency; moving it is deliberate (`Move.lock` committed) |
| Sui network (fullnodes) | — | closed (no tx) | purchase, consume, admin | chain liveness only |
| Off-chain verifier (nft-gate) | gateways 0.0.21 tag (+ `main`; the Worker was redeployed from `main` 2026-10-09) | closed (no grant) | access to the relay | integrator-operated; digest-first contract documented (F34, resolved) |
| Sui CLI | 1.81.0 (CI via suiup 0.0.14, sha256 `c0b9fea9…`; scripts check major.minor against `Published.toml`) | closed (preflight aborts) | publish, custody | F44 |
| `jq` | unpinned (system) | closed (scripts require it) | publish, custody | — |
| npm toolchain (publish only) | `npm@11.20.0`; no dependencies (`package-lock.json` empty) | — | npm release | `npm audit` 0 |

**Wire / format coupling**

| Format | Exact layout | On-chain | Off-chain | Conformance |
| --- | --- | --- | --- | --- |
| `AccessConsumedEvent` | `{nft_id: ID, gate_id: ID, nonce: vector<u8>, consumer: address, uses_after: u64, timestamp_ms: u64}` at `<original-id>::access_gate::AccessConsumedEvent` | `consume_data` | access-gate gateways (exact type, `sender`, `gate_id` — F34); access-gate-client `events.ts` (BCS layout) | gateways: env-gated live test (`live_consume_tx_valid`, `GRPC_TESTNET=1`; the Rust one still targets the immutable superseded `0xa55789…`/`0xfd6c3b…`, by design); access-gate-client: BCS decode tests and an ABI-drift integration test (passes against `0xd7ddaa94…`, 2026-10-09) |
| `Gate` object JSON (`paused`, `policy.pause_blocks_access`, `soulbound`, `default_uses`) | struct `Gate` (`:254-288`) | — | gateways' pause read (nft-gate F15); access-gate-client `gates.ts` | gateway unit fixtures; client tests |
| `AccessNFT` / `SoulboundAccessNFT` `data.{gate_id, variant}` | `AccessData` (`:223-229`), enum `AccessVariant` | — | access-gate-client `ownership.ts` (`ownsAccessNft` — no uses filter, nft-gate F7); seal-policies via `is_valid_for*` | client tests; seal-policies Move tests |
| Access-proof message | `nft-gate:access:v2` (audience-bound, digest-first consume) | — (off-chain only) | access-gate-gateway-client, gateways | vectors published by access-gate-gateway-client and asserted by both gateways (nft-gate audits) |
| Event and entry ABIs (all) | this module | — | access-gate-client builders + BCS layouts; both gateways | access-gate-client ABI-drift test against the recorded `published-at` (per its `CLAUDE.md`) |

### B.2 Publish authority, capabilities & secret custody

| Authority / capability / secret | Where minted / held | Custody | Gates | Rotation plan |
| --- | --- | --- | --- | --- |
| npm publish `@meddleware/access-gate-sui` | CI (`npm-publish.yml`, OIDC) | GitHub OIDC → npm | source/docs/record releases consumed by sites and access-gate-client | n/a (no secret) |
| Operator deploy key (`0xa991…`) | local keystore | operator | every publish; currently all authority objects | to be emptied of authority by the `CUSTODY.md` transfer (F2/F3) |
| Multisig | to be derived (`multisig-address.sh`) | members' keystores | platform authority + UpgradeCap (planned) | replace by creating a new multisig and transferring (`CUSTODY.md`) |
| `UpgradeCap`, `PlatformAdminCap`, `Publisher`, `Display×2` | see B.3 / capability matrix | — | — | — |

#### CI & release integrity

| Item | Holds? | Evidence |
| --- | --- | --- |
| Actions pinned | Yes | `actions/checkout@3d3c42e5…`, `actions/setup-node@82076278…` |
| Least privilege | Yes | `permissions: contents: read`; `id-token: write` only in `publish-npm` |
| OIDC trusted publishing | Yes | `npm publish --provenance`; attestation present for 0.0.5 and 0.0.6 |
| Update automation | Yes | `.github/dependabot.yml` (`a5ea133`): weekly, grouped (F47) |
| Tag-gated, idempotent publish | Yes | `v*` tags; tag/version check; registry probe + conflict tolerance |
| Container images | N/A | none |
| Secrets never echoed | Yes | no secrets used |
| Real funds are manual | Yes | no workflow signs on a chain; scripts are operator-run, mainnet double-guarded |
| Test-only modes | Yes | `#[test_only]` helpers are excluded from published bytecode by the compiler |

### B.3 `UpgradeCap` custody & immutability policy

| Network | Package ID | `UpgradeCap` ID | Status | Intended policy | Tooling |
| --- | --- | --- | --- | --- | --- |
| testnet (current) | `0xd7ddaa94…88c9` | `0x7d63f623…ddf92` | **held** by the publisher EOA `0xa991…864a` (`deployments.json`; on-chain read 2026-10-09) | `CUSTODY.md`: multisig → verification window → multisig burn on `plannedBurnDate` (not set) — pre-mainnet process, `OPERATOR_TASKS.md` "Mainnet release custody" (F2/F3, OQ21) | `transfer-platform-authority.sh --include-upgrade-cap` (dry run, `YES` + `UPGRADECAP`); `make-immutable.sh` (dry run; direct `YES` or unsigned multisig transaction) |
| testnet | `0xa55789…6d41` (superseded, 0.0.5) | `0x70be984f…e0ba` | **burned** 2026-10-09 (object gone, read on-chain) | — | — |
| testnet | `0x1a81ca…eea4` | `0xf04a1d87…32bc` | **burned** 2026-10-02 (object gone, read on-chain 2026-10-09) | — | — |
| testnet | `0x0bedd0…d20d` | `0x1ab9a455…` | **burned** 2026-09-28 | — | — |
| testnet | strays `0x692547…`, `0x891cc2…`, `0xbd2b4f…` | `0x6b6cd7…`, `0xb0c90e…`, `0xe81b451c…` | **burned** 2026-09-28 | — | — |
| mainnet | — | — | unpublished | `CUSTODY.md` lifecycle, then burn — **blocking** (Section D) | as above; `MAINNET_CONFIRM=1` |

**Versioning to integrators:**

- Within the verification window an upgrade keeps the original-id. Call the latest `published-at`;
  after `migrate`, older versions abort (F32).
- After the burn, protocol changes ship as a fresh package with a new original-id, and verifiers
  subscribe to every trusted original-id.
- `SECURITY.md` must state both cases (F39).

### B.4 Permissionless & griefing surfaces

| Function | Attacker controls | Confidentiality | Discoverability / UX | Gas / state growth | Mitigation |
| --- | --- | --- | --- | --- | --- |
| `create_gate` | every gate field incl. display strings (unbounded) and policy | none | look-alike gates; phishing names and images in wallets | one shared object per call, paid by the attacker; price ≥ the minimum makes nothing free | UIs list gates by `AdminCap` ownership or curated IDs; never trust `nft_name`/`nft_image_url` |
| `create_free_gate` | same, plus pays the free-gate fee (default 1 SUI from 0.0.7; 0.1 SUI on the live testnet object) | none | as above; free passes airdroppable without commission | fee per gate | fee (F27) |
| `purchase` | payment coin size | none | — | one NFT per call, paid by the buyer | clients split the exact price (access-gate-client); no on-chain price ceiling (F42 note) |
| `consume*` / `burn*` | own NFTs; nonce bytes (≥ 8, unbounded) | none | spam `AccessConsumedEvent`s for own passes | events paid by the caller | verifiers bind digest + sender + gate (F34); S2 nonce cap |
| Views | — | none | — | — | — |

### B.5 Replay protection & event semantics

**On-chain:** nonce length ≥ 8; `consumer = tx sender`; no nonce uniqueness or freshness; the NFT is
spent by value (owner only); `check_version` applies.

**Documented verifier contract (this package, one protocol since `7b75da3` — F34 / OQ17, decided
digest-first):** the verifier fetches the consume transaction by digest, requires a finalised
transaction, an event of the exact type `<original-id>::access_gate::AccessConsumedEvent` whose `consumer`
equals the signer of the proof and whose `gate_id` is the gate it serves, and accepts each digest once
through its own redemption store. The signed message names the verifier's audience and the digest
(`nft-gate:access:v2`) and the consumption must be recent. The event `nonce` is optional.

**Deployed verifier behaviour (access-gate gateways, 0.0.21 + `main`, same as the contract above):**

- the access message is v2 (audience-bound) and names the digest; the details are in the nft-gate audits;
- the consume transaction is fetched **by digest**, and an event of the exact type
  `<original-id>::access_gate::AccessConsumedEvent` with `sender` = signer and `gate_id` = `GATE_ID`
  is required. The Workers gateway also requires `status.success`; Rust infers success from the event
  (nft-gate Rust F21);
- **the event `nonce` and `nft_id` are not checked**;
- single use is enforced by a redemption store keyed on the digest: lease, then commit on 2xx or
  release on failure (lease and retention details: the nft-gate audits).

| Event | Emitted by | Fields (verifier MUST check) | Before/after structural change | Consumers |
| --- | --- | --- | --- | --- |
| `GateCreatedEvent` | `share_new_gate` | `policy`, `free_gate_fee_paid_mist` (indexers) | before share | indexers (dao/treasury discover gates via `AdminCap` instead) |
| `AccessMintedEvent` | `purchase`, `airdrop` | `commission_mist` (accounting) | before transfer | treasury-ui activity |
| `AccessConsumedEvent` | `consume*` | digest (from the transaction), `consumer`/sender, `gate_id`, exact event type; `nonce` and `nft_id` optional (F34, same in docs and gateways) | after decrement, before delete | access-gate gateways, treasury-ui (`consumer`) |
| `AccessBurnedEvent` | auto-burn, `burn*` | — | before delete | indexers |
| `GateFrozenEvent` | `make_gate_immutable` | `locked_commission` | after `frozen = true`, before cap delete | UIs |
| `GateMadeFreeEvent` | `make_gate_free` | `fee_paid_mist` | after the price change | indexers |
| `PlatformConfigUpdatedEvent` | platform setters | full resulting terms | after the update | treasury/dao UIs |
| `PlatformMigratedEvent` | `migrate` | `from_version`, `to_version` | after the update | integrators (switch to the new `published-at`) |

### B.SC-1 ID-constant trace (consumers of this package's IDs)

| Location | Network | Value | Kind | Matches latest (`Published.toml`)? |
| --- | --- | --- | --- | --- |
| `Published.toml` | testnet | `0xd7ddaa94…88c9` | original-id = published-at (v1) | reference |
| `deployments.json` | testnet | `PlatformConfig 0x3f81489d…e7b5`, `authorityObjects` | object | Y (matches docs and the client) |
| `SECURITY.md`, `docs/onchain/{overview,dev-guide,api-reference}.md`, `Move.toml` comment | testnet | `0xd7ddaa94…` / `0x3f81489d…` | both | Y (`83dbf25`) |
| `@meddleware/access-gate-client` 0.0.8 (0.0.9 since 2026-10-10, same record) `src/deployments.ts` (generated from access-gate-sui 0.0.6) | testnet | `originalId`/`publishedAt` `0xd7ddaa94…`, `platformConfigId 0x3f81489d…` | both | Y |
| `sealed-storage-sui` 0.0.7 `Move.toml`/`Move.lock` | testnet | `rev = 790695489fc4…` (`7906954`, the publish record of `0xd7ddaa94…`) | git SHA | Y |
| `access-gate-gateway/gateway-workers/wrangler.toml` `NFT_TYPE` / `GATE_ID` | testnet | `0xd7ddaa94…::access_gate::SoulboundAccessNFT` / gate `0x316f1bf9…` | original-id (type) | Y |
| `access-gate-gateway/gateway-rust/src/sui_rpc.rs:658-678` (env-gated live test) | testnet | `0xa55789…` / `0xfd6c3b…`, commented as the superseded immutable package/gate | original-id | N, deliberately: it replays a recorded consume on an immutable package and does not serve traffic |
| Apps' `VITE_ACCESS_GATE_ID_TESTNET` (GitHub repository variable consumed by the dashboard and token-issuance-ui image builds) | testnet | not readable from the repositories | gate | unverified directly; the 2026-10-09 paywall e2e through the live dashboard bought a pass on `0x316f1bf9…`, so the dashboard build carries the new gate |

### B.SC-2 Coupling (scripts' PTB only)

| Move function | Builder | Test asserting target + arguments |
| --- | --- | --- |
| `new_gate_policy(bool×4)` → `create_gate(platform, price, recipient, uses, soulbound, auto_burn, name, image, description, policy)` | `publish.sh:261-265` | localnet `--create-gate` runs (2026-09-28/30); no automated assertion |
| `create_free_gate(platform, fee, recipient, …, policy)` with `split-coins gas [fee]`, the fee read from `PlatformConfig` | `publish.sh:250-259` | localnet runs; testnet gate creation 2026-10-02 |

Every application PTB lives in `@meddleware/access-gate-client` (ADR-0001), which is audited
separately.

### B.OPS-1 Runbook linkage

| Script | Linked from | Dry-run command | Recovery command |
| --- | --- | --- | --- |
| `publish.sh` | README, `AGENTS.md`, `CUSTODY.md` step 1 | — (no dry run; F41e adjudicated) | printed: "re-run only that step … never re-publish"; `--replace-published` for a deliberate fresh publish |
| `transfer-platform-authority.sh` | `CUSTODY.md` step 2, `AGENTS.md` | default (`DRY_RUN=1`) | printed on a partial failure (re-run; ownership re-verified) |
| `make-immutable.sh` | `CUSTODY.md` step 5, `AGENTS.md` | default | multisig signing steps printed; burn record instructions |
| `multisig-address.sh` | `CUSTODY.md` | n/a | n/a |

`SECURITY.md` Scope names `publish.sh`, `transfer-platform-authority.sh`, `make-immutable.sh` and `multisig-address.sh` (F39, resolved).

### B.TS-1/2/3 npm package

| Check | Holds? |
| --- | --- |
| `exports` / `files` | explicit: `./package.json`, `./Published.toml`, `./deployments.json`; `files` whitelist (15 packed files, 33.4 kB; no tests, scripts, audit or env files) |
| `sideEffects` | not applicable (no JavaScript) |
| Install-time code | none (no lifecycle scripts, no `allowScripts`, no `overrides`) |
| Lockfile + `npm ci` + `npm audit --audit-level=high` in publish | yes (empty tree) |
| npm client pinned in publish | yes (`11.20.0`) |

---

## Section C — Test-coverage & hermetic/live split

### C.1 Coverage grade — A (94/94 on sui 1.81.0; 100.00% module coverage)

| Dimension | Assessment |
| --- | --- |
| Happy-path | A — init defaults, create (paid/free), purchase (exact/overpay/free), commission split, floor/cap, single-use decrement + receipt, transferable auto-burn, soulbound mint + consume, airdrop (+ commission), burns, setters, freeze (+ lock), platform setters, `migrate`, the soulbound auto-burn branch, the display setters and the display copy at mint, `is_valid_for*` (the last four closed in 0.0.6, F37). **Missing:** none recorded |
| Error-path / abort codes | A — every code 1–16 has an `expected_failure` test (counts below); 3/4/5/8 also on the soulbound path; 13 on all 20 gated entry points |
| Boundary / edge | A — `u64::MAX` price at 10%, dust, floor raise after creation, 7-byte nonce, zero uses, exhausted vs unlimited, foreign cap, frozen-while-paused, auto-burn changed after mint, migrate at, below and above the version |
| Security-relevant | A− — cross-gate consume (both variants), frozen guards, cap binding, short nonce, zero treasury, wrong version everywhere, the policy-combination rule (15) and the pass-kind rule (16). **Missing:** none recorded |

**Abort-code map and test counts (`(access_gate, code)`):**

| Code | Name | `expected_failure` tests |
| --- | --- | --- |
| 1 | `E_PAUSED` | 3 |
| 2 | `E_INSUFFICIENT_PAYMENT` | 3 |
| 3 | `E_NOT_SINGLE_USE` | 2 |
| 4 | `E_NO_USES_REMAINING` | 2 |
| 5 | `E_WRONG_GATE` | 3 |
| 6 | `E_GATE_FROZEN` | 2 |
| 7 | `E_COMMISSION_TOO_HIGH` | 1 |
| 8 | `E_INVALID_NONCE` | 2 |
| 9 | `E_ZERO_ADDRESS` | 1 |
| 10 | `E_FREEZE_WHILE_PAUSED` | 1 |
| 11 | `E_PRICE_TOO_LOW` | 3 |
| 12 | `E_FREE_FEE_UNPAID` | 1 |
| 13 | `E_WRONG_VERSION` | 20 |
| 14 | `E_NOT_UPGRADE` | 2 |
| 15 | `E_POLICY_COMBINATION` | 2 |
| 16 | `E_USES_KIND_IMMUTABLE` | 2 |

`seal_policies` reuses low codes (`config` 1–2, `sealed_content` 1–3, `nft_gate` 4), so clients
disambiguate by module.

**Conformance:** this package decodes no client-built bytes. Its event layout is asserted by
access-gate-client's BCS tests and ABI-drift integration test, and by the gateways' env-gated live
tests, against the real contract (not a self-compared vector).

### C.2 Hermetic vs. live paths

| Path | Hermetic unit test? | Deferred to | Tracking |
| --- | --- | --- | --- |
| All accounting, consume, freeze and version logic | yes | — | `tests/access_gate_tests.move` |
| `publish.sh` (incl. `--create-gate`), `transfer-platform-authority.sh`, `make-immutable.sh` (direct + multisig) | no | localnet | runs 2026-09-28/30; full custody rehearsal 2026-10-01 (`CUSTODY.md`); not re-run this pass; the 2026-10-09 testnet republish (`publish.sh --replace-published`, record `7906954`) and the cap burn are real-chain evidence (burn read on-chain; the script used for the burn is not recorded) |
| Upgrade + `migrate` on a real chain (old `published-at` aborts afterwards) | unit only (`set_platform_version_for_testing`) | **testnet, scratch publication, 2026-10-22** (v1 → v2 signed by a 2-of-2 multisig, `migrate`, old `published-at` aborts `E_WRONG_VERSION` = 13; log entry). The first upgrade of a MAINNET publication inside the `CUSTODY.md` window is still ahead | S4 |
| Wallet `Display` rendering; wallets refusing a soulbound transfer | no | testnet smoke | manual |
| Cross-package linkage (`seal_policies` → `is_valid_for*`) | `is_valid_for*` itself is unit-tested (F37) | seal-policies tests (41, linking `0xd7ddaa94…`) + testnet decrypt round trip | seal-policies audit |
| Verifier replay discipline | no | nft-gate suites; live paywall e2e PASS 2026-10-09 (pass bought on gate `0x316f1bf9…`, consumed, `nft-gate:access:v2` proof) | F34 |

---

## Section D — Deployment-readiness gates

### pre-localnet

- [x] `sui move build` clean (lint clean, warnings as errors); `sui move test` green **94/94** (sui 1.81.0), 100.00% module coverage — CI `move-ci.yml`
- [x] every abort code tested (1–16); no unchecked u64 products; all caps bound to their objects — F6, F9, F10, C.1
- [x] shellcheck green (CI); script inventory complete — F45, OPS matrix
- [x] every irreversible step dry-run by default with its own typed confirmation — I19
- [x] `SECURITY.md` present **and consistent with the audit** — F34, F39 (and the audit is no longer shipped in the npm tarball: F43)

### pre-testnet

- [x] published (`0xd7ddaa94…`, `Published.toml`, 2026-10-09); package ID recorded consistently across `Move.toml`,
  `Published.toml`, README, `SECURITY.md`, docs and consumers — B.SC-1
- [x] git dependants pin commit SHAs (seal-policies `790695489fc4` = `7906954`); lockfile committed — F15
- [x] integration exercised against real testnet objects — live relay paywall e2e on gate `0x316f1bf9…`
  (2026-10-09; nft-gate audits); seal decrypt round trip (seal-policies)
- [x] custody/immutability tooling present with dry-run default + explicit confirmation — F12, F33
- [x] preflight hard-fails on environment / chain id / CLI version mismatch — F45
- [x] preflight checks the expected signer and balance — F41 (`7b75da3`)
- [x] real-chain jobs: none in CI (no keys in CI) — B.2
- [x] record-keeping writes original-id and published-at, and drives the consumer bump and re-pin — B.SC-1
- [x] record-keeping covers the authority object IDs — F40 (`deployments.json` `authorityObjects`)
- [x] verifier contract reconciled with the deployed gateways — F34 / OQ17 (decided digest-first)
- [x] published dev-site snippets match the ABI — F38 (a docs-side snippet CI check stays a suggestion, S6)

### pre-mainnet

- [ ] **B.3 policy executed on mainnet:** `CUSTODY.md` transfer → verification window → multisig burn — **blocking** (F3, OQ1; maintainer: `OPERATOR_TASKS.md` "Mainnet release custody")
- [ ] **privileged caps** (`PlatformAdminCap` / `Publisher` / `Display`) at the multisig — **blocking** (F2, OQ2; same item)
- [x] the custody lifecycle exercised once on a real chain (testnet) — OQ21: run 2026-10-22 on a scratch testnet publication (not the live cap) with a 2-of-2 multisig of two throwaway keys: publish `8mzSBRPQtwYAsuQsWyk5KQPFDXmXjRzb939jiBSPZG62`, transfer of all five authority objects (`FRjnKWTL…Ek9M`, `CVd56mj1…R1X9V`, `9zis5HSu…CXJ`, `8XDyM9EH…z4N`, `ErzPAj46…jtnRsE`), `plannedBurnDate` set, multisig upgrade + `migrate`, multisig burn `Eui26pAVBmeicw9P9chig8eqzR1jrDHnPi7iewK1p1Zo` (UpgradeCap gone); full ids in the log entry. The live caps were not touched
- [ ] full Section A coverage with no GAP — only I11 remains (F3, mainnet-blocked)
- [x] abort-code map published (`docs/onchain/api-reference.md`, C.1)
- [x] live-only paths (C.2) exercised on testnet, including an upgrade + `migrate` — 2026-10-22 on the scratch publication: upgrade `E1jsVrjMhMRFGLwwhJrTGbKaDDxV47aDNWGcXGCuwEZW` (v2 `0x12d50145…c5af`), `migrate` `BEMeJ7oCX2SzvYfn3gmcsaKLxYU8YQdMcYcWD9rfrYLr` (`PlatformMigratedEvent` 1 → 2); a `purchase` dry run against the old `published-at` aborts 13 (`check_version`) after it and succeeds against the new one. Before `migrate`: v1 succeeds, v2 aborts 13. S4's localnet script is still a suggestion
- [x] mainnet double guards in place; skipped runs never report success — F45
- [x] runbook links every script with dry-run and recovery commands, including `SECURITY.md` scope — F39, B.OPS-1
- [ ] external audit — maintainer / mainnet item

---

## Cross-project themes

- **Supply chain & release integrity:**
  - The only Move dependency is the framework, pinned in the committed `Move.lock`.
  - npm publishes via OIDC with provenance.
  - Actions are SHA-pinned; the sui CLI is pinned by version, with its installer checksum-pinned
    (F44).
  - Tags are now reconciled and chronological; dependants still pin SHAs (F15).
- **Wire-format coupling & conformance vectors:**
  - `AccessConsumedEvent` and the object layouts are consumed by access-gate-client (BCS +
    ABI-drift test) and both gateways (live test).
  - The *semantic* contract, which fields a verifier binds, is the same in this package's docs and in
    the gateways since 0.0.6: digest-first redemption (F34, resolved).
  - The access proof itself lives in access-gate-gateway-client / nft-gate vectors.
- **On-chain-truth boundary:** prices, commission, fees, pass validity and version are decided
  on-chain. UIs and clients split exact amounts and only preview.
- **Deployment readiness:** Section D. Everything up to testnet is ticked; mainnet is blocked on custody
  (F2/F3), one real upgrade + `migrate` rehearsal and external review.
- **Chain-access layering & on-chain ID/ABI coupling (ADR-0001):**
  - This package is the Move side. Its domain client is `@meddleware/access-gate-client`, generated
    from this package's `Published.toml` + `deployments.json`.
  - Call targets use `published-at` and types/events use the original-id; they are identical until the
    first upgrade, and the client export already carries both.
  - Every consumer traces to the latest record (B.SC-1). seal-policies' git dependency resolves to the
    commit recording the latest publication.
  - The ABI drift test lives in access-gate-client (passes against `0xd7ddaa94…`, 2026-10-09). The one
    hand-written snippet on the dev site that had drifted was fixed (F38).
  - **Pre-v0.2 policy:** no findings ask for compatibility shims. A fresh package is preferred over
    upgrades with layout constraints (as done for `0x1a81ca…` → `0xa55789…` → `0xd7ddaa94…`; the orphaned
    gates on the old package are accepted, F48), and npm 0.0.6 is the publication that carries the changed files.

---

## Normative requirements (MUST / MUST NOT)

**Move lens baseline:**

1. MUST NOT overflow or silently truncate in any reachable arithmetic — **holds** (F6, F10, I9).
2. MUST bind every capability to its object and check it on every privileged path — **holds** (I4, I7).
3. MUST keep dry-run policy functions side-effect-free — **N/A here** (none; `seal_policies` holds them).
4. MUST keep on-chain byte-layout decoders length-guarded and identical to the encoder — **N/A** (the
   nonce is opaque, only its length is guarded).
5. MUST have a decided and, before mainnet, executed UpgradeCap policy and target custody for every
   privileged object — **decided** (`CUSTODY.md`, F33); **not executed** (F2, F3).
6. MUST pin git dependencies to commit SHAs and commit the lockfile — **holds** (no git dependencies;
   dependants pin SHAs).
7. MUST document in `SECURITY.md` and the audit what off-chain verifiers are responsible for —
   **holds** (digest-first contract, identical in docs and gateways; F34, B.5).

**Project-specific:**

8. Every state-changing, minting or consuming function MUST call `check_version` first, and `migrate`
   MUST only move forward — **holds** (I17).
9. A gate's `GatePolicy` MUST be immutable, and locked terms MUST be the only terms after freeze —
   **holds** (I8b).
10. Every paid mint MUST pay `max(bps share, floor)` ≤ 10% of the price, and a free gate the one-off
    fee — **holds** (I16).
11. Admin configuration MUST NOT be able to destroy holders' sold entitlements, or change the type or
    variant verifiers accept, without a protective rule — **holds** (E15/E16 since 0.0.6; F35, F36, I8c).
12. The canonical package address MUST be the one in `Published.toml`, `SECURITY.md`, the docs and
    every consumer — **holds** (`0xd7ddaa94…`, B.SC-1).
13. Published documentation (dev-site snippets, `SECURITY.md`, the shipped audit) MUST match the
    current ABI and deployment — **holds** (F38, F39, F43 resolved; the npm tarball no longer ships the audit).
14. Downstream Move packages MUST pin this dependency to a commit SHA — **holds** (seal-policies
    `790695489fc4` = `7906954`).

**OPS lens baseline:**

| ID | Holds? | Evidence |
| --- | --- | --- |
| OPS-M1 | holds — env, chain id, CLI major.minor, expected signer (mainnet-required) and balance hard-fail (`publish.sh`; the transfer script checks the signer) | F41 |
| OPS-M2 | holds — `set -euo pipefail`, shellcheck clean, git-ignored env files | |
| OPS-M3 | holds — dry-run defaults, per-step typed confirmations, mainnet double guard | publish has no dry run (F41e, adjudicated) |
| OPS-M4 | holds — `--json` + `jq`, exact types, abort on missing IDs | |
| OPS-M5 | holds — IDs and recovery printed; the publish-side burn is verified | F41c |
| OPS-M6 | holds — original-id/published-at, `PlatformConfig`, custody and authority IDs committed; consumers bumped and re-pinned | F40, B.SC-1 |
| OPS-M7 | holds — no keys in CI | |
| OPS-M8 | holds — no real-chain CI jobs; operator-run scripts | |
| OPS-M9 | holds — scripts never switch env; the `chain-identifier` cache write is documented | |
| Destructive file operations (§A) | N/A — no script deletes files; generated files are the `.env.<net>` and record files, previous ones kept as `.bak` | F45 |

**TS lens baseline (npm-package rows):**

| ID | Holds? |
| --- | --- |
| TS-M7 | holds (whitelisted files, no install-time code) |
| TS-M8 | holds (`npm ci`, audit gate, no shared deps) |
| TS-M1…M6 | N/A (no TypeScript) |
| TS-M9 | N/A (no dependencies, no `@mysten/*` peers) |

## Implementation suggestions (SHOULD / MAY)

- **S1** SHOULD emit events from the gate setters (configuration history; also the signal verifiers
  need for F35, now closed) — F20.
- **S2** MAY cap the nonce length (e.g. ≤ 256 bytes) to bound event size.
- **S3** SHOULD add a view returning `(price, commission, operator_share)` so UIs never recompute the
  split.
- **S4** SHOULD add a localnet script exercising publish → create gate → purchase → consume →
  **upgrade with `VERSION` bumped → `migrate` → old `published-at` aborts**, run before every release.
  [Run by hand on testnet on 2026-10-22 (log entry), through the real scripts and a 2-of-2 multisig; it found F49. Not scripted: the
  steps need the current CLI, three signatures and a funded scratch key, so they stay a rehearsal before each full release.]
- **S5** MAY bound gate display strings (name ≤ 64, URL ≤ 512, description ≤ 1024 bytes) to limit
  wallet-phishing payloads and event size (B.4).
- **S6** SHOULD add a docs CI check comparing dev-site `moveCall` snippets with the compiled ABI (F38).
- **S7** MAY record each script run used as evidence (date, network, result) in `CUSTODY.md` or this
  log (OPS §C).

## Open questions (`OQ#`)

1. **OQ1** When will the testnet `UpgradeCap` be burned or moved, and how will versioning and
   migration be announced to integrators? *(2026-09-28, owner: design as if a multisig holds authority;
   keep crucial new versions upgradeable while tested, then burn.)* *(2026-09-28, owner: burn vs
   multisig not yet decided.)* **(Decided 2026-10-01: both — transfer to the multisig, verification
   window, multisig-signed burn on a planned date, per `CUSTODY.md`; version gating retires old code
   during the window — see F3, F32, F33.)** Timing for testnet is OQ21.
2. **OQ2** *(first pass — decided: multisig is the target custody)* Which multisig address (and M-of-N)
   will hold platform authority, and when will the transfer run? *(2026-09-28, owner: multisig later;
   operator requirement before launch.)* **(Decided 2026-10-01 in part: a 1-of-1 multisig of the
   maintainer's key is acceptable while there is one maintainer; extend by re-transferring to a new
   multisig — `CUSTODY.md`.)** The address and date remain open (`deployments.json`
   `multisigAddress: null`).
3. **OQ3** *(first pass — decided: on-chain minimum length + `consumer` field; uniqueness off-chain)*
   Should the minimum nonce length rise from 8 to 16 bytes to match the recommended verifier nonce?
4. **OQ4** Is it acceptable that `set_commission_bps` changes the economics of frozen gates?
   **(Decided 2026-09-28: configurable per gate via `lock_commission_on_freeze` — see F4, F24.)**
5. **OQ5** Should `make_gate_immutable` refuse to freeze a paused gate? **(Decided 2026-09-28:
   configurable via `freeze_requires_unpaused` — see F19, F24.)** The combination hazard is OQ19.
6. **OQ6** Is per-gate metadata (copied at mint) the source of truth with the global `Display` a
   passthrough, and who may change the `Display` templates?
   *(Decided 2026-10-22: yes. The per-gate metadata copied onto the pass at mint is canonical; the global `Display` is a passthrough of those fields; the `Display` and the `Publisher` stay with the multisig, so only the `PlatformAdminCap` authority can change a template. No code change; this is a requirement for the next publish and its custody step.)*
7. **OQ7** Which testnet package is canonical? **(Decided 2026-09-28: `0x0bedd0…`, republish once the
   off-chain changes are in — see F14.)** *(Superseded 2026-10-02 by the version-gated publish:
   `0xa55789…`; superseded again 2026-10-09 by the 0.0.6 republish: `0xd7ddaa94…` per `Published.toml`.)*
8. **OQ8** Tag hygiene: will release tags be immutable (never moved), for example via tag protection?
   *(2026-10-03: tags `v0.0.1`–`v0.0.5` are now on the remote in chronological order; 2026-10-09: `v0.0.6` → `83dbf25` added. Tag protection is a maintainer setting, F15.)*
   *(Decided 2026-10-22: protect release tags with a tag ruleset (no update, no deletion of `v*`), so a published version's tag cannot move. A repository setting, applied by the maintainer; not a code change.)*
9. **OQ9** Should `auto_burn_at_zero` be snapshotted per NFT at mint instead of read at consume time?
10. **OQ10** Which licence applies? **(Decided 2026-09-28: 0BSD — see F21.)**
11. **OQ11** Dust pricing: enforce a minimum price, or accept? **(Decided 2026-09-28:
    operator-configurable at the tool layer, later enforced on-chain by F26 — see F25, F26.)**
12. **OQ12** Should `create_*` / `set_payment_recipient` reject `@0x0` as the gate's
    `payment_recipient`?
    *(Decided 2026-10-22: yes — reject `@0x0` with `E_ZERO_ADDRESS` in both. A payment to `@0x0` is irrecoverable and never intended. This changes Move code, so it is a requirement for the NEXT publish (with a test for each entry point and the abort-code map updated); the source is not edited in this pass.)*
13. **OQ13** Burn the stray packages' UpgradeCaps? **(Decided 2026-09-28: yes — done, with every other
    stray and superseded cap — see F31.)**
14. **OQ14** Should Meddleware's deployment allow free (price 0) gates? **(Decided 2026-09-28: yes, if
    creation is charged and cannot be dodged by re-configuration — see F27.)**
15. **OQ15** Should the gateways honour `pause_blocks_decryption`? **(Decided 2026-09-28: make it
    optional and independent — `pause_blocks_access`, F29.)**
16. **OQ16** Are the default platform terms right for Meddleware's deployment: 0.2%, a 0.001 SUI floor
    (minimum paid price 0.01 SUI) and a 0.1 SUI free-gate fee?
    **(Decided 2026-10-19: 0.2% stays; the floor becomes 0.0005 SUI (minimum paid price 0.005 SUI) and the
    free-gate fee 1 SUI. Evidence: the workspace cost model `docs/economics/COST_MODEL.md` (decision D57) — the
    floor is at most 20% of a buyer's unavoidable purchase gas on mainnet (0.00442 SUI), the free-gate fee is a
    value action of about US$1. Source defaults changed in 0.0.7; the live testnet `PlatformConfig` is changed
    by the maintainer through `set_min_commission_mist` / `set_free_gate_fee_mist`.)**
17. **OQ17** Which consume binding is canonical?
    - (a) Digest-first redemption: digest + event `sender`/`consumer` + `gate_id`, single use by
      redemption store. This is the gateways today.
    - (b) Nonce-bound: the event `nonce` must equal the signed challenge. This is this package's docs
      today.

    Shared with nft-gate (gateway audits F23 / F1 and OQ1) — see F34.
    **(Decided 2026-10-08: (a), digest-first redemption is canonical; the docs were rewritten in
    `7b75da3`.)**
18. **OQ18** Should `soulbound` and `default_uses` become immutable after creation (or lockable by a
    policy flag), or stay mutable with events and live checks in verifiers? See F35.
    **(Decided 2026-10-08: immutable after creation — `set_soulbound` removed, `set_default_uses` cannot
    cross zero, `E_USES_KIND_IMMUTABLE` = 16, 0.0.6.)**
19. **OQ19** Should `pause_blocks_access` / `pause_blocks_decryption` require
    `freeze_requires_unpaused`, or should freezing unpause such gates? See F36.
    **(Decided 2026-10-08: refuse the combination at creation, `E_POLICY_COMBINATION` = 15, 0.0.6.)**
20. **OQ20** Should `min_commission_mist` and `free_gate_fee_mist` have on-chain ceilings, or is the
    `PlatformAdminCap` (multisig) trust assumption sufficient? See F42.
21. **OQ21** Should the testnet `0xd7ddaa94…` publication (formerly `0xa55789…`) run the `CUSTODY.md` lifecycle now
    (multisig, planned burn), so the process is proven on a real chain before mainnet, or does
    testnet stay with the deploy key until mainnet? (`SECURITY.md` currently says the latter.) See F3.
    *(Decided 2026-10-22: rehearse the lifecycle on a scratch testnet publication, not on the live cap. The live `0xd7ddaa94…` caps stay with the deploy key until mainnet (an irreversible burn there would remove the upgrade path the testnet needs); the real-chain rehearsal — transfer, verification window, upgrade plus `migrate`, multisig burn — runs on a throwaway publication whose caps can be burned freely. The Section D box stays open until that rehearsal has run.)* **Run 2026-10-22** (Section D, log entry): the lifecycle works as `CUSTODY.md` describes except for F49.

## Risks (residual)

- **Key custody:** until F2/F3 execute, one key controls package code, `migrate`, commission routing,
  platform terms and wallet display for every gate.
- **Verifier correctness:** replay safety depends on each verifier. The documented and deployed
  verifier contracts now agree (digest-first, F34), but a careless integrator can still build a
  replayable service.
- **Version fragmentation:** after the burn, each release is a new original-id with its own
  `PlatformConfig`. Gates and passes never migrate automatically, and verifiers must track every
  trusted original-id.
- **Upgrade window:** while the multisig holds the UpgradeCap, `migrate` can retire old code for every
  caller at once. That is the intended safety valve, but it is also a liveness lever for whoever holds
  the multisig.
- **Admin configuration:** since 0.0.6 the pass kind and policy are fixed at creation (F35, F36), so an
  admin can no longer strand sold passes through type, kind or policy changes. An admin can still pause
  or re-price a gate (F5, F42, B.4); buyers must read gate state.
- **Orphaned package lineages:** each fresh publish leaves gates and passes on the previous package
  frozen and outside version gating (F48); verifiers must track every trusted original-id.
- **Metadata phishing:** anyone can create gates with arbitrary names and images (B.4).
- **Effective rate on cheap passes:** the floor makes the platform's share 10% at the minimum price,
  falling to 0.2% at 0.5 SUI and above.
- **Revenue depends on coin sweeping:** about half of each minimum-price sale's value to the treasury
  is the storage deposit of the commission coin, recovered only when the treasury merges coins.
- **Commission lock:** a gate that locks its commission at freeze is immune to later platform rate
  changes in either direction.
- **Mutable git tags** remain a hazard for any dependant that pins a tag instead of a SHA.

---

## Re-verification log

- 2026-09-18 — First-pass baseline (18 → 22 tests; F1–F9; OQ1–OQ6).
- 2026-09-28 — Relocated to the package repo; re-verified under the updated template + Sui lens.
  - Added F10–F22. F10–F13, F16 and F17 RESOLVED in `c835520` (36/36 tests; scripts verified on
    localnet).
  - On-chain reads confirmed `0x0bedd0…` canonical for consumers; `0x692547…` also exists; the testnet
    UpgradeCap is live (compatible policy).
  - Package made npm-consumable for the docs sites.
- 2026-09-28 (second pass) — Owner answers to OQ1/2/4/5/7/10/11 recorded.
  - F24 (gate policies) and F21 (0BSD) RESOLVED in `22fe6d7`.
  - F14 RESOLVED (on-chain GraphQL reads).
  - F4/F19 RESOLVED via policy.
  - F25 RESOLVED at the tool layer.
  - 42/42 tests. OQ13–OQ15 added.
- 2026-09-28 (third pass) — F26–F29 RESOLVED in `6bdf8a6`; F30 in nft-gate `bbf8665`.
  - Published fresh as `0x1a81ca…` (`dcd2d3c`), and every stray and superseded UpgradeCap burned (F31).
  - 60/60 tests. OQ13–OQ15 answered; OQ16 added.
- 2026-09-29 — Relay gate migrated to `0xcb8206…5f50` on `0x1a81ca…`; live paywall round trip passes.
- 2026-10-01 — *(recorded retroactively at the 2026-10-03 pass)* Custody decision (`CUSTODY.md`:
  transfer → verify → multisig burn) and localnet rehearsal of the full lifecycle; version gating
  implemented (`120a407`).
- 2026-10-02 — *(recorded retroactively)* Version-gated fresh publish `0xa55789…` from `b445876`
  (toolchain 1.81.0, `Published.toml`, `deployments.json`, npm 0.0.5). `0x1a81ca…`'s UpgradeCap burned.
  Relay gate `0xfd6c3b…` created on `0xa55789…` and the Worker re-pointed. seal-policies republished
  (`0x61c4aaa4…`) against `b445876`. The previous audit's front matter was partially updated, but the
  body was not re-verified (the cause of F43).
- 2026-10-03 — **Re-verified** at `32597c9` under base (2026-10-02) + SUI (2026-09-28) + OPS
  (2026-09-30) + TS (2026-10-03) + SUI_CLIENT (2026-09-30, script PTB).
  - Measured: sui 1.81.0, `sui move test` 85/85; lint clean; coverage 92.70%; shellcheck 0.11.0
    clean; npm pack 16 files; provenance verified.
  - On-chain reads were not possible from the review sandbox.
  - Every finding re-dated. F14 canonical → `0xa55789…`; F2/F3 updated to the current cap and
    custody decision; F20 partly superseded.
  - Added F32–F46 (F45–F46 Positive) and OQ17–OQ21. Decisions recorded on OQ1, OQ2 (partial), OQ4,
    OQ5, OQ7, OQ10, OQ11, OQ13, OQ14 and OQ15.
  - Front matter, executive summary, threat model, Sections A–D, normative list (renumbered in order)
    and themes rewritten to the current state.
  - **No finding resolved in this pass:** by maintainer instruction it records findings only;
    remediation is to be applied separately and each disposition then moves with the diff cited.
  - Pre-save consistency checklist run.
- 2026-10-08 — *(recorded retroactively at the 2026-10-09 pass)* The 2026-10-03 findings were fixed in
  `7b75da3` (0.0.6) and `a5ea133` (Dependabot), `9defe35` (shellcheck 0.9 clean): F34–F44 and F47 resolved;
  decisions OQ17 (digest-first), OQ18 (pass kind fixed at creation), OQ19 (refuse the combination).
  New aborts `E_POLICY_COMBINATION` = 15 and `E_USES_KIND_IMMUTABLE` = 16; `set_soulbound` removed; 94
  tests, 100.00% coverage.
- 2026-10-09 — **Re-verified** (fifth pass) at `83dbf25` = tag `v0.0.6` under base (2026-10-08) + SUI
  (2026-09-28) + OPS (2026-10-08) + TS (2026-10-08, npm rows) + SUI_CLIENT (2026-10-08, script PTB).
  - Republished on testnet: `0xd7ddaa94…` (`7906954`, `83dbf25`), `PlatformConfig 0x3f81489d…`, UpgradeCap
    `0x7d63f623…` (read on-chain: owned by the publisher EOA). The superseded `0xa55789…` cap
    `0x70be984f…` was burned (object gone). Relay gate `0x316f1bf9…` (soulbound, 10 uses) created;
    the Worker, access-gate-client 0.0.8 and sealed-storage-sui 0.0.7 (`790695489fc4`) point at it.
  - Measured: `sui move test` 94/94, coverage 100.00%, lint clean (warnings as errors), npm pack 15
    files / 33.4 kB, npm 0.0.6 published; shellcheck not re-run (CI). Test counts per abort code
    re-counted from the source (13: 20 tests; 15 and 16: 2 each).
  - Dispositions after this pass (48 findings): RESOLVED 33, Positive 7 (F6–F9, F22, F45, F46),
    ADJUDICATED 3 (F5, F18, F42), MITIGATED 1 (F15), ACCEPTED-RISK 2 (F20, F48), DEFERRED 2 (F2, F3 —
    mainnet-blocked, `OPERATOR_TASKS.md` "Mainnet release custody"). No finding is open without a gate.
  - Fixed in this pass's text: Sections A–D, B.1–B.SC-2, C.1/C.2, themes, normative list, OPS/TS tables,
    risks and OQ decisions (OQ7/OQ8/OQ17–OQ19); the stale `0xa55789…`/`0xfd6c3b…`/`0x61c4aa…` ids remain
    only in history lines and "superseded" statements. A package object always reads `Immutable`, so the
    burn evidence is the missing cap object.
  - New this pass: F47 and F48 (see the findings).
- 2026-10-18 — release status checked: no new release (`@meddleware/access-gate-sui` 0.0.6 is still `latest`, SLSA v1 provenance
  present; tag `v0.0.6` = `83dbf25`; no code change on `main` since). Consumers re-read: access-gate-client 0.0.9 (released
  2026-10-10) still generates `deployments.ts` from the exact pin `0.0.6`; docs and dev at `^0.0.6`. No finding or Section D box changes.
- 2026-10-19 — dependency-bot status checked (read-only): `.github/dependabot.yml` carries the `ignore` rules and the repository has no open Dependabot pull requests (`gh pr list`, 2026-10-19). Versions, findings and gates were not re-examined in this pass.
  - Dependabot policy encoded in .github/dependabot.yml (majors declined); open PRs merged 2026-10-19
- 2026-10-19 — OQ16 decided from the workspace cost model (`docs/economics/COST_MODEL.md`, D57): source defaults
  `DEFAULT_MIN_COMMISSION_MIST` 1_000_000 → 500_000 and `DEFAULT_FREE_GATE_FEE_MIST` 100_000_000 → 1_000_000_000
  (`DEFAULT_COMMISSION_BPS` stays 20), with a comment that they apply at the mainnet publish; F22 and the F42
  note updated; on-chain docs and README amounts updated. Version 0.0.7 (`Move.toml`, `package.json`), released as tag `v0.0.7` = `bf23517`. Measured: `sui move build --lint --warnings-are-errors` clean, `sui move test` 94/94
  (`test_init_creates_platform_objects` pins the new defaults). Not republished: the testnet `PlatformConfig`
  keeps 1_000_000 / 100_000_000 until the maintainer sends the setters. No disposition changes.

- 2026-10-22 (audit close-out) — open questions decided; no Move source change.
  - **Decided 2026-10-22:** OQ21 (rehearse custody on a scratch testnet publication, not the live cap), OQ8 (protect release tags with a tag ruleset), OQ6 (per-gate metadata copied at mint is canonical, the global `Display` is a passthrough, `Display` and `Publisher` stay with the multisig),
    OQ12 (reject `@0x0` as `payment_recipient` with `E_ZERO_ADDRESS`). OQ12 changes Move code and is recorded as a requirement for the NEXT publish (tests for `create_*` and `set_payment_recipient`, abort-code map and docs updated with it); OQ6 and OQ21 are process rules for that publish and its custody step; OQ8 is a repository setting (maintainer).
  - **F20 and F48 stay ACCEPTED-RISK** (reasons confirmed). Section D: the OQ21 box keeps its place and now names the decided method. Release status: `0.0.7` is tagged (`v0.0.7` = `bf23517`; D57 fee defaults, source only: the testnet publication is still 0.0.6). No code was changed or run in this pass.
- 2026-10-22 (testnet rehearsal on a scratch publication; scripts fixed, 0.0.8 local commit, not released) — OQ21 and C.2, S4 run on a real chain.
  - **Setup:** an isolated `SUI_CONFIG_DIR` holding only the maintenance runner's testnet key and two throwaway keys; a copy of this checkout with `Published.toml` and `deployments.json` emptied (the live package `0xd7ddaa94…` and its caps were not touched); sui 1.81.0 for the scripts, 1.82.2 (release `testnet-v1.82.2`, run from a scratch directory, nothing installed) for `sui client upgrade`.
  - **Publish:** `scripts/publish.sh testnet --create-gate` (paid gate, 0.005 SUI, soulbound, 1 use): package `0x47fdd6f8a0d33186d6714361fed5c59bc3d3dff19411c57e5a0f5e04faed11ce` (tx `8mzSBRPQtwYAsuQsWyk5KQPFDXmXjRzb939jiBSPZG62`), `PlatformConfig` `0xe9ab0a59…e5c1`, gate `0xf649f0ca…afc2`.
  - **Multisig:** `scripts/multisig-address.sh` (threshold 2, weights 1 1, keys `0xb674a708…e3c` and `0xbe210acd…4182`) gave `0x447853c8de49efc0d344a54bad230fab16f9b3975110af8671364b223ae33ea9`; it was funded with 0.15 SUI (`AdtHnSMUtqcdFCzDs7eVbq3R973ewkdUBR2B7SbH35aR`).
  - **Transfer:** `transfer-platform-authority.sh --include-upgrade-cap` (dry run first; `YES` and `UPGRADECAP`): PlatformAdminCap `FRjnKWTLtTTSPFpiYqBjKazgZ18H3KrSh5gBDvqqEk9M`, Publisher `CVd56mj1viRVVnZHAAhHnXqXitjpZcWrqMFWRiZR1X9V`, Display<AccessNFT> `9zis5HSuQCPayHdNA3svfR1bpGuZ1fAwBUHQiHDtCGXJ`, Display<SoulboundAccessNFT> `8XDyM9EHU1No91QumsSAqLBAKJWjMMz7wrKjG9bjoz4N`, UpgradeCap `ErzPAj46wEN7EcTW38bh2iB7dewWdpQgDrQzbnjmtRsE`; each re-read as owned by the multisig; `deployments.json` recorded it; `plannedBurnDate` set by hand.
  - **Upgrade:** `VERSION` 1 → 2; `sui client upgrade --sender <multisig> --serialize-unsigned-transaction` failed on CLI 1.81.0 (`protocol version 139 is newer than the maximum version 138 supported by this CLI`, F49) and built on 1.82.2; both members signed, `multi-sig-combine-partial-sig`, `execute-signed-tx`: tx `E1jsVrjMhMRFGLwwhJrTGbKaDDxV47aDNWGcXGCuwEZW`, v2 package `0x12d5014537b14b567e6deb8ecfe255a841d78bb39573dc5ae2cc33e5f669c5af` (cost the multisig 0.0732 SUI). Before `migrate`: `purchase` dry run on v1 succeeds, on v2 aborts 13.
  - **`migrate`:** `sui client ptb --move-call <v2>::access_gate::migrate` as the multisig, signed by both: `BEMeJ7oCX2SzvYfn3gmcsaKLxYU8YQdMcYcWD9rfrYLr`, `PlatformMigratedEvent { from_version: 1, to_version: 2 }`. After it: `purchase` on the old published-at aborts 13 in `check_version`, on v2 it succeeds.
  - **Burn:** `make-immutable.sh` refused at first (F49); with the fix, `DRY_RUN=0` wrote the unsigned transaction and both signatures executed it: `Eui26pAVBmeicw9P9chig8eqzR1jrDHnPi7iewK1p1Zo` (deleted object `0x2::package::UpgradeCap`; a read of the cap returns "not found").
  - **After the burn (v2, immutable):** a multisig-signed `set_free_gate_fee_mist` (`HsFd7wypsce34vKWeozUzK1ttrXNsVK94UereKRKvUPT`, `PlatformConfigUpdatedEvent`), then `make_gate_free` `3cJb3jJ9H7wo6Ff525F49m5nmkmddBAQNCxdX9e7XKLe`, a free purchase `AkuTybQC252jTgQ3jRvX8t6gr9c3N2mHvg19iUoFo9aR`, consume `AtfomeiPyh7HSb69ReK6hX32CZR5DJ985ApN6w5DDd1j` and `make_gate_immutable` `3YxU2MnRT1Ed4bvwrHCmPep2knMviConQtn6yYWZxeCC`: the platform authority works from the multisig after the cap is gone, and the gate lifecycle events these produce fed the sui-indexer F24 parity check (kinds `GateMadeFree`, `PlatformConfigUpdated`, `PlatformMigrated`).
  - **Fixed (F49, 0.0.8, commit pending):** `scripts/make-immutable.sh`, `tests/scripts/make_immutable_test.sh` (new, 5 cases; 4 fail on the old script; shellcheck clean), `move-ci.yml` (shellcheck over `tests/scripts` and the test), `CUSTODY.md` (current CLI for the upgrade, record the new `published-at`, the testnet rehearsal). `sui move test` 94/94 unchanged.
  - **Dispositions (49 findings):** RESOLVED 34 (adds F49), Positive 7, ADJUDICATED 3, MITIGATED 1, ACCEPTED-RISK 2, DEFERRED 2 (F2, F3, mainnet-blocked). Section D: the OQ21 box and the C.2 box are ticked; the mainnet boxes are unchanged. Cost to the runner: about 0.15 SUI to the multisig (a throwaway address) and 0.03 SUI of fees.
  - **Not exercised:** a mainnet publication; the live `0xd7ddaa94…` caps (deliberately); `transfer-platform-authority.sh` without `--include-upgrade-cap`; a threshold below the number of members (the rehearsal used 2-of-2).

## Pre-save consistency checklist (this pass)

- [x] Section A ↔ findings — only I11 (F3, DEFERRED mainnet-blocked) is a GAP; I3, I4b, I5, I6, I8b, I8c, I18,
  I19, I20 and I21 moved to HOLDS with the fixing finding cited.
- [x] Finding header ↔ body — the stale `0xa55789…`/`0xfd6c3b…`/`0x61c4aa…` statements are limited to
  history lines, the superseded-package rows and "superseded" sentences; "85/85", "92.70%", "16 files",
  "gateways 0.0.17" removed.
- [x] Template line lists the base + SUI + OPS + TS (npm rows) + SUI_CLIENT (script PTB) with dates
  (`check-template-dates.mjs` passes).
- [x] Closing structure in order; normative items numbered sequentially.
- [x] Open questions: none deleted or renumbered; decisions use `(Decided YYYY-MM-DD: …)`; OQ3, OQ6,
  OQ8, OQ9, OQ12, OQ20, OQ21 stay open (OQ16 decided 2026-10-19).
- [x] Section D ↔ dispositions — unticked items are mainnet-blocked or maintainer-only and say which.
- [x] Executive summary reflects the current dispositions.
- [x] Counts and versions re-measured 2026-10-09 (tests 94, coverage 100.00%, CLI 1.81.0, npm 0.0.6 / 15
  files, IDs read on-chain).
- [x] Re-verification log entry added.
- [x] 2026-10-22 (close-out): OQ6, OQ8, OQ12 and OQ21 carry their decisions; F20 and F48 confirmed; log entry added; no counts change.
- [x] 2026-10-22 (testnet rehearsal): F49 added (RESOLVED); the OQ21 and C.2 Section D boxes ticked with digests; counts 49 findings (RESOLVED 34); log entry added.
