// SPDX-License-Identifier: CC0-1.0
// This work is dedicated to the public domain under CC0.

/// Generic, reusable NFT access-gate primitive for Sui.
///
/// ## Overview
///
/// An `access_gate` lets anyone create a **`Gate`** — a shared object describing an
/// access class — and mint **access NFTs** that prove the holder is entitled to some
/// off-chain (or on-chain) resource behind that gate. It is deliberately generic: the
/// resource could be an upload relay, a members-only website, a gacha pull, an API,
/// or anything a server/contract wants to gate on NFT ownership. Nothing here knows
/// about any specific consumer.
///
/// ## Access models
///
/// A gate's `default_uses` selects the NFT flavour minted by `purchase`/`airdrop`:
/// - `default_uses == 0` → an **unlimited pass** (`AccessVariant::UnlimitedPass`): the
///   holder is entitled for as long as they own the NFT.
/// - `default_uses == N` → a **single-use** NFT (`AccessVariant::SingleUse { N }`): each
///   entitlement is spent by calling `consume`, which decrements the counter.
///
/// ## Single-use enforcement (why it is on-chain)
///
/// A gating *server* can only READ ownership (`getOwnedObjects`); it holds no authority
/// to mutate a user's NFT and submits no transaction. A genuine one-time-use therefore
/// must be spent by the **owner's own** `consume(nft, nonce, ...)` call, which emits an
/// `AccessConsumedEvent` carrying the server-issued challenge `nonce`. The server then
/// binds one grant to one on-chain consumption by matching that nonce — replay-proof and
/// fully on-chain. This module never trusts a bare address claim.
///
/// ## Transferability
///
/// Each gate chooses, at creation, whether its NFTs are transferable (`AccessNFT`, which
/// has `store`) or **soulbound** (`SoulboundAccessNFT`, which lacks `store` and so cannot
/// be moved by `public_transfer`). Soulbound is appropriate when a secondary market would
/// undermine rate limits (e.g. a relay pass); transferable suits tradeable goods (e.g.
/// gacha items).
///
/// ## Exhaustion policy
///
/// When a single-use NFT hits zero, `Gate.auto_burn_at_zero` decides its fate: `false`
/// (default) returns the spent zero-use NFT to the owner as a receipt; `true` deletes it.
///
/// ## Governance & immutability
///
/// Price, recipient, pause, and flags are **governable** by default via the `AdminCap`
/// minted to the gate creator (`set_price`, `set_payment_recipient`, …). An operator who
/// wants to guarantee to users that a gate can never change may **renounce** governance
/// with `make_gate_immutable`, which consumes the `AdminCap` and sets `Gate.frozen = true`
/// (mirroring `0x2::package::make_immutable` for a package's `UpgradeCap`). This is
/// **irreversible** and also ends `airdrop`/`mint_to`, so grant everything first, then
/// freeze. `gate_is_frozen` lets a UI/verifier read the locked state on-chain.
///
/// ## Platform commission
///
/// A `PlatformConfig` shared object (created in `init`) carries a `treasury` address and
/// `commission_bps` (basis points). Every paid `purchase` splits the payment: the
/// commission fraction goes to `treasury`, the remainder to the gate's `payment_recipient`.
/// This is automatic and on-chain; the platform operator incurs no gas cost.
///
/// ## NFT display metadata
///
/// Each `Gate` stores default `nft_name`, `nft_image_url`, and `nft_description` values
/// which are copied into every minted NFT. `Display<AccessNFT>` and
/// `Display<SoulboundAccessNFT>` objects (created in `init`) map these to the Sui
/// standard wallet display fields `name`, `image_url`, and `description`.
///
/// ## Trust assumptions
///
/// - `create_gate`, `purchase`, and `consume` are permissionless. Anyone may stand up a
///   gate; anyone may buy access if they pay the price; only the NFT owner can consume it.
/// - Privileged operations (price/recipient/pause/flags, free grants) require the
///   `AdminCap` minted to the gate creator and bound to that gate's ID — unless the gate
///   has been made immutable (`frozen`), after which no privileged operation is possible.
/// - `PlatformConfig` setters require `PlatformAdminCap`, minted to the package publisher.
module access_gate::access_gate;

use std::string::String;
use sui::coin::Coin;
use sui::display;
use sui::event;
use sui::package;
use sui::sui::SUI;

