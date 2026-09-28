---
title: Access Gate — on-chain API reference
---

# Access Gate — on-chain API reference

Module `access_gate::access_gate` (`sources/access_gate.move`), Move 2024. All functions are
`public` (callable from PTBs and other packages); there are no `entry`-only functions.

## Objects

| Type | Abilities | Fields |
| --- | --- | --- |
| `Gate` | `key` (shared) | `admin_cap_id: ID`, `price_mist: u64`, `payment_recipient: address`, `default_uses: u64`, `soulbound: bool`, `auto_burn_at_zero: bool`, `paused: bool`, `frozen: bool`, `nft_name: String`, `nft_image_url: String`, `nft_description: String`, `policy: GatePolicy`, `locked_commission_bps: Option<u64>` |
| `GatePolicy` | `copy, drop, store` | `freeze_requires_unpaused: bool`, `lock_commission_on_freeze: bool`, `pause_blocks_decryption: bool` — immutable, set at creation |
| `AdminCap` | `key, store` | `gate_id: ID` |
| `AccessNFT` | `key, store` (transferable) | `data: AccessData`, `name`, `image_url`, `description` |
| `SoulboundAccessNFT` | `key` (no `store` ⇒ non-transferable) | same as `AccessNFT` |
| `AccessData` | `store` | `gate_id: ID`, `variant: AccessVariant`, `minted_epoch: u64` |
| `AccessVariant` | `copy, drop, store` enum | `UnlimitedPass` \| `SingleUse { uses_remaining: u64 }` |
| `PlatformConfig` | `key` (shared) | `treasury: address`, `commission_bps: u64` |
| `PlatformAdminCap` | `key, store` | — |

`init` (on publish) creates `Publisher`, `Display<AccessNFT>`, `Display<SoulboundAccessNFT>` and
`PlatformAdminCap` for the publisher, and shares `PlatformConfig { treasury: publisher,
commission_bps: 20 }`.

## Functions

| Function | Authority | Notes |
| --- | --- | --- |
| `create_gate(price_mist, payment_recipient, default_uses, soulbound, auto_burn_at_zero, nft_name, nft_image_url, nft_description, ctx)` | anyone | Shares the `Gate` with `default_gate_policy()` (no restrictions); transfers a bound `AdminCap` to the sender; emits `GateCreatedEvent`. |
| `create_gate_with_policy(…same 8 values…, policy: GatePolicy, ctx)` | anyone | As `create_gate`, recording `policy` on the gate for good. |
| `new_gate_policy(freeze_requires_unpaused, lock_commission_on_freeze, pause_blocks_decryption): GatePolicy` / `default_gate_policy(): GatePolicy` | — | Build a policy (in a PTB, pass the result to `create_gate_with_policy`). |
| `purchase(gate: &Gate, platform: &PlatformConfig, payment: Coin<SUI>, ctx)` | anyone | Aborts 1 if paused, 2 if underpaid. Commission = ⌊price × `effective_commission_bps` / 10000⌋ (u128, no overflow) → treasury; rest → `payment_recipient`; overpayment refunded; mints to sender. |
| `airdrop(cap: &AdminCap, gate: &Gate, recipient, ctx)` | `AdminCap` | Aborts 5 on a foreign cap, 6 on a frozen gate. |
| `consume(nft: AccessNFT, gate: &Gate, nonce: vector<u8>, ctx)` | NFT holder (by value) | Aborts 8 if `nonce` < 8 bytes, 5 if wrong gate, 3 on an unlimited pass, 4 at zero uses. Emits `AccessConsumedEvent`; deletes at zero if `auto_burn_at_zero` (read at consume time), else returns the NFT. |
| `consume_soulbound(nft: SoulboundAccessNFT, gate, nonce, ctx)` | NFT holder (by value) | As `consume`. |
| `burn(nft: AccessNFT, ctx)` / `burn_soulbound(nft: SoulboundAccessNFT, ctx)` | NFT holder | Emits `AccessBurnedEvent`, deletes. |
| `assert_admin(cap: &AdminCap, gate: &Gate)` | — | Aborts 5 unless `cap.gate_id == id(gate)`. |
| `make_gate_immutable(cap: AdminCap, gate: &mut Gate, platform: &PlatformConfig, ctx)` | `AdminCap` (consumed) | Aborts 5 on a foreign cap, 10 if paused and the policy has `freeze_requires_unpaused`. Snapshots `platform.commission_bps` into `locked_commission_bps` if the policy has `lock_commission_on_freeze`. Sets `frozen`, emits `GateFrozenEvent`, deletes the cap. Irreversible. |
| `effective_commission_bps(gate: &Gate, platform: &PlatformConfig): u64` | — | The locked snapshot if present, else the live `platform.commission_bps`. |
| `set_price` / `set_payment_recipient` / `set_paused` / `set_default_uses` / `set_soulbound` / `set_auto_burn_at_zero` / `set_nft_name` / `set_nft_image_url` / `set_nft_description` `(cap: &AdminCap, gate: &mut Gate, value)` | `AdminCap` | Abort 5 on a foreign cap, 6 on a frozen gate. No events. |
| `set_platform_treasury(cap: &PlatformAdminCap, config: &mut PlatformConfig, treasury)` | `PlatformAdminCap` | Aborts 9 on `@0x0`. |
| `set_commission_bps(cap: &PlatformAdminCap, config: &mut PlatformConfig, bps)` | `PlatformAdminCap` | Aborts 7 above 1000 (10%). |

