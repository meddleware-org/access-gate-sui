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
- **On-chain single-use** — `consume(nft, nonce)` decrements a use and emits
  `AccessConsumedEvent` carrying the caller-supplied `nonce`, so an off-chain verifier can
  bind one grant to one on-chain consumption (replay-proof). See
  [../../../../docs/single-use-semantics.md](../../../../docs/single-use-semantics.md).

## Quick start

```bash
sui move test                 # 16 unit tests
./scripts/publish.sh testnet --create-gate   # publish + bootstrap a first gate
```

`--create-gate` reads `GATE_PRICE_MIST`, `GATE_PAYMENT_RECIPIENT`, `GATE_DEFAULT_USES`,
`GATE_SOULBOUND`, `GATE_AUTO_BURN` (all optional). IDs and the NFT type string are written
to `.env.<network>` for the gateway and frontend to consume.

## Entry points

| Function | Auth | Purpose |
| --- | --- | --- |
| `create_gate(price, recipient, default_uses, soulbound, auto_burn_at_zero)` | permissionless | Share a `Gate`, grant the caller an `AdminCap`. |
| `purchase(gate, payment: Coin<SUI>)` | permissionless | Pay the price, mint the NFT to sender, refund overpayment. |
| `consume(nft, gate, nonce)` / `consume_soulbound(...)` | NFT owner | Spend one use; emit `AccessConsumedEvent{nonce}`; burn-at-zero if the gate opts in, else keep as receipt. |
| `airdrop(cap, gate, recipient)` / `mint_to` | `AdminCap` | Free grant. |
| `burn(nft)` / `burn_soulbound(nft)` | NFT owner | Voluntary destroy. |
| `set_price` / `set_paused` / `set_payment_recipient` / `set_default_uses` / `set_soulbound` / `set_auto_burn_at_zero` | `AdminCap` | Reconfigure the gate. |

## Events

`GateCreatedEvent`, `AccessMintedEvent`, `AccessConsumedEvent` (carries `nonce`),
`AccessBurnedEvent`. Off-chain indexers subscribe to these; the consume event's `nonce` is
the binding key for single-use verification.

## Consuming this package as a dependency

Other Move packages depend on `access_gate` via a **git dependency pinned to a tag** (Move has no
crates.io — packages are resolved from git or a local path):

```toml
[dependencies]
access_gate = { git = "https://github.com/meddleware-org/access-gate-sui.git", rev = "v0.0.2" }
```

The package's `Move.toml` carries `published-at` (and an `[addresses]` entry) for its on-chain id, so
a consumer resolves `access_gate`'s address automatically — no override needed.

**Release = push a tag.** There is no registry publish step and no CI publish job: a version is
consumable once its `v*` tag exists on GitHub. To cut a release, tag the commit and push it:

```bash
git tag v0.0.2 && git push origin v0.0.2
```

(The on-chain deployment is separate — `./scripts/publish.sh testnet` — and only needs redoing when
the Move source changes.)

## License

CC0-1.0 (public domain). See the repo root.