// ── One-time witness (required for Publisher + Display) ────────────────────────

/// One-time witness for the module. Consumed in `init` to claim the `Publisher`
/// and set up the NFT `Display`. Name matches the module (uppercased) as the OTW rule requires.
public struct ACCESS_GATE has drop {}

// ── Error codes ────────────────────────────────────────────────────────────────

/// The gate is paused; `purchase` is disabled.
const E_PAUSED: u64 = 1;
/// The supplied payment coin is worth less than the gate's `price_mist`.
const E_INSUFFICIENT_PAYMENT: u64 = 2;
/// `consume` was called on an unlimited pass (nothing to spend).
const E_NOT_SINGLE_USE: u64 = 3;
/// `consume` was called on a single-use NFT with zero uses remaining.
const E_NO_USES_REMAINING: u64 = 4;
/// The NFT / AdminCap does not belong to the supplied gate.
const E_WRONG_GATE: u64 = 5;
/// A privileged operation was attempted on a gate that has been made immutable.
const E_GATE_FROZEN: u64 = 6;
/// `set_commission_bps` was called with a value exceeding the 10% hard cap.
const E_COMMISSION_TOO_HIGH: u64 = 7;

// ── Platform commission config ────────────────────────────────────────────────

/// Platform-wide shared config governing purchase commissions.
/// Created once in `init`; shared permanently. Updateable via `PlatformAdminCap`.
public struct PlatformConfig has key {
    id: UID,
    /// Address that receives the commission fraction from every paid `purchase`.
    treasury: address,
    /// Commission in basis points (20 = 0.2%). Applied to every paid `purchase`.
    /// Hard cap: 1000 bps (10%) — enforced by `set_commission_bps`.
    commission_bps: u64,
}

/// Capability authorising updates to `PlatformConfig`.
/// Transferred to the package publisher in `init`.
public struct PlatformAdminCap has key, store {
    id: UID,
}

// ── Core data ────────────────────────────────────────────────────────────────

/// Access flavour carried by every access NFT.
public enum AccessVariant has copy, drop, store {
    /// Entitled while owned; `consume` aborts on it.
    UnlimitedPass,
    /// Entitled `uses_remaining` more times; each `consume` decrements it.
    SingleUse { uses_remaining: u64 },
}

/// Inner payload shared by the transferable and soulbound NFT wrappers, so the
/// consume/view logic is written once.
public struct AccessData has store {
    /// The `Gate` this NFT was minted from.
    gate_id: ID,
    variant: AccessVariant,
    /// Epoch the NFT was minted (audit trail).
    minted_epoch: u64,
}

/// Transferable access NFT (`store` ⇒ movable via `public_transfer`).
/// Top-level `name`, `image_url`, `description` are referenced by `Display<AccessNFT>`
/// and are copied from the gate's defaults at mint time.
public struct AccessNFT has key, store {
    id: UID,
    data: AccessData,
    name: String,
    image_url: String,
    description: String,
}

/// Soulbound access NFT (no `store` ⇒ cannot be moved by `public_transfer`; only this
/// module's `consume`/`burn` may destroy it).
/// Top-level display fields are referenced by `Display<SoulboundAccessNFT>`.
public struct SoulboundAccessNFT has key {
    id: UID,
    data: AccessData,
    name: String,
    image_url: String,
    description: String,
}

/// A shared object describing one access class.
public struct Gate has key {
    id: UID,
    /// The `AdminCap` authorised over this gate (informational; auth is by cap.gate_id).
    admin_cap_id: ID,
    /// Price in MIST that `purchase` charges (0 = free).
    price_mist: u64,
    /// Where `purchase` payments are routed (after commission deduction).
    payment_recipient: address,
    /// 0 ⇒ mint unlimited passes; N ⇒ mint single-use NFTs with N uses.
    default_uses: u64,
    /// Whether newly-minted NFTs are soulbound.
    soulbound: bool,
    /// Whether a single-use NFT is deleted (vs. kept as a receipt) when it reaches zero.
    auto_burn_at_zero: bool,
    /// When true, `purchase` is disabled.
    paused: bool,
    /// When true, the gate has been made immutable: the `AdminCap` was renounced and no
    /// privileged operation (setters / airdrop) can ever run again. `purchase`/`consume`
    /// remain permissionless. Set once, irreversibly, by `make_gate_immutable`.
    frozen: bool,
    /// Default display name copied into each minted NFT (e.g. "VIP Relay Pass").
    nft_name: String,
    /// Default image URL copied into each minted NFT (Walrus blob URL or HTTPS).
    nft_image_url: String,
    /// Default description copied into each minted NFT.
    nft_description: String,
}

