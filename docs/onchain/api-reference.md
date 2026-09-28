---
title: Access Gate — on-chain API reference
---

# Access Gate — on-chain API reference

Module `access_gate::access_gate` (`sources/access_gate.move`), Move 2024. All functions are
`public` (callable from PTBs and other packages); there are no `entry`-only functions.

Testnet package `0x1a81ca177db039585e575beeeee4759466e55910e936a6733e38dbb65025eea4`,
`PlatformConfig` `0xe3b949cabe9a0574c03dfc924fb3f96e6f959f2bb86d053ed6229a241c3a23f7`.

## Objects

| Type | Abilities | Fields |
| --- | --- | --- |
| `Gate` | `key` (shared) | `admin_cap_id: ID`, `price_mist: u64`, `payment_recipient: address`, `default_uses: u64`, `soulbound: bool`, `auto_burn_at_zero: bool`, `paused: bool`, `frozen: bool`, `nft_name: String`, `nft_image_url: String`, `nft_description: String`, `policy: GatePolicy`, `locked_commission: Option<CommissionTerms>`, `free_fee_paid: bool` |
| `GatePolicy` | `copy, drop, store` | `freeze_requires_unpaused`, `lock_commission_on_freeze`, `pause_blocks_decryption`, `pause_blocks_access` (all `bool`) — immutable, set at creation |
| `CommissionTerms` | `copy, drop, store` | `bps: u64`, `min_mist: u64` |
| `AdminCap` | `key, store` | `gate_id: ID` |
| `AccessNFT` | `key, store` (transferable) | `data: AccessData`, `name`, `image_url`, `description` |
| `SoulboundAccessNFT` | `key` (no `store` ⇒ non-transferable) | same as `AccessNFT` |
| `AccessData` | `store` | `gate_id: ID`, `variant: AccessVariant`, `minted_epoch: u64` |
| `AccessVariant` | `copy, drop, store` enum | `UnlimitedPass` \| `SingleUse { uses_remaining: u64 }` |
| `PlatformConfig` | `key` (shared) | `treasury: address`, `commission_bps: u64`, `min_commission_mist: u64`, `free_gate_fee_mist: u64` |
| `PlatformAdminCap` | `key, store` | — |

`init` (on publish) creates `Publisher`, `Display<AccessNFT>`, `Display<SoulboundAccessNFT>` and
`PlatformAdminCap` for the publisher, and shares `PlatformConfig { treasury: publisher,
commission_bps: 20, min_commission_mist: 1_000_000, free_gate_fee_mist: 100_000_000 }`.

## Commission and fees

- **Commission** on a paid mint (`purchase`, or `airdrop` from a paid gate):
  `max(⌊price × bps / 10000⌋, min_mist)`, never more than 10% of the price, computed in u128. The
  terms are the gate's locked snapshot if it froze with `lock_commission_on_freeze`, otherwise the
  live `PlatformConfig` (`effective_commission_terms`).
- **Minimum paid price** (`min_paid_price_mist`): `⌈min_commission_mist × 10⌉`, at least 1 MIST —
  the lowest price at which the commission floor fits under the 10% cap. With the defaults: 0.2%,
  never less than 0.001 SUI, so the minimum paid price is 0.01 SUI.
- **Free gates** pay `free_gate_fee_mist` once — at `create_free_gate`, or at `make_gate_free` for a
  gate created paid. After that the gate may move freely between 0 and a paid price; paid purchases
  always carry the commission, and airdrops pay it too, so no price change or grant avoids it.

## Functions

