---
title: Access Gate — using passes and gates
---

# Access Gate — using passes and gates

This page explains what you can do with an access gate on-chain, who can do it, and what to watch
for. You normally do all of this through an app (for example the Access Gate console or the Walrus
uploader); the app builds the transaction and your wallet signs it.

## If you are buying or holding a pass

| Action | Who can do it | What happens |
| --- | --- | --- |
| **Buy a pass** | anyone, while the gate is not paused | You pay the gate price (plus network gas); the pass is minted to your wallet; any overpayment is refunded. |
| **Use a single-use pass** | only the wallet that holds the pass | One use is spent on-chain. When uses reach zero the pass is either deleted or kept as a zero-use receipt — the gate decides. |
| **Transfer a pass** | the holder — **transferable passes only** | Soulbound passes can never be transferred. |
| **Destroy a pass** | the holder | The pass is burned permanently. |

Things to know:

- **Soulbound means soulbound.** A soulbound pass cannot be moved to another wallet — not even by
  you. If you lose access to the wallet, the pass is gone.
- **A use is spent when the app asks you to approve a "consume" transaction.** Approving it is what
  proves to the service that you used your pass for that request.
- **Pausing** a gate stops new purchases; it does not revoke passes already held.
- A single-use pass that is used up cannot authorise anything, even if it is kept as a receipt.

## If you run a gate

| Action | Who can do it |
| --- | --- |
| Create a gate (price, recipient, pass flavour, soulbound, auto-burn, NFT name/image/description) | anyone |
| Change price, recipient, pause, pass flavour, auto-burn, NFT display defaults | the gate's `AdminCap` holder |
| Give passes for free (airdrop) | the gate's `AdminCap` holder |
| **Freeze** the gate (make it immutable) | the gate's `AdminCap` holder — irreversible |

Things to know:

- **Freezing is permanent.** After `make_gate_immutable` nobody can change the gate or airdrop from
  it again. Purchases and uses keep working. **If you freeze a paused gate, it can never sell again.**
- **Auto-burn applies to existing passes.** The auto-burn setting is read when a pass is used, so
  changing it affects passes that were already minted.
- **The platform commission is not frozen with your gate.** The platform operator can change the
  commission (never above 10%) for all gates, including frozen ones.
- **Very small prices pay no commission.** The commission is rounded down; at the default 0.2% any
  price under 500 MIST pays none.
- Keep your `AdminCap` safe: whoever holds it controls your gate's price and payout address.

## Limits and safety notes

- The chain guarantees a pass for one gate can never be used for another gate.
- The chain does **not** stop a service from accepting the same consumption twice — well-built
  services track each one-time challenge themselves. Only use services you trust.
- Prices are in MIST (1 SUI = 1,000,000,000 MIST).
