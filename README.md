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
- **On-chain single-use** — `consume(nft, gate, nonce)` decrements a use and emits
  `AccessConsumedEvent` carrying the caller-supplied `nonce` (≥ 8 bytes) and the `consumer`
  address, so an off-chain verifier can bind one grant to one on-chain consumption. Replay
  protection (nonce uniqueness and freshness) is the verifier's job — see
  [SECURITY.md](SECURITY.md) and [docs/onchain/dev-guide.md](docs/onchain/dev-guide.md).
- **Platform commission** — a shared `PlatformConfig` routes `commission_bps` (≤ 10%, default
  0.2%) of every paid purchase to the platform treasury.

## Quick start

```bash
sui move test --build-env testnet   # 36 unit tests
./scripts/publish.sh testnet --create-gate   # publish + bootstrap a first gate
```

`--create-gate` reads `GATE_PRICE_MIST`, `GATE_PAYMENT_RECIPIENT`, `GATE_DEFAULT_USES`,
`GATE_SOULBOUND`, `GATE_AUTO_BURN` (all optional). IDs and the NFT type string are written
to `.env.<network>` for the gateway and frontend to consume.

## Entry points

| Function | Auth | Purpose |
| --- | --- | --- |
| `create_gate(price_mist, payment_recipient, default_uses, soulbound, auto_burn_at_zero, nft_name, nft_image_url, nft_description)` | permissionless | Share a `Gate`, grant the caller an `AdminCap`. |
| `purchase(gate, platform: &PlatformConfig, payment: Coin<SUI>)` | permissionless | Pay the price (commission split), mint the NFT to sender, refund overpayment. |
| `consume(nft, gate, nonce)` / `consume_soulbound(...)` | NFT owner (by value) | Spend one use; emit `AccessConsumedEvent{nonce, consumer}`; burn-at-zero if the gate opts in, else keep as receipt. |
| `airdrop(cap, gate, recipient)` | `AdminCap` | Free grant. |
| `burn(nft)` / `burn_soulbound(nft)` | NFT owner | Voluntary destroy. |
| `set_price` / `set_paused` / `set_payment_recipient` / `set_default_uses` / `set_soulbound` / `set_auto_burn_at_zero` / `set_nft_name` / `set_nft_image_url` / `set_nft_description` | `AdminCap` | Reconfigure the gate. |
| `make_gate_immutable(cap, gate)` | `AdminCap` (consumed) | Irreversibly freeze the gate's config. |
| `set_platform_treasury` / `set_commission_bps` | `PlatformAdminCap` | Platform commission routing / rate (≤ 1000 bps). |

The full reference (objects, events, abort codes, views) is in
[docs/onchain/api-reference.md](docs/onchain/api-reference.md).

## Events

`GateCreatedEvent`, `AccessMintedEvent`, `AccessConsumedEvent` (carries `nonce` + `consumer`),
`AccessBurnedEvent`, `GateFrozenEvent`. Off-chain indexers subscribe to these; the consume event's `nonce` is
the binding key for single-use verification.

## Consuming this package as a dependency

Other Move packages depend on `access_gate` via a **git dependency pinned to a commit SHA** (Move
has no crates.io — packages are resolved from git or a local path). Pin a SHA, not a tag: tags are
mutable (`v0.0.1` has already been moved), and the commit determines which on-chain address your
package links against:

```toml
[dependencies]
# f191c2d resolves access_gate to the canonical testnet package 0x0bedd0… (used by every live
# consumer and the live gates). See docs/audit/access-gate-sui-audit.md for the address question.
access_gate = { git = "https://github.com/meddleware-org/access-gate-sui.git", rev = "f191c2d338006c056d4ecfafa9bb0404afed37a5" }
```

**Release = push a tag.** There is no registry publish step and no CI publish job: a version is
consumable once its `v*` tag exists on GitHub. To cut a release, tag the commit and push it:

```bash
git tag v0.0.2 && git push origin v0.0.2
```

(The on-chain deployment is separate — `./scripts/publish.sh testnet` — and only needs redoing when
the Move source changes.)

## Security & audit

- [SECURITY.md](SECURITY.md) — scope, invariants, reporting.
- [docs/audit/access-gate-sui-audit.md](docs/audit/access-gate-sui-audit.md) — internal audit.

## License

BSD Zero Clause License (`0BSD`) — see [LICENSE](LICENSE).
