# access_gate — generic NFT access gate (Move)

A small, reusable Sui Move package for **NFT-gated access** to any resource: an upload
relay, a members-only website, a gacha pull, an API — anything a server or contract wants
to restrict to holders of a specific NFT. It knows nothing about any particular consumer.

## What it provides

- **`Gate`** — a shared object describing one access class: price, payment recipient,
  default access model, transferability, and exhaustion policy.
- **`AccessNFT`** (transferable) and **`SoulboundAccessNFT`** (non-transferable) — the proof
  a holder presents. A gate mints one flavour, chosen at creation.
- **Access models** — an *unlimited pass* (`default_uses == 0`) or a *single-use* NFT
  (`default_uses == N`) whose entitlement is spent by `consume`.
- **Permissionless `purchase`** — anyone may buy access at the gate's price; payment is
  routed to the recipient and an NFT is minted to the buyer atomically.
- **On-chain single-use** — `consume(nft, gate, platform, nonce)` decrements a use and emits
  `AccessConsumedEvent` carrying the caller-supplied `nonce` (≥ 8 bytes) and the `consumer`
  address, so an off-chain verifier can bind one grant to one on-chain consumption. Replay
  protection (nonce uniqueness and freshness) is the verifier's job — see
  [SECURITY.md](SECURITY.md) and [docs/onchain/dev-guide.md](docs/onchain/dev-guide.md).
- **Platform commission and fees** — a shared `PlatformConfig` routes the commission on every paid
  mint (0.2% by default, never less than `min_commission_mist` — 0.001 SUI — and never more than 10%
  of the price) to the platform treasury, and charges a one-off `free_gate_fee_mist` (0.1 SUI) to
  make a gate free. Airdrops pay the commission too.

## Quick start

```bash
sui move test --build-env testnet   # 85 unit tests
./scripts/publish.sh testnet --create-gate   # publish + bootstrap a first gate
```

`--create-gate` reads `GATE_PRICE_MIST` (0 = free gate, paying the free-gate fee),
`GATE_PAYMENT_RECIPIENT`, `GATE_DEFAULT_USES`, `GATE_SOULBOUND`, `GATE_AUTO_BURN`, the NFT display
fields and the four `GATE_*` policy flags (all optional). IDs and the NFT type string are written
to `.env.<network>` for the gateway and frontend to consume.

## Entry points

| Function | Auth | Purpose |
| --- | --- | --- |
| `create_gate(platform, price_mist, payment_recipient, default_uses, soulbound, auto_burn_at_zero, nft_name, nft_image_url, nft_description, policy)` | permissionless | Share a paid `Gate` (price ≥ `min_paid_price_mist`), grant the caller an `AdminCap`. |
| `create_free_gate(platform, payment, payment_recipient, …, policy)` | permissionless | As above for a free gate, paying the free-gate fee. |
| `new_gate_policy(freeze_requires_unpaused, lock_commission_on_freeze, pause_blocks_decryption, pause_blocks_access)` / `default_gate_policy()` | — | Build the immutable per-gate policy. |
| `purchase(gate, platform: &PlatformConfig, payment: Coin<SUI>)` | permissionless | Pay the price (commission split), mint the NFT to sender, refund overpayment. |
| `consume(nft, gate, platform, nonce)` / `consume_soulbound(...)` | NFT owner (by value) | Spend one use; emit `AccessConsumedEvent{nonce, consumer}`; burn-at-zero if the gate opts in, else keep as receipt. |
| `airdrop(cap, gate, platform, payment, recipient)` | `AdminCap` | Grant a pass; the admin pays the commission a sale would carry. |
| `burn(nft)` / `burn_soulbound(nft)` | NFT owner | Voluntary destroy. |
| `set_price(cap, gate, platform, price)` / `make_gate_free(cap, gate, platform, payment)` | `AdminCap` | Re-price (paid ≥ minimum; 0 only once the free-gate fee is paid). |
| `set_paused` / `set_payment_recipient` / `set_default_uses` / `set_soulbound` / `set_auto_burn_at_zero` / `set_nft_name` / `set_nft_image_url` / `set_nft_description` — each `(cap, gate, platform, value)` | `AdminCap` | Reconfigure the gate. |
| `make_gate_immutable(cap, gate, platform: &PlatformConfig)` | `AdminCap` (consumed) | Irreversibly freeze the gate's config (refused while paused if the policy says so; snapshots the commission if the policy locks it). |
| `set_platform_treasury` / `set_commission_bps` / `set_min_commission_mist` / `set_free_gate_fee_mist` | `PlatformAdminCap` | Platform treasury and terms (rate ≤ 1000 bps). |
| `migrate(cap, platform)` | `PlatformAdminCap` | After an upgrade that bumps `VERSION`, move `PlatformConfig` to it; every older version then aborts (`E_WRONG_VERSION`). |

Every function that changes shared state, mints or consumes takes `&PlatformConfig` and works only
from the package version it names (see "Versioning" in `sources/access_gate.move`).

