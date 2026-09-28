# CLAUDE.md — access_gate

Technical guidance for the `access_gate` Move package. User overview is in
[README.md](README.md); repo-wide policy is in the repo-root
[CLAUDE.md](../../../../CLAUDE.md).

## What this is

A generic NFT access-gate primitive. One module, `access_gate::access_gate`. It is
deliberately **consumer-agnostic** — do not add Walrus/relay/website-specific logic here.
Consumers (a gateway, a frontend, a contract) compose on top.

## Object model

- **`Gate` (shared)** — the access class. Config: `price_mist`, `payment_recipient`,
  `default_uses` (0 ⇒ unlimited pass, N ⇒ single-use with N), `soulbound`,
  `auto_burn_at_zero`, `paused`, immutable `policy`, `locked_commission`, `free_fee_paid`.
  `admin_cap_id` records the authorised cap (auth is by
  `cap.gate_id == object::id(gate)`, checked in `assert_admin`).
- **`AccessNFT has key, store`** vs **`SoulboundAccessNFT has key`** — the presence/absence
  of `store` is the *entire* soulbound mechanism: without `store`, `public_transfer` cannot
  move it, so only this module's `consume`/`burn` can destroy it. Both wrap a shared
  **`AccessData`** (`gate_id`, `variant`, `minted_epoch`) so consume/view logic is written
  once (`consume_data`, `data_uses_remaining`).
- **`AccessVariant`** enum — `UnlimitedPass | SingleUse { uses_remaining }`.

## Invariants (do not break)

1. **Purchase is atomic and permissionless** — price routed to `payment_recipient`, NFT
   minted to sender, overpayment refunded, in one call. No operator co-sign.
2. **Single-use is spent on-chain by the owner.** `consume` requires the NFT by value,
   asserts a ≥ 8-byte `nonce`, `SingleUse` + `uses_remaining > 0`, decrements, and emits
   `AccessConsumedEvent { nonce, consumer }`. A verifier binds a challenge to a consumption via
   that `nonce` + `consumer` and enforces nonce uniqueness/freshness itself — never trust a bare
   address. Off-chain systems cannot decrement an NFT.
3. **`E_WRONG_GATE` guards cross-gate use** — `consume`/admin setters assert the NFT/cap
   belongs to the supplied gate.
4. **Exhaustion policy is the gate's choice** — `auto_burn_at_zero` true ⇒ `object::delete`
   at zero; false ⇒ return the zero-use NFT as a receipt. Never force-burn unconditionally.
5. **Emit before delete** — capture `object::id` before unpacking; `AccessBurnedEvent` is
   emitted with the id, then `id.delete()`.
6. **Commission arithmetic never overflows** — `commission_for` multiplies in u128 and rounds
   down; `commission_bps` ≤ 1000; the platform treasury is never `@0x0`.
7. **`GatePolicy` is immutable per gate** — set by `create_gate`/`create_free_gate`, no setter.
   Mints use `effective_commission_terms` (freeze snapshot if locked, else live terms).
   `pause_blocks_access` is enforced here (`consume` aborts) and by gateways;
   `pause_blocks_decryption` only by dependants (`seal_policies::nft_gate`).
8. **The platform is always paid** — commission = `max(bps share, min_commission)` capped at 10%;
   paid price ≥ `min_paid_price_mist`; price 0 only after the free-gate fee; airdrops pay the
   commission.

## Error codes

`E_PAUSED=1`, `E_INSUFFICIENT_PAYMENT=2`, `E_NOT_SINGLE_USE=3`, `E_NO_USES_REMAINING=4`,
`E_WRONG_GATE=5`, `E_GATE_FROZEN=6`, `E_COMMISSION_TOO_HIGH=7`, `E_INVALID_NONCE=8`,
`E_ZERO_ADDRESS=9`, `E_FREEZE_WHILE_PAUSED=10`, `E_PRICE_TOO_LOW=11`, `E_FREE_FEE_UNPAID=12`.
Tests reference these by literal in `#[expected_failure(abort_code = …)]` because
module-private constants are not cross-module referenceable in that attribute — keep the
literal and the constant in sync if you renumber.

## Testing

`sui move test --build-env testnet` — 60 tests (`tests/access_gate_tests.move`): `init` defaults,
gate creation, purchase (exact/overpay/free/underpay/paused, commission split, u64::MAX price at
the 10% cap, dust rounding), single-use decrement + receipt vs auto-burn, every abort code on both
the transferable and soulbound paths, foreign-cap and frozen-gate guards, platform setters, voluntary
burns, gate policies, the commission floor/cap, minimum price, free-gate fee paths and airdrop
commission. Every abort code has an `expected_failure` test — keep it that way for new
entries/branches.

## Working rules

- Keep it dependency-free (only Sui framework). Generality is the point.
- New config → add a field to `Gate` + an `AdminCap`-gated setter + a `GateCreatedEvent`
  field + a view + tests.
- If you touch the ABI (entry signatures, event fields), update the TS client
  (`packages/nft-gate-client`) and the Rust gateway (`gateway/`) — they mirror this.

---

## Deferred documentation — NOT for the `docs.` website (planned here per Part 0.4)

> Captured for the future **`dev.meddleware.co.uk`** subdomain and white-label offering; excluded
> from the user-facing `docs.` site (which explains gates for operators and buyers in plain terms).

### `dev.` — developer/integrator reference (to write later)

- **Curated contract reference** (Move has no clean autodoc — author from source): entry-function
  signatures (`create_gate`, `purchase`, `consume`, `airdrop`, `burn`, admin setters), object shapes
  (`Gate`, `AccessNFT`/`SoulboundAccessNFT`, `AdminCap`, `AccessData`/`AccessVariant`), event schemas
  (`GateCreated`/`AccessMinted`/`AccessConsumed`{`nonce`}/`AccessBurned`), and the error-code table.
  These same tables feed the docs-site Access Gate *reference* page and the `dev.` deep-dive.
- **Composition guide:** how a gateway/frontend/contract composes on the consumer-agnostic primitive;
  the `consume`→`nonce` binding that verifiers must use (never trust a bare address).

### White-label (to write later)

- Operators deploying their **own gate set** under the shared platform (commission enforced by
  `PlatformConfig`); which knobs are gate-owner-controlled (`price_mist`, `default_uses`, `soulbound`,
  `auto_burn_at_zero`, `paused`) vs platform-only (`set_platform_treasury`, `set_commission_bps`).
