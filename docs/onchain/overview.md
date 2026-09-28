---
title: Access Gate — on-chain overview
---

# Access Gate — on-chain overview

`access_gate` is a small, generic Sui Move package for **NFT-gated access**. A **Gate** describes
one access class (a price, who gets paid, and what kind of pass it mints). Buying from a gate mints
an **access NFT** — the proof a holder presents to whatever the gate protects: an upload relay, a
members-only site, an API, encrypted content, or anything else. The package knows nothing about any
particular consumer.

## What lives on-chain

| Object | Kind | Purpose |
| --- | --- | --- |
| `Gate` | shared | One access class: price, payment recipient, pass flavour, pause/freeze state, NFT display defaults. |
| `AdminCap` | owned (gate creator) | Authority over exactly one gate: change settings, airdrop, freeze. |
| `AccessNFT` | owned, **transferable** | A pass that can be sent or traded. |
| `SoulboundAccessNFT` | owned, **non-transferable** | A pass bound to the wallet that received it. |
| `PlatformConfig` | shared (one per package) | Platform treasury address and commission rate (≤ 10%). |
| `PlatformAdminCap` | owned (platform operator) | Authority to change the platform treasury and commission. |

## Pass flavours

- **Unlimited pass** (`default_uses = 0`) — valid for as long as it is held.
- **Single-use pass** (`default_uses = N`) — carries `N` uses; each use is spent on-chain by the
  holder calling `consume`, which records a one-time `nonce` supplied by the service being accessed.

## Money flow

`purchase` is permissionless and atomic: the buyer pays at least the gate price; the platform
commission (`commission_bps`, default 0.2%, capped at 10%, rounded down) goes to the platform
treasury, the rest to the gate's payment recipient, any overpayment is refunded, and the pass is
minted to the buyer — all in one transaction.

## Trust boundaries (summary)

- The **chain** enforces ownership, pass validity per gate, use counts, payment routing and the
  commission cap.
- A **gate creator** controls their own gate until they freeze it (`make_gate_immutable`), which is
  irreversible.
- The **platform operator** can change the treasury and commission (≤ 10%) for every gate of this
  package, including frozen ones — except frozen gates whose policy locked the commission.
- Each gate carries an immutable **policy** chosen at creation (freeze-while-paused, commission lock,
  pause blocks decryption); the tool that creates a gate decides it, and buyers can read it.
- **Off-chain services** that accept passes are responsible for replay protection when they rely on
  single-use consumption — see the [developer guide](dev-guide.md).

Deployed testnet package: `0x0bedd0b27d993d3292ca6a5315f7562de8bc0ff3752b445b4c53252c76f2d20d`
(canonical; used by every Meddleware app; predates gate policies). Mainnet: not yet published.