The full reference (objects, events, abort codes, views) is in
[docs/onchain/api-reference.md](docs/onchain/api-reference.md).

## Events

`GateCreatedEvent`, `AccessMintedEvent`, `AccessConsumedEvent` (carries `nonce` + `consumer`),
`AccessBurnedEvent`, `GateFrozenEvent` (carries the locked commission terms, if any),
`GateMadeFreeEvent`, `PlatformConfigUpdatedEvent`, `PlatformMigratedEvent`. Off-chain indexers subscribe to these; the consume event's `nonce` is
the binding key for single-use verification.

## Consuming this package as a dependency

Other Move packages depend on `access_gate` via a **git dependency pinned to a commit SHA** (Move
has no crates.io — packages are resolved from git or a local path). Pin a SHA, not a tag: tags are
mutable (`v0.0.1` has already been moved), and the commit determines which on-chain address your
package links against:

```toml
[dependencies]
# Pin the commit whose Published.toml records the publication you link against (seal-policies-sui's
# Move.toml shows the current one). See docs/audit/access-gate-sui-audit.md for the address history.
access_gate = { git = "https://github.com/meddleware-org/access-gate-sui.git", rev = "<full commit SHA>" }
```

**Release = push a tag.** Move consumers resolve the git commit directly; a `v*` tag also runs the
`Publish (npm)` workflow, which ships `Published.toml` and `deployments.json` to
`@meddleware/access-gate-sui` for the TypeScript client (trusted publishing). Bump `package.json`, then:

```bash
git tag v0.0.5 && git push origin v0.0.5
```

(The on-chain deployment is separate — `./scripts/publish.sh testnet` — and only needs redoing when
the Move source changes.)

**Deployment records.** `Published.toml` holds the package IDs per network (published-at and
original-id); `deployments.json` holds the shared objects consumers need (`platformConfigId`),
written by `publish.sh`. Both ship in the npm package, and `@meddleware/access-gate-client`
generates its `deployments` export from them — commit both after every publish.

## Operations runbook

Every script refuses to sign unless the active `sui client` env **is** the target network (it
never switches it), the chain identifier matches (testnet/mainnet), and the `sui` CLI major.minor
matches `Published.toml`'s `toolchain-version`. Mainnet additionally needs `MAINNET_CONFIRM=1`
(a skipped run exits `78`).

| Script | Purpose | Dry run | Execute | Recovery |
| --- | --- | --- | --- | --- |
| `scripts/publish.sh <net> [--create-gate] [--make-immutable]` | Publish, optionally create the first gate; `--make-immutable` burns the UpgradeCap at once (throwaway publishes only — a full release follows [CUSTODY.md](CUSTODY.md)) | — (publishing is the action; the burn asks for its own `BURN <id prefix>` confirmation) | as shown | IDs are written to `.env.<net>` (the previous record is kept as `.env.<net>.<timestamp>.bak`) and the PlatformConfig and custody record to `deployments.json`. If gate creation fails, re-run only the gate PTB against the recorded package/config IDs — never re-publish |
| `scripts/transfer-platform-authority.sh` | Move `PlatformAdminCap`, `Publisher` and both `Display`s (plus the UpgradeCap with `--include-upgrade-cap`) to a multisig | `NETWORK=<net> MULTISIG_ADDRESS=0x… bash scripts/transfer-platform-authority.sh` (default) | `DRY_RUN=0 …` then `YES` (and `UPGRADECAP` for the cap) | Each object is re-verified (type, package, owner) before sending, and `deployments.json` records the multisig; after a partial failure, re-run — objects already transferred are refused, the rest proceed |
| `scripts/make-immutable.sh` | Burn the UpgradeCap on the planned date (CUSTODY.md step 5). The deploy key burns it directly; a multisig-owned cap gets an unsigned transaction and the signing steps | `NETWORK=<net> bash scripts/make-immutable.sh` (default) | `DRY_RUN=0 …` then `YES` (direct), or sign and execute the written transaction (multisig) | Checks the cap's type and package first; the cap still existing after a direct burn is an error. Records the burn in `deployments.json` |
| `scripts/multisig-address.sh` | Derive the custody multisig address from public keys, weights and a threshold | `MULTISIG_PKS=… MULTISIG_WEIGHTS=… MULTISIG_THRESHOLD=… bash scripts/multisig-address.sh` | — (read-only) | — |

## Custody

Every full release follows [CUSTODY.md](CUSTODY.md): publish from the deploy key, transfer the
UpgradeCap and platform objects to the multisig, launch, verify during the planned window, then the
multisig burns the UpgradeCap on the planned date. `PlatformAdminCap` stays with the multisig.
`deployments.json` records the custody state per network.

## Security & audit

- [SECURITY.md](SECURITY.md) — scope, invariants, reporting.
- [docs/audit/access-gate-sui-audit.md](docs/audit/access-gate-sui-audit.md) — internal audit.

## License

BSD Zero Clause License (`0BSD`) — see [LICENSE](LICENSE).