| Function | Authority | Notes |
| --- | --- | --- |
| `default_gate_policy(): GatePolicy` / `new_gate_policy(freeze_requires_unpaused, lock_commission_on_freeze, pause_blocks_decryption, pause_blocks_access): GatePolicy` | — | Build the policy passed to `create_gate` / `create_free_gate` (in a PTB, use the result). |
| `create_gate(platform: &PlatformConfig, price_mist, payment_recipient, default_uses, soulbound, auto_burn_at_zero, nft_name, nft_image_url, nft_description, policy: GatePolicy, ctx)` | anyone | Paid gate. Aborts 11 if `price_mist < min_paid_price_mist(platform)` (so also for 0). Shares the `Gate`; transfers a bound `AdminCap` to the sender; emits `GateCreatedEvent`. |
| `create_free_gate(platform, payment: Coin<SUI>, payment_recipient, default_uses, soulbound, auto_burn_at_zero, nft_name, nft_image_url, nft_description, policy, ctx)` | anyone | Free gate (price 0). Pays `free_gate_fee_mist` from `payment` to the treasury (aborts 2 if short; excess refunded). |
| `purchase(gate: &Gate, platform: &PlatformConfig, payment: Coin<SUI>, ctx)` | anyone | Aborts 1 if paused, 2 if underpaid. Commission (`gate_commission_mist`) → treasury; rest of the price → `payment_recipient`; overpayment refunded; mints to sender. |
| `airdrop(cap: &AdminCap, gate: &Gate, platform: &PlatformConfig, payment: Coin<SUI>, recipient, ctx)` | `AdminCap` | Free for the recipient; the admin pays `gate_commission_mist` from `payment` (0 for a free gate; excess refunded). Aborts 5 on a foreign cap, 6 on a frozen gate, 2 if short. |
| `consume(nft: AccessNFT, gate: &Gate, nonce: vector<u8>, ctx)` | NFT holder (by value) | Aborts 8 if `nonce` < 8 bytes, 5 if wrong gate, 1 if the gate is paused and its policy has `pause_blocks_access`, 3 on an unlimited pass, 4 at zero uses. Emits `AccessConsumedEvent`; deletes at zero if `auto_burn_at_zero` (read at consume time), else returns the NFT. |
| `consume_soulbound(nft: SoulboundAccessNFT, gate, nonce, ctx)` | NFT holder (by value) | As `consume`. |
| `burn(nft: AccessNFT, ctx)` / `burn_soulbound(nft: SoulboundAccessNFT, ctx)` | NFT holder | Emits `AccessBurnedEvent`, deletes. |
| `assert_admin(cap: &AdminCap, gate: &Gate)` | — | Aborts 5 unless `cap.gate_id == id(gate)`. |
| `set_price(cap, gate: &mut Gate, platform: &PlatformConfig, price_mist)` | `AdminCap` | 0 requires `free_fee_paid` (else 12 — use `make_gate_free`); a paid price must be ≥ `min_paid_price_mist` (else 11). Aborts 5 / 6 as below. |
| `make_gate_free(cap, gate: &mut Gate, platform, payment: Coin<SUI>, ctx)` | `AdminCap` | Pays `free_gate_fee_mist` unless already paid (excess refunded), sets the price to 0, emits `GateMadeFreeEvent`. |
| `set_payment_recipient` / `set_paused` / `set_default_uses` / `set_soulbound` / `set_auto_burn_at_zero` / `set_nft_name` / `set_nft_image_url` / `set_nft_description` `(cap: &AdminCap, gate: &mut Gate, value)` | `AdminCap` | Abort 5 on a foreign cap, 6 on a frozen gate. No events. |
| `make_gate_immutable(cap: AdminCap, gate: &mut Gate, platform: &PlatformConfig, ctx)` | `AdminCap` (consumed) | Aborts 5 on a foreign cap, 10 if paused and the policy has `freeze_requires_unpaused`. With `lock_commission_on_freeze`, snapshots the platform terms into `locked_commission`. Sets `frozen`, emits `GateFrozenEvent`, deletes the cap. Irreversible. |
| `set_platform_treasury(cap: &PlatformAdminCap, config, treasury)` | `PlatformAdminCap` | Aborts 9 on `@0x0`. |
| `set_commission_bps(cap, config, bps)` | `PlatformAdminCap` | Aborts 7 above 1000 (10%). |
| `set_min_commission_mist(cap, config, mist)` / `set_free_gate_fee_mist(cap, config, mist)` | `PlatformAdminCap` | Existing gates keep their price; their commission stays capped at 10% of it. |
| `commission_terms(platform)`, `effective_commission_terms(gate, platform)`, `gate_commission_mist(gate, platform)`, `commission_for_price(price, &terms)`, `min_paid_price_mist(platform)` | — | The commission maths above. |

Every `PlatformConfig` setter emits `PlatformConfigUpdatedEvent` with the resulting configuration.

### Views

`gate_id`, `gate_id_soulbound`, `uses_remaining`, `uses_remaining_soulbound` (→ `Option<u64>`,
`none` = unlimited), `is_valid_for`, `is_valid_for_soulbound`, `gate_price_mist`,
`gate_payment_recipient`, `gate_default_uses`, `gate_is_paused`, `gate_is_frozen`,
`gate_is_soulbound`, `gate_auto_burn_at_zero`, `gate_admin_cap_id`, `admin_cap_gate_id`,
`gate_nft_name`, `gate_nft_image_url`, `gate_nft_description`, `gate_policy`,
`gate_freeze_requires_unpaused`, `gate_lock_commission_on_freeze`, `gate_pause_blocks_decryption`,
`gate_pause_blocks_access`, `gate_locked_commission` (→ `Option<CommissionTerms>`),
`gate_free_fee_paid`, `policy_freeze_requires_unpaused`, `policy_lock_commission_on_freeze`,
`policy_pause_blocks_decryption`, `policy_pause_blocks_access`, `terms_bps`, `terms_min_mist`,
`platform_treasury`, `platform_commission_bps`, `platform_min_commission_mist`,
`platform_free_gate_fee_mist`.

### Gate policy

A `GatePolicy` is chosen once, at creation, and can never change (there is no setter), so buyers can
rely on it. All flags default to `false`:

| Flag | Effect |
| --- | --- |
| `freeze_requires_unpaused` | `make_gate_immutable` aborts 10 while the gate is paused, so a frozen gate can never be stuck unpurchasable. |
| `lock_commission_on_freeze` | Freezing snapshots the platform commission terms; mints on the frozen gate use them, whatever the platform later sets. |
| `pause_blocks_decryption` | Dependent decryption policies (`seal_policies::nft_gate`) deny access while the gate is paused. |
| `pause_blocks_access` | While paused, `consume*` aborts 1 and access gateways (`nft-gate`) deny holders. Independent of `pause_blocks_decryption`. |

Without a restricting flag, pausing only stops purchases. The policy binds the gate, not the
creator's tooling: tools (e.g. `access-gate-ui`) choose which policy their gates carry, and anyone
can read it from the gate.

## Events

All events have `copy, drop`. Timestamps are `ctx.epoch_timestamp_ms()` (epoch start, coarse).

| Event | Emitted by | Fields |
| --- | --- | --- |
| `GateCreatedEvent` | `create_gate`, `create_free_gate` | `gate_id`, `admin_cap_id`, `price_mist`, `default_uses`, `soulbound`, `auto_burn_at_zero`, `nft_name`, `policy`, `free_gate_fee_paid_mist` (0 for a paid gate), `creator`, `timestamp_ms` |
| `AccessMintedEvent` | `purchase`, `airdrop` | `nft_id`, `gate_id`, `soulbound`, `initial_uses` (0 = unlimited), `recipient`, `commission_mist`, `timestamp_ms` |
| `AccessConsumedEvent` | `consume*` | `nft_id`, `gate_id`, `nonce`, `consumer` (tx sender), `uses_after`, `timestamp_ms` — verifiers MUST check `nonce`, `gate_id`, `consumer` |
| `AccessBurnedEvent` | auto-burn in `consume*`, `burn*` | `nft_id`, `gate_id`, `timestamp_ms` — emitted before the object is deleted |
| `GateFrozenEvent` | `make_gate_immutable` | `gate_id`, `locked_commission` (`Option<CommissionTerms>`; `none` = follows the live terms), `timestamp_ms` |
| `GateMadeFreeEvent` | `make_gate_free` | `gate_id`, `fee_paid_mist` (0 if already paid), `timestamp_ms` |
| `PlatformConfigUpdatedEvent` | every platform setter | `treasury`, `commission_bps`, `min_commission_mist`, `free_gate_fee_mist` |

Gate setters other than `make_gate_free` emit no events; read the current `Gate` for configuration.

## Abort codes (`access_gate`)

| Code | Constant | Meaning |
| --- | --- | --- |
| 1 | `E_PAUSED` | Gate is paused: `purchase` disabled; `consume*` too if the policy has `pause_blocks_access`. |
| 2 | `E_INSUFFICIENT_PAYMENT` | Payment, free-gate fee or airdrop commission coin worth less than required. |
| 3 | `E_NOT_SINGLE_USE` | `consume*` on an unlimited pass. |
| 4 | `E_NO_USES_REMAINING` | `consume*` on a pass with zero uses. |
| 5 | `E_WRONG_GATE` | NFT or `AdminCap` belongs to a different gate. |
| 6 | `E_GATE_FROZEN` | Privileged operation on a frozen gate. |
| 7 | `E_COMMISSION_TOO_HIGH` | `commission_bps` above 1000. |
| 8 | `E_INVALID_NONCE` | `nonce` shorter than 8 bytes. |
| 9 | `E_ZERO_ADDRESS` | Platform treasury set to `@0x0`. |
| 10 | `E_FREEZE_WHILE_PAUSED` | `make_gate_immutable` on a paused gate whose policy has `freeze_requires_unpaused`. |
| 11 | `E_PRICE_TOO_LOW` | A paid price below `min_paid_price_mist` (or 0 via `create_gate`). |
| 12 | `E_FREE_FEE_UNPAID` | `set_price(0)` before the free-gate fee is paid. |

Codes are unique within this module only — disambiguate by `(module, code)`.

## Invariants

- A pass for gate A can never be consumed, validated or approved against gate B.
- A soulbound pass cannot leave the wallet it was minted to (no `store`).
- A single-use pass is spent only by its holder, atomically, and cannot go below zero.
- `commission ≤ 10% of the price`; commission arithmetic never overflows; the operator share never
  underflows.
- A gate's price is 0 only after its free-gate fee was paid; otherwise it is ≥ the minimum paid
  price in force when it was set.
- Every paid mint pays the commission to the treasury, including airdrops.
- After `make_gate_immutable`, no privileged operation on that gate can ever succeed.
- A gate's `policy` never changes; `locked_commission` is set at most once (at freeze).

Package version note: the superseded testnet package `0x0bedd0…` (which still holds the live Walrus
relay gate until it migrates) predates all of the above except the base purchase/consume flow: it
multiplies in u64, has no codes 9–12, no policies, fees or airdrop commission.