/// Capability authorising privileged operations on exactly one `Gate`.
public struct AdminCap has key, store {
    id: UID,
    gate_id: ID,
}

// ── Events ────────────────────────────────────────────────────────────────────

/// Emitted when a gate is created.
public struct GateCreatedEvent has copy, drop {
    gate_id: ID,
    admin_cap_id: ID,
    price_mist: u64,
    default_uses: u64,
    soulbound: bool,
    auto_burn_at_zero: bool,
    nft_name: String,
    creator: address,
    timestamp_ms: u64,
}

/// Emitted when an access NFT is minted (via `purchase` or `airdrop`).
public struct AccessMintedEvent has copy, drop {
    nft_id: ID,
    gate_id: ID,
    soulbound: bool,
    /// 0 for an unlimited pass; otherwise the single-use starting count.
    initial_uses: u64,
    recipient: address,
    timestamp_ms: u64,
}

/// Emitted when a single-use NFT is consumed. The `nonce` binds the consumption to a
/// server-issued challenge; a verifying gateway indexes this field.
public struct AccessConsumedEvent has copy, drop {
    nft_id: ID,
    gate_id: ID,
    nonce: vector<u8>,
    uses_after: u64,
    timestamp_ms: u64,
}

/// Emitted when an access NFT is destroyed (auto-burn at zero, or voluntary `burn`).
public struct AccessBurnedEvent has copy, drop {
    nft_id: ID,
    gate_id: ID,
    timestamp_ms: u64,
}

/// Emitted once when a gate is made immutable (its `AdminCap` renounced).
public struct GateFrozenEvent has copy, drop {
    gate_id: ID,
    timestamp_ms: u64,
}

// ── Initialisation ─────────────────────────────────────────────────────────────

/// Called once on publish. Creates:
/// - `Publisher` (kept by publisher; required for future Display updates)
/// - `Display<AccessNFT>` and `Display<SoulboundAccessNFT>` (transferred to publisher)
/// - `PlatformAdminCap` (transferred to publisher)
/// - `PlatformConfig` shared object (commission_bps = 20, treasury = publisher address)
fun init(otw: ACCESS_GATE, ctx: &mut TxContext) {
    let publisher = package::claim(otw, ctx);

    let mut sb_display = display::new<SoulboundAccessNFT>(&publisher, ctx);
    sb_display.add(b"name".to_string(), b"{name}".to_string());
    sb_display.add(b"description".to_string(), b"{description}".to_string());
    sb_display.add(b"image_url".to_string(), b"{image_url}".to_string());
    sb_display.update_version();
    transfer::public_transfer(sb_display, ctx.sender());

    let mut nft_display = display::new<AccessNFT>(&publisher, ctx);
    nft_display.add(b"name".to_string(), b"{name}".to_string());
    nft_display.add(b"description".to_string(), b"{description}".to_string());
    nft_display.add(b"image_url".to_string(), b"{image_url}".to_string());
    nft_display.update_version();
    transfer::public_transfer(nft_display, ctx.sender());

    transfer::public_transfer(publisher, ctx.sender());

    transfer::public_transfer(PlatformAdminCap { id: object::new(ctx) }, ctx.sender());
    transfer::share_object(PlatformConfig {
        id: object::new(ctx),
        treasury: ctx.sender(),
        commission_bps: 20,
    });
}

// ── Gate lifecycle ──────────────────────────────────────────────────────────────

