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
| `PlatformConfig` | shared (one per package) | Platform treasury, commission terms (rate + minimum) and the free-gate fee. |
| `PlatformAdminCap` | owned (platform operator) | Authority to change the platform treasury, commission terms and free-gate fee. |

## Pass flavours

- **Unlimited pass** (`default_uses = 0`) — valid for as long as it is held.
- **Single-use pass** (`default_uses = N`) — carries `N` uses; each use is spent on-chain by the
  holder calling `consume`, which records a one-time `nonce` supplied by the service being accessed.

## Money flow

`purchase` is permissionless and atomic: the buyer pays at least the gate price; the platform
commission goes to the platform treasury, the rest to the gate's payment recipient, any overpayment
is refunded, and the pass is minted to the buyer — all in one transaction.

- **Commission:** 0.2% of the price by default, but never less than 0.001 SUI and never more than
  10% of the price. A paid gate therefore costs at least 0.01 SUI.
- **Free gates** (price 0) pay a one-off platform fee (0.1 SUI by default) when they are created or
  made free; after that, passes are free to claim.
- **Airdrops** (passes granted by the gate's admin) pay the same commission a purchase would, so a
  gate cannot sell off-chain and grant on-chain to avoid it.

The platform operator sets these terms in `PlatformConfig`; see the
[API reference](api-reference.md#commission-and-fees).

## Trust boundaries (summary)

- The **chain** enforces ownership, pass validity per gate, use counts, payment routing and the
  commission cap.
- A **gate creator** controls their own gate until they freeze it (`make_gate_immutable`), which is
  irreversible.
- The **platform operator** can change the treasury and commission terms (never above 10% of a
  price) for every gate of this package, including frozen ones — except frozen gates whose policy
  locked the commission.
- Each gate carries an immutable **policy** chosen at creation (no freezing while paused, commission
  lock, pause blocks decryption, pause blocks access); the tool that creates a gate decides it, and
  buyers can read it.
- **Off-chain services** that accept passes are responsible for replay protection when they rely on
  single-use consumption — see the [developer guide](dev-guide.md).

Deployed testnet package: `0xa55789d77b8ae41e604c1c2e9ad9f7b034ca69b028ad0f1eee7d7cc8ad886d41`
(`PlatformConfig` `0x53a325dc1ebd083c80fd5bed77e3e7cc989285283f188835793af3a7bd8504fa`). The
superseded `0x1a81ca…` and `0x0bedd0…` packages keep working for gates created on them. Mainnet: not yet published.