### Views

`gate_id`, `gate_id_soulbound`, `uses_remaining`, `uses_remaining_soulbound` (→ `Option<u64>`,
`none` = unlimited), `is_valid_for`, `is_valid_for_soulbound`, `gate_price_mist`,
`gate_payment_recipient`, `gate_default_uses`, `gate_is_paused`, `gate_is_frozen`,
`gate_is_soulbound`, `gate_auto_burn_at_zero`, `gate_admin_cap_id`, `admin_cap_gate_id`,
`gate_nft_name`, `gate_nft_image_url`, `gate_nft_description`, `gate_policy`,
`gate_freeze_requires_unpaused`, `gate_lock_commission_on_freeze`, `gate_pause_blocks_decryption`,
`gate_locked_commission_bps` (→ `Option<u64>`), `policy_freeze_requires_unpaused`,
`policy_lock_commission_on_freeze`, `policy_pause_blocks_decryption`, `platform_treasury`,
`platform_commission_bps`.

### Gate policy

A `GatePolicy` is chosen once, at creation, and can never change (there is no setter), so buyers can
rely on it. All flags default to `false`:

| Flag | Effect |
| --- | --- |
| `freeze_requires_unpaused` | `make_gate_immutable` aborts 10 while the gate is paused, so a frozen gate can never be stuck unpurchasable. |
| `lock_commission_on_freeze` | Freezing snapshots the platform commission; purchases on the frozen gate use the snapshot, whatever the platform later sets. |
| `pause_blocks_decryption` | Advisory to dependent policies: `seal_policies::nft_gate` denies decryption while the gate is paused. `access_gate` itself only stops purchases when paused. |

The policy binds the gate, not the creator's tooling: anyone calling `create_gate` directly gets
the unrestricted default. Tools (e.g. `access-gate-ui`) choose which policy their gates carry.

## Events

All events have `copy, drop`. Timestamps are `ctx.epoch_timestamp_ms()` (epoch start, coarse).

| Event | Emitted by | Fields |
| --- | --- | --- |
| `GateCreatedEvent` | `create_gate*` | `gate_id`, `admin_cap_id`, `price_mist`, `default_uses`, `soulbound`, `auto_burn_at_zero`, `nft_name`, `policy`, `creator`, `timestamp_ms` |
| `AccessMintedEvent` | `purchase`, `airdrop` | `nft_id`, `gate_id`, `soulbound`, `initial_uses` (0 = unlimited), `recipient`, `timestamp_ms` |
| `AccessConsumedEvent` | `consume*` | `nft_id`, `gate_id`, `nonce`, `consumer` (tx sender), `uses_after`, `timestamp_ms` — verifiers MUST check `nonce`, `gate_id`, `consumer` |
| `AccessBurnedEvent` | auto-burn in `consume*`, `burn*` | `nft_id`, `gate_id`, `timestamp_ms` — emitted before the object is deleted |
| `GateFrozenEvent` | `make_gate_immutable` | `gate_id`, `locked_commission_bps` (`Option<u64>`; `none` = follows the live rate), `timestamp_ms` |

Setters emit no events; read the current `Gate` / `PlatformConfig` object for configuration.

## Abort codes (`access_gate`)

| Code | Constant | Meaning |
| --- | --- | --- |
| 1 | `E_PAUSED` | Gate is paused; `purchase` disabled. |
| 2 | `E_INSUFFICIENT_PAYMENT` | Payment coin worth less than `price_mist`. |
| 3 | `E_NOT_SINGLE_USE` | `consume*` on an unlimited pass. |
| 4 | `E_NO_USES_REMAINING` | `consume*` on a pass with zero uses. |
| 5 | `E_WRONG_GATE` | NFT or `AdminCap` belongs to a different gate. |
| 6 | `E_GATE_FROZEN` | Privileged operation on a frozen gate. |
| 7 | `E_COMMISSION_TOO_HIGH` | `commission_bps` above 1000. |
| 8 | `E_INVALID_NONCE` | `nonce` shorter than 8 bytes. |
| 9 | `E_ZERO_ADDRESS` | Platform treasury set to `@0x0`. |
| 10 | `E_FREEZE_WHILE_PAUSED` | `make_gate_immutable` on a paused gate whose policy has `freeze_requires_unpaused`. |

Codes are unique within this module only — disambiguate by `(module, code)`.

## Invariants

- A pass for gate A can never be consumed, validated or approved against gate B.
- A soulbound pass cannot leave the wallet it was minted to (no `store`).
- A single-use pass is spent only by its holder, atomically, and cannot go below zero.
- `commission ≤ price`; commission arithmetic never overflows; the operator share never underflows.
- After `make_gate_immutable`, no privileged operation on that gate can ever succeed.
- A gate's `policy` never changes; `locked_commission_bps` is set at most once (at freeze).

Package version note: the arithmetic widening, `E_ZERO_ADDRESS`, `GatePolicy`
(`create_gate_with_policy`, code 10, the `platform` argument of `make_gate_immutable`) are in the
repository source only. The live testnet package `0x0bedd0…` multiplies in u64, has no codes 9–10,
no policies, and its `make_gate_immutable` takes `(cap, gate, ctx)`. Because the `Gate` layout and a
public signature changed, the next release is a **new package** (not an upgrade).