/// Create a new access class. Permissionless: shares the `Gate` and transfers a bound
/// `AdminCap` to the caller. Display metadata (`nft_name`, `nft_image_url`,
/// `nft_description`) is copied into every NFT minted from this gate.
public fun create_gate(
    price_mist: u64,
    payment_recipient: address,
    default_uses: u64,
    soulbound: bool,
    auto_burn_at_zero: bool,
    nft_name: String,
    nft_image_url: String,
    nft_description: String,
    ctx: &mut TxContext,
) {
    let gate_uid = object::new(ctx);
    let gate_id = gate_uid.to_inner();
    let cap = AdminCap { id: object::new(ctx), gate_id };
    let admin_cap_id = object::id(&cap);

    event::emit(GateCreatedEvent {
        gate_id,
        admin_cap_id,
        price_mist,
        default_uses,
        soulbound,
        auto_burn_at_zero,
        nft_name,
        creator: ctx.sender(),
        timestamp_ms: ctx.epoch_timestamp_ms(),
    });

    let gate = Gate {
        id: gate_uid,
        admin_cap_id,
        price_mist,
        payment_recipient,
        default_uses,
        soulbound,
        auto_burn_at_zero,
        paused: false,
        frozen: false,
        nft_name,
        nft_image_url,
        nft_description,
    };

    transfer::share_object(gate);
    transfer::public_transfer(cap, ctx.sender());
}

// ── Purchase & minting ─────────────────────────────────────────────────────────

/// Buy access. Permissionless. Asserts the gate is live and `payment >= price`, splits
/// the price: `commission_bps / 10000` to `platform.treasury`, the rest to
/// `payment_recipient`. Refunds any overpayment and mints the gate's NFT flavour to the
/// caller.
#[allow(lint(self_transfer))]
public fun purchase(
    gate: &Gate,
    platform: &PlatformConfig,
    mut payment: Coin<SUI>,
    ctx: &mut TxContext,
) {
    assert!(!gate.paused, E_PAUSED);
    assert!(payment.value() >= gate.price_mist, E_INSUFFICIENT_PAYMENT);

    if (gate.price_mist > 0) {
        let commission = gate.price_mist * platform.commission_bps / 10000;
        let operator_share = gate.price_mist - commission;
        if (commission > 0) {
            let commission_coin = payment.split(commission, ctx);
            transfer::public_transfer(commission_coin, platform.treasury);
        };
        if (operator_share > 0) {
            let paid = payment.split(operator_share, ctx);
            transfer::public_transfer(paid, gate.payment_recipient);
        };
    };
    // Return any overpayment; destroy an exact/zero-priced remainder.
    if (payment.value() > 0) {
        transfer::public_transfer(payment, ctx.sender());
    } else {
        payment.destroy_zero();
    };

    mint_and_transfer(gate, ctx.sender(), ctx);
}

/// AdminCap-gated free grant (airdrop) of the gate's NFT flavour to `recipient`.
public fun airdrop(cap: &AdminCap, gate: &Gate, recipient: address, ctx: &mut TxContext) {
    assert_admin_mutable(cap, gate);
    mint_and_transfer(gate, recipient, ctx);
}

fun mint_and_transfer(gate: &Gate, recipient: address, ctx: &mut TxContext) {
    let gate_id = object::id(gate);
    let data = AccessData {
        gate_id,
        variant: new_variant(gate.default_uses),
        minted_epoch: ctx.epoch(),
    };
    let ts = ctx.epoch_timestamp_ms();
    let name = gate.nft_name;
    let image_url = gate.nft_image_url;
    let description = gate.nft_description;

    if (gate.soulbound) {
        let nft = SoulboundAccessNFT { id: object::new(ctx), data, name, image_url, description };
        event::emit(AccessMintedEvent {
            nft_id: object::id(&nft),
            gate_id,
            soulbound: true,
            initial_uses: gate.default_uses,
            recipient,
            timestamp_ms: ts,
        });
        transfer::transfer(nft, recipient);
    } else {
        let nft = AccessNFT { id: object::new(ctx), data, name, image_url, description };
        event::emit(AccessMintedEvent {
            nft_id: object::id(&nft),
            gate_id,
            soulbound: false,
            initial_uses: gate.default_uses,
            recipient,
            timestamp_ms: ts,
        });
        transfer::public_transfer(nft, recipient);
    }
}

fun new_variant(default_uses: u64): AccessVariant {
    if (default_uses == 0) {
        AccessVariant::UnlimitedPass
    } else {
        AccessVariant::SingleUse { uses_remaining: default_uses }
    }
}

// ── Consume (single-use spend) ──────────────────────────────────────────────────

