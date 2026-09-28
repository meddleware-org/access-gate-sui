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
| Create a gate (price, recipient, pass flavour, soulbound, auto-burn, NFT name/image/description) | anyone — a paid gate costs at least 0.01 SUI per pass; a free gate pays a one-off platform fee |
| Change price, recipient, pause, pass flavour, auto-burn, NFT display defaults | the gate's `AdminCap` holder |
| Give passes away (airdrop) — free for the recipient; the admin pays the platform commission a sale would carry | the gate's `AdminCap` holder |
| **Freeze** the gate (make it immutable) | the gate's `AdminCap` holder — irreversible |

Things to know:

- **Freezing is permanent.** After `make_gate_immutable` nobody can change the gate or airdrop from
  it again. Purchases and uses keep working. **If you freeze a paused gate, it can never sell again**
  — unless the gate's policy forbids freezing while paused (see below), in which case the freeze is
  refused until you unpause.
- **Auto-burn applies to existing passes.** The auto-burn setting is read when a pass is used, so
  changing it affects passes that were already minted.
- **The platform commission is not frozen with your gate** — unless the gate's policy locks it.
  Otherwise the platform operator can change the commission (never above 10%) for all gates,
  including frozen ones.
- **A gate's policy is permanent.** Some tools create gates with extra rules, recorded on the gate
  when it is created and visible to everyone: *no freezing while paused*, *freezing locks in the
  commission*, *pausing also blocks unlocking of protected content* and *pausing also stops passes
  from being used* (e.g. uploads to the Walrus relay). They can never be changed
  afterwards.
- **Commission and minimum price.** Each sale pays the platform 0.2% of the price, but at least
  0.001 SUI and never more than 10% of the price — so a paid pass costs at least 0.01 SUI.
- **Free gates.** Making a gate free (at creation, or later by setting its price to 0) costs a
  one-off platform fee; after that its price can go back and forth between free and paid.
- Keep your `AdminCap` safe: whoever holds it controls your gate's price and payout address.

## Limits and safety notes

- The chain guarantees a pass for one gate can never be used for another gate.
- The chain does **not** stop a service from accepting the same consumption twice — well-built
  services track each one-time challenge themselves. Only use services you trust.
- Prices are in MIST (1 SUI = 1,000,000,000 MIST).