/// Spend one use of a transferable single-use NFT, binding the spend to `nonce`. If the
/// NFT reaches zero and the gate has `auto_burn_at_zero`, it is deleted; otherwise it is
/// returned to the caller as a receipt (an intentional self-transfer). Aborts on an
/// unlimited pass or zero uses.
#[allow(lint(self_transfer))]
public fun consume(mut nft: AccessNFT, gate: &Gate, nonce: vector<u8>, ctx: &mut TxContext) {
    let nft_id = object::id(&nft);
    let ts = ctx.epoch_timestamp_ms();
    let burn = consume_data(&mut nft.data, gate, nonce, nft_id, ts);
    if (burn) {
        let AccessNFT { id, data, name: _, image_url: _, description: _ } = nft;
        destroy_data(data);
        event::emit(AccessBurnedEvent { nft_id, gate_id: object::id(gate), timestamp_ms: ts });
        id.delete();
    } else {
        transfer::public_transfer(nft, ctx.sender());
    }
}

/// Soulbound counterpart of `consume`.
#[allow(lint(self_transfer))]
public fun consume_soulbound(
    mut nft: SoulboundAccessNFT,
    gate: &Gate,
    nonce: vector<u8>,
    ctx: &mut TxContext,
) {
    let nft_id = object::id(&nft);
    let ts = ctx.epoch_timestamp_ms();
    let burn = consume_data(&mut nft.data, gate, nonce, nft_id, ts);
    if (burn) {
        let SoulboundAccessNFT { id, data, name: _, image_url: _, description: _ } = nft;
        destroy_data(data);
        event::emit(AccessBurnedEvent { nft_id, gate_id: object::id(gate), timestamp_ms: ts });
        id.delete();
    } else {
        transfer::transfer(nft, ctx.sender());
    }
}

/// Decrement one use, emit `AccessConsumedEvent`, and report whether the NFT should now
/// be auto-burned (reached zero AND the gate opts into auto-burn).
fun consume_data(
    data: &mut AccessData,
    gate: &Gate,
    nonce: vector<u8>,
    nft_id: ID,
    ts: u64,
): bool {
    assert!(data.gate_id == object::id(gate), E_WRONG_GATE);
    let gate_id = data.gate_id;
    let auto_burn = gate.auto_burn_at_zero;
    match (&mut data.variant) {
        AccessVariant::SingleUse { uses_remaining } => {
            assert!(*uses_remaining > 0, E_NO_USES_REMAINING);
            *uses_remaining = *uses_remaining - 1;
            let after = *uses_remaining;
            event::emit(AccessConsumedEvent {
                nft_id,
                gate_id,
                nonce,
                uses_after: after,
                timestamp_ms: ts,
            });
            after == 0 && auto_burn
        },
        AccessVariant::UnlimitedPass => abort E_NOT_SINGLE_USE,
    }
}

// ── Voluntary burn ──────────────────────────────────────────────────────────────

/// Permanently destroy a transferable NFT.
public fun burn(nft: AccessNFT, ctx: &TxContext) {
    let nft_id = object::id(&nft);
    let AccessNFT { id, data, name: _, image_url: _, description: _ } = nft;
    let gate_id = data.gate_id;
    destroy_data(data);
    event::emit(AccessBurnedEvent { nft_id, gate_id, timestamp_ms: ctx.epoch_timestamp_ms() });
    id.delete();
}

/// Permanently destroy a soulbound NFT (the owner may always discard their own).
public fun burn_soulbound(nft: SoulboundAccessNFT, ctx: &TxContext) {
    let nft_id = object::id(&nft);
    let SoulboundAccessNFT { id, data, name: _, image_url: _, description: _ } = nft;
    let gate_id = data.gate_id;
    destroy_data(data);
    event::emit(AccessBurnedEvent { nft_id, gate_id, timestamp_ms: ctx.epoch_timestamp_ms() });
    id.delete();
}

fun destroy_data(data: AccessData) {
    let AccessData { gate_id: _, variant: _, minted_epoch: _ } = data;
}

// ── Admin setters ───────────────────────────────────────────────────────────────

/// Assert the cap authorises the supplied gate.
public fun assert_admin(cap: &AdminCap, gate: &Gate) {
    assert!(cap.gate_id == object::id(gate), E_WRONG_GATE);
}

/// Assert the cap authorises the gate AND the gate is still governable (not frozen).
/// Note: after `make_gate_immutable` the `AdminCap` is destroyed, so a frozen gate has no
/// cap to present here — the `frozen` check is defence-in-depth (and future-proofs any
/// design that mints more than one cap).
fun assert_admin_mutable(cap: &AdminCap, gate: &Gate) {
    assert_admin(cap, gate);
    assert!(!gate.frozen, E_GATE_FROZEN);
}

/// Renounce governance and make the gate **immutable**: sets `frozen = true`, emits
/// `GateFrozenEvent`, and permanently destroys the `AdminCap`. Irreversible. After this,
/// no setter or `airdrop`/`mint_to` can run; `purchase`/`consume` remain permissionless.
/// Perform any final `set_*`/`airdrop` BEFORE calling this. Mirrors
/// `0x2::package::make_immutable` for a package's `UpgradeCap`.
public fun make_gate_immutable(cap: AdminCap, gate: &mut Gate, ctx: &TxContext) {
    assert_admin_mutable(&cap, gate);
    gate.frozen = true;
    event::emit(GateFrozenEvent { gate_id: object::id(gate), timestamp_ms: ctx.epoch_timestamp_ms() });
    let AdminCap { id, gate_id: _ } = cap;
    id.delete();
}

/// Update the gate price for future purchases (does not affect in-flight transactions).
public fun set_price(cap: &AdminCap, gate: &mut Gate, price_mist: u64) {
    assert_admin_mutable(cap, gate);
    gate.price_mist = price_mist;
}

/// Redirect future purchase payments to a new recipient address.
public fun set_payment_recipient(cap: &AdminCap, gate: &mut Gate, recipient: address) {
    assert_admin_mutable(cap, gate);
    gate.payment_recipient = recipient;
}

/// Pause or unpause `purchase`. When paused, `purchase` aborts with `E_PAUSED`.
public fun set_paused(cap: &AdminCap, gate: &mut Gate, paused: bool) {
    assert_admin_mutable(cap, gate);
    gate.paused = paused;
}

/// Change the default uses for future mints (does not affect already-minted NFTs).
public fun set_default_uses(cap: &AdminCap, gate: &mut Gate, default_uses: u64) {
    assert_admin_mutable(cap, gate);
    gate.default_uses = default_uses;
}

/// Switch the soulbound flag for future mints (does not affect already-minted NFTs).
public fun set_soulbound(cap: &AdminCap, gate: &mut Gate, soulbound: bool) {
    assert_admin_mutable(cap, gate);
    gate.soulbound = soulbound;
}

/// Toggle the auto-burn policy for future mints (does not affect already-minted NFTs).
public fun set_auto_burn_at_zero(cap: &AdminCap, gate: &mut Gate, auto_burn_at_zero: bool) {
    assert_admin_mutable(cap, gate);
    gate.auto_burn_at_zero = auto_burn_at_zero;
}

/// Update the default NFT display name for future mints (does not affect existing NFTs).
public fun set_nft_name(cap: &AdminCap, gate: &mut Gate, name: String) {
    assert_admin_mutable(cap, gate);
    gate.nft_name = name;
}

/// Update the default NFT image URL for future mints (does not affect existing NFTs).
public fun set_nft_image_url(cap: &AdminCap, gate: &mut Gate, url: String) {
    assert_admin_mutable(cap, gate);
    gate.nft_image_url = url;
}

/// Update the default NFT description for future mints (does not affect existing NFTs).
public fun set_nft_description(cap: &AdminCap, gate: &mut Gate, description: String) {
    assert_admin_mutable(cap, gate);
    gate.nft_description = description;
}

// ── Platform admin setters ──────────────────────────────────────────────────────

/// Update the platform treasury address (where commission payments are routed).
public fun set_platform_treasury(
    _cap: &PlatformAdminCap,
    config: &mut PlatformConfig,
    treasury: address,
) {
    config.treasury = treasury;
}

/// Update the platform commission rate. Hard cap: 1000 bps (10%).
public fun set_commission_bps(
    _cap: &PlatformAdminCap,
    config: &mut PlatformConfig,
    commission_bps: u64,
) {
    assert!(commission_bps <= 1000, E_COMMISSION_TOO_HIGH);
    config.commission_bps = commission_bps;
}

// ── Views ───────────────────────────────────────────────────────────────────────

/// The object ID of the `Gate` from which this NFT was minted.
public fun gate_id(nft: &AccessNFT): ID { nft.data.gate_id }

/// Soulbound counterpart of `gate_id`.
public fun gate_id_soulbound(nft: &SoulboundAccessNFT): ID { nft.data.gate_id }

/// Remaining uses for a single-use NFT, or `none` for an unlimited pass.
public fun uses_remaining(nft: &AccessNFT): Option<u64> { data_uses_remaining(&nft.data) }

/// Soulbound counterpart of `uses_remaining`.
public fun uses_remaining_soulbound(nft: &SoulboundAccessNFT): Option<u64> {
    data_uses_remaining(&nft.data)
}

/// True if the NFT was minted from `gate` (i.e. its `gate_id` matches).
public fun is_valid_for(nft: &AccessNFT, gate: &Gate): bool {
    nft.data.gate_id == object::id(gate)
}

/// Soulbound counterpart of `is_valid_for`.
public fun is_valid_for_soulbound(nft: &SoulboundAccessNFT, gate: &Gate): bool {
    nft.data.gate_id == object::id(gate)
}

fun data_uses_remaining(data: &AccessData): Option<u64> {
    match (&data.variant) {
        AccessVariant::SingleUse { uses_remaining } => option::some(*uses_remaining),
        AccessVariant::UnlimitedPass => option::none(),
    }
}

/// Price in MIST charged by `purchase` (0 = free gate).
public fun gate_price_mist(gate: &Gate): u64 { gate.price_mist }

/// Address that receives the operator share of each paid `purchase`.
public fun gate_payment_recipient(gate: &Gate): address { gate.payment_recipient }

/// Default uses minted into each NFT (0 = unlimited pass).
public fun gate_default_uses(gate: &Gate): u64 { gate.default_uses }

/// True if `purchase` is currently disabled.
public fun gate_is_paused(gate: &Gate): bool { gate.paused }

/// True if the gate has been made immutable via `make_gate_immutable`.
public fun gate_is_frozen(gate: &Gate): bool { gate.frozen }

/// True if newly-minted NFTs are soulbound.
public fun gate_is_soulbound(gate: &Gate): bool { gate.soulbound }

/// True if single-use NFTs are auto-deleted when they reach zero uses.
public fun gate_auto_burn_at_zero(gate: &Gate): bool { gate.auto_burn_at_zero }

/// Object ID of the `AdminCap` authorised over this gate.
public fun gate_admin_cap_id(gate: &Gate): ID { gate.admin_cap_id }

/// The `Gate` ID this cap is authorised over.
public fun admin_cap_gate_id(cap: &AdminCap): ID { cap.gate_id }

/// Default NFT display name copied into minted NFTs.
public fun gate_nft_name(gate: &Gate): String { gate.nft_name }

/// Default NFT image URL copied into minted NFTs.
public fun gate_nft_image_url(gate: &Gate): String { gate.nft_image_url }

/// Default NFT description copied into minted NFTs.
public fun gate_nft_description(gate: &Gate): String { gate.nft_description }

/// Address that receives commission payments from every paid `purchase`.
public fun platform_treasury(config: &PlatformConfig): address { config.treasury }

/// Commission rate in basis points (20 = 0.2%). Hard cap: 1000 bps.
public fun platform_commission_bps(config: &PlatformConfig): u64 { config.commission_bps }

// ── Test-only helpers ─────────────────────────────────────────────────────────────

#[test_only]
/// Mint an extra `AdminCap` bound to `gate` (to exercise the defensive `frozen` guard on
/// setters, which is otherwise unreachable because `make_gate_immutable` consumes the cap).
public fun new_admin_cap_for_testing(gate: &Gate, ctx: &mut TxContext): AdminCap {
    AdminCap { id: object::new(ctx), gate_id: object::id(gate) }
}

#[test_only]
public fun burn_admin_cap_for_testing(cap: AdminCap) {
    let AdminCap { id, gate_id: _ } = cap;
    id.delete();
}

#[test_only]
/// Create and share a `PlatformConfig` with zero commission for tests that check exact
/// payment amounts. Take it with `ts::take_shared<PlatformConfig>()` after `next_tx`.
public fun share_platform_config_zero_commission_for_testing(ctx: &mut TxContext) {
    transfer::share_object(PlatformConfig {
        id: object::new(ctx),
        treasury: ctx.sender(),
        commission_bps: 0,
    });
}
