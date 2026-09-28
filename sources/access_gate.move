// SPDX-License-Identifier: 0BSD
// Licensed under the 0BSD license; see the LICENSE file.

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
/// **irreversible** and also ends `airdrop`, so grant everything first, then
/// freeze. `gate_is_frozen` lets a UI/verifier read the locked state on-chain.
///
/// ## Gate policy (operator-selectable restrictions)
///
/// Each gate carries an immutable `GatePolicy`, fixed at creation by whatever tool creates it (the
/// tool's operator decides which restrictions to apply). Every restriction is OFF in
/// `default_gate_policy`:
/// - `freeze_requires_unpaused` — `make_gate_immutable` aborts while the gate is paused, so a gate
///   can never be frozen into a permanently unsellable state.
/// - `lock_commission_on_freeze` — freezing snapshots the platform commission terms; purchases and
///   airdrops on the frozen gate use that snapshot, so later platform changes cannot affect it.
/// - `pause_blocks_decryption` — dependent decryption policies (the Seal `nft_gate` policy) deny
///   access while the gate is paused. Stored and exposed here; enforced by the dependant.
/// - `pause_blocks_access` — while paused, `consume` aborts (`E_PAUSED`) and access gateways deny
///   holders; independent of `pause_blocks_decryption`.
///
/// ## Platform commission and fees
///
/// A `PlatformConfig` shared object (created in `init`) carries the platform `treasury` and its terms,
/// all set by the `PlatformAdminCap` holder:
/// - `commission_bps` + `min_commission_mist` — every paid `purchase` (and every `airdrop` from a paid
///   gate) pays `max(price × commission_bps / 10000, min_commission_mist)` to the treasury, never more
///   than `MAX_COMMISSION_BPS` (10%) of the price; the rest goes to the gate's `payment_recipient`.
///   A paid gate's price must therefore be at least `min_paid_price_mist` (10 × the minimum
///   commission), so the floor always fits under the cap.
/// - `free_gate_fee_mist` — a one-off fee to make a gate free: paid by `create_free_gate`, or by
///   `make_gate_free` before a paid gate's price can be set to 0. Once paid, the gate may move between
///   free and paid; paid purchases always carry the commission.
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
/// - `create_gate`, `create_free_gate`, `purchase`, and `consume` are permissionless. Anyone may
///   stand up a gate (paying the free-gate fee for a free one); anyone may buy access if they pay
///   the price; only the NFT owner can consume it.
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
/// `consume` was called with a nonce shorter than `MIN_NONCE_LENGTH` bytes.
const E_INVALID_NONCE: u64 = 8;

/// `set_platform_treasury` was called with the zero address (commission would be unrecoverable).
const E_ZERO_ADDRESS: u64 = 9;
/// `make_gate_immutable` on a paused gate whose policy has `freeze_requires_unpaused`.
const E_FREEZE_WHILE_PAUSED: u64 = 10;
/// A paid price below `min_paid_price_mist` (or 0 via `create_gate`; use `create_free_gate`).
const E_PRICE_TOO_LOW: u64 = 11;
/// `set_price(0)` on a gate whose free-gate fee has not been paid (use `make_gate_free`).
const E_FREE_FEE_UNPAID: u64 = 12;

/// Minimum nonce length (bytes). Enforced by `consume_data`; ensures the server-issued
/// challenge carries enough entropy to be meaningful as a replay guard.
const MIN_NONCE_LENGTH: u64 = 8;

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
    /// Floor on a paid purchase's commission (MIST); the commission never exceeds 10% of the price.
    min_commission_mist: u64,
    /// One-off fee (MIST) to make a gate free (`create_free_gate` / `make_gate_free`).
    free_gate_fee_mist: u64,
}

/// A commission rule: `max(price × bps / 10000, min_mist)`, capped at 10% of the price.
public struct CommissionTerms has copy, drop, store {
    bps: u64,
    min_mist: u64,
}

/// Maximum `commission_bps` (10%). `set_commission_bps` aborts above it.
const MAX_COMMISSION_BPS: u64 = 1000;
/// Basis-point denominator.
const BPS_DENOMINATOR: u64 = 10000;
/// `init` defaults: 0.2% commission, never less than 0.001 SUI per paid mint (so the minimum paid
/// price is 0.01 SUI); 0.1 SUI to make a gate free.
const DEFAULT_COMMISSION_BPS: u64 = 20;
const DEFAULT_MIN_COMMISSION_MIST: u64 = 1_000_000;
const DEFAULT_FREE_GATE_FEE_MIST: u64 = 100_000_000;

/// Capability authorising updates to `PlatformConfig`.
/// Transferred to the package publisher in `init`.
public struct PlatformAdminCap has key, store {
    id: UID,
}

// ── Core data ────────────────────────────────────────────────────────────────

/// Operator-selectable restrictions, fixed per gate at creation (see "Gate policy" above).
public struct GatePolicy has copy, drop, store {
    freeze_requires_unpaused: bool,
    lock_commission_on_freeze: bool,
    pause_blocks_decryption: bool,
    pause_blocks_access: bool,
}

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
    /// Operator-selected restrictions; immutable after creation.
    policy: GatePolicy,
    /// Commission terms snapshotted at freeze when `policy.lock_commission_on_freeze`; purchases and
    /// airdrops on a frozen gate use them instead of the live `PlatformConfig` terms.
    locked_commission: Option<CommissionTerms>,
    /// True once the free-gate fee has been paid (by `create_free_gate` or `make_gate_free`); only
    /// then may the price be 0.
    free_fee_paid: bool,
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
    policy: GatePolicy,
    /// Free-gate fee paid at creation (0 for a paid gate).
    free_gate_fee_paid_mist: u64,
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
    /// Commission paid to the platform treasury for this mint.
    commission_mist: u64,
    timestamp_ms: u64,
}

/// Emitted when a single-use NFT is consumed. The `nonce` binds the consumption to a
/// server-issued challenge; a verifying gateway indexes this field.
/// `consumer` is the transaction sender (the NFT owner who called `consume`/`consume_soulbound`);
/// gateways bind this address to the grant to prevent a valid event from being claimed by a
/// different sender.
public struct AccessConsumedEvent has copy, drop {
    nft_id: ID,
    gate_id: ID,
    nonce: vector<u8>,
    consumer: address,
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
    /// The commission terms applied from now on, or `none` if the gate follows the live terms.
    locked_commission: Option<CommissionTerms>,
    timestamp_ms: u64,
}

/// Emitted when `make_gate_free` sets a gate's price to 0.
public struct GateMadeFreeEvent has copy, drop {
    gate_id: ID,
    /// Free-gate fee paid now (0 if it had already been paid).
    fee_paid_mist: u64,
    timestamp_ms: u64,
}

/// Emitted by every `PlatformConfig` setter with the resulting configuration.
public struct PlatformConfigUpdatedEvent has copy, drop {
    treasury: address,
    commission_bps: u64,
    min_commission_mist: u64,
    free_gate_fee_mist: u64,
}

// ── Initialisation ─────────────────────────────────────────────────────────────

/// Called once on publish. Creates:
/// - `Publisher` (kept by publisher; required for future Display updates)
/// - `Display<AccessNFT>` and `Display<SoulboundAccessNFT>` (transferred to publisher)
/// - `PlatformAdminCap` (transferred to publisher)
/// - `PlatformConfig` shared object (treasury = publisher; commission 20 bps with a 0.001 SUI
///   floor; free-gate fee 0.1 SUI)
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
        commission_bps: DEFAULT_COMMISSION_BPS,
        min_commission_mist: DEFAULT_MIN_COMMISSION_MIST,
        free_gate_fee_mist: DEFAULT_FREE_GATE_FEE_MIST,
    });
}

// ── Gate lifecycle ──────────────────────────────────────────────────────────────

/// The unrestricted policy (every restriction off).
public fun default_gate_policy(): GatePolicy {
    GatePolicy {
        freeze_requires_unpaused: false,
        lock_commission_on_freeze: false,
        pause_blocks_decryption: false,
        pause_blocks_access: false,
    }
}

/// Build a `GatePolicy` for `create_gate` / `create_free_gate` (callable from a PTB).
public fun new_gate_policy(
    freeze_requires_unpaused: bool,
    lock_commission_on_freeze: bool,
    pause_blocks_decryption: bool,
    pause_blocks_access: bool,
): GatePolicy {
    GatePolicy {
        freeze_requires_unpaused,
        lock_commission_on_freeze,
        pause_blocks_decryption,
        pause_blocks_access,
    }
}

/// Create a **paid** access class. Permissionless: shares the `Gate` and transfers a bound
/// `AdminCap` to the caller. `price_mist` must be at least `min_paid_price_mist(platform)`
/// (`E_PRICE_TOO_LOW`); free gates use `create_free_gate`. Display metadata is copied into every
/// NFT minted from this gate; `policy` is fixed for good.
public fun create_gate(
    platform: &PlatformConfig,
    price_mist: u64,
    payment_recipient: address,
    default_uses: u64,
    soulbound: bool,
    auto_burn_at_zero: bool,
    nft_name: String,
    nft_image_url: String,
    nft_description: String,
    policy: GatePolicy,
    ctx: &mut TxContext,
) {
    assert!(price_mist >= min_paid_price_mist(platform), E_PRICE_TOO_LOW);
    share_new_gate(
        price_mist, payment_recipient, default_uses, soulbound, auto_burn_at_zero,
        nft_name, nft_image_url, nft_description, policy, 0, ctx,
    );
}

/// Create a **free** access class (price 0), paying the platform's one-off `free_gate_fee_mist`
/// from `payment` (any excess is refunded). `payment_recipient` receives the proceeds if the gate is
/// later given a price.
public fun create_free_gate(
    platform: &PlatformConfig,
    payment: Coin<SUI>,
    payment_recipient: address,
    default_uses: u64,
    soulbound: bool,
    auto_burn_at_zero: bool,
    nft_name: String,
    nft_image_url: String,
    nft_description: String,
    policy: GatePolicy,
    ctx: &mut TxContext,
) {
    let fee = platform.free_gate_fee_mist;
    pay_to(payment, fee, platform.treasury, ctx);
    share_new_gate(
        0, payment_recipient, default_uses, soulbound, auto_burn_at_zero,
        nft_name, nft_image_url, nft_description, policy, fee, ctx,
    );
}

/// Share a new gate and give its `AdminCap` to the sender. `free_fee_paid_mist` is the free-gate fee
/// already collected (0 for a paid gate).
fun share_new_gate(
    price_mist: u64,
    payment_recipient: address,
    default_uses: u64,
    soulbound: bool,
    auto_burn_at_zero: bool,
    nft_name: String,
    nft_image_url: String,
    nft_description: String,
    policy: GatePolicy,
    free_gate_fee_paid_mist: u64,
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
        policy,
        free_gate_fee_paid_mist,
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
        policy,
        locked_commission: option::none(),
        free_fee_paid: price_mist == 0,
    };

    transfer::share_object(gate);
    transfer::public_transfer(cap, ctx.sender());
}

// ── Purchase & minting ─────────────────────────────────────────────────────────

/// Buy access. Permissionless. Asserts the gate is live and `payment >= price`, pays the platform
/// commission (`gate_commission_mist`) to the treasury and the rest of the price to
/// `payment_recipient`, refunds any overpayment and mints the gate's NFT flavour to the caller.
public fun purchase(
    gate: &Gate,
    platform: &PlatformConfig,
    mut payment: Coin<SUI>,
    ctx: &mut TxContext,
) {
    assert!(!gate.paused, E_PAUSED);
    assert!(payment.value() >= gate.price_mist, E_INSUFFICIENT_PAYMENT);

    let commission = gate_commission_mist(gate, platform);
    if (commission > 0) {
        transfer::public_transfer(payment.split(commission, ctx), platform.treasury);
    };
    let operator_share = gate.price_mist - commission;
    if (operator_share > 0) {
        transfer::public_transfer(payment.split(operator_share, ctx), gate.payment_recipient);
    };
    refund_or_destroy(payment, ctx);

    mint_and_transfer(gate, ctx.sender(), commission, ctx);
}

/// AdminCap-gated grant of the gate's NFT flavour to `recipient`. The grant is free for the
/// recipient, but the admin pays the platform the commission a purchase at the current price would
/// carry (`gate_commission_mist`, 0 for a free gate) from `payment`; any excess is refunded.
public fun airdrop(
    cap: &AdminCap,
    gate: &Gate,
    platform: &PlatformConfig,
    payment: Coin<SUI>,
    recipient: address,
    ctx: &mut TxContext,
) {
    assert_admin_mutable(cap, gate);
    let commission = gate_commission_mist(gate, platform);
    pay_to(payment, commission, platform.treasury, ctx);
    mint_and_transfer(gate, recipient, commission, ctx);
}

/// Take exactly `amount` from `payment` for `recipient` (`E_INSUFFICIENT_PAYMENT` if short) and
/// refund the remainder to the sender.
fun pay_to(mut payment: Coin<SUI>, amount: u64, recipient: address, ctx: &mut TxContext) {
    assert!(payment.value() >= amount, E_INSUFFICIENT_PAYMENT);
    if (amount > 0) transfer::public_transfer(payment.split(amount, ctx), recipient);
    refund_or_destroy(payment, ctx);
}

/// Return a non-zero remainder to the sender; destroy an empty coin.
#[allow(lint(self_transfer))]
fun refund_or_destroy(payment: Coin<SUI>, ctx: &TxContext) {
    if (payment.value() > 0) transfer::public_transfer(payment, ctx.sender())
    else payment.destroy_zero()
}

fun mint_and_transfer(gate: &Gate, recipient: address, commission_mist: u64, ctx: &mut TxContext) {
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
            commission_mist,
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
            commission_mist,
            timestamp_ms: ts,
        });
        transfer::public_transfer(nft, recipient);
    }
}

/// The platform's current commission terms.
public fun commission_terms(platform: &PlatformConfig): CommissionTerms {
    CommissionTerms { bps: platform.commission_bps, min_mist: platform.min_commission_mist }
}

/// The terms a mint on `gate` pays: the freeze-time snapshot if the gate locked one, otherwise the
/// live platform terms.
public fun effective_commission_terms(gate: &Gate, platform: &PlatformConfig): CommissionTerms {
    if (gate.locked_commission.is_some()) *gate.locked_commission.borrow()
    else commission_terms(platform)
}

/// Commission a purchase of `gate` pays right now (0 for a free gate).
public fun gate_commission_mist(gate: &Gate, platform: &PlatformConfig): u64 {
    commission_for_price(gate.price_mist, &effective_commission_terms(gate, platform))
}

/// Commission on `price_mist` under `terms`: `max(price × bps / 10000, min_mist)` (the percentage
/// part rounded down), never more than `MAX_COMMISSION_BPS` of the price; 0 for a price of 0.
/// Computed in u128, so no price can overflow; the result is always ≤ `price_mist`.
public fun commission_for_price(price_mist: u64, terms: &CommissionTerms): u64 {
    if (price_mist == 0) return 0;
    let denominator = BPS_DENOMINATOR as u128;
    let share = (price_mist as u128) * (terms.bps as u128) / denominator;
    let cap = (price_mist as u128) * (MAX_COMMISSION_BPS as u128) / denominator;
    let floor = terms.min_mist as u128;
    let commission = if (share > floor) share else floor;
    (if (commission > cap) cap else commission) as u64
}

/// The lowest price a paid gate may have: 10 × the minimum commission (so that floor never exceeds
/// the 10% cap), and at least 1 MIST.
public fun min_paid_price_mist(platform: &PlatformConfig): u64 {
    let min = ((platform.min_commission_mist as u128) * (BPS_DENOMINATOR as u128)
        + (MAX_COMMISSION_BPS as u128) - 1) / (MAX_COMMISSION_BPS as u128);
    if (min == 0) 1
    else if (min > 18_446_744_073_709_551_615) 18_446_744_073_709_551_615
    else min as u64
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
/// unlimited pass or zero uses, and with `E_PAUSED` while the gate is paused if its policy has
/// `pause_blocks_access`.
#[allow(lint(self_transfer))]
public fun consume(mut nft: AccessNFT, gate: &Gate, nonce: vector<u8>, ctx: &mut TxContext) {
    let nft_id = object::id(&nft);
    let ts = ctx.epoch_timestamp_ms();
    let burn = consume_data(&mut nft.data, gate, nonce, nft_id, ts, ctx.sender());
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
    let burn = consume_data(&mut nft.data, gate, nonce, nft_id, ts, ctx.sender());
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
    consumer: address,
): bool {
    assert!(vector::length(&nonce) >= MIN_NONCE_LENGTH, E_INVALID_NONCE);
    assert!(data.gate_id == object::id(gate), E_WRONG_GATE);
    assert!(!(gate.paused && gate.policy.pause_blocks_access), E_PAUSED);
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
                consumer,
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
/// no setter or `airdrop` can run; `purchase`/`consume` remain permissionless.
///
/// Policy-dependent behaviour:
/// - freezing a **paused** gate is allowed (it then never sells again) unless the gate's policy has
///   `freeze_requires_unpaused`, in which case this aborts with `E_FREEZE_WHILE_PAUSED`;
/// - with `lock_commission_on_freeze`, the current platform commission terms are snapshotted and
///   used for every later purchase of this gate.
///
/// Perform any final `set_*`/`airdrop` BEFORE calling this. Mirrors
/// `0x2::package::make_immutable` for a package's `UpgradeCap`.
public fun make_gate_immutable(
    cap: AdminCap,
    gate: &mut Gate,
    platform: &PlatformConfig,
    ctx: &TxContext,
) {
    assert_admin_mutable(&cap, gate);
    if (gate.policy.freeze_requires_unpaused) assert!(!gate.paused, E_FREEZE_WHILE_PAUSED);
    if (gate.policy.lock_commission_on_freeze) {
        gate.locked_commission = option::some(commission_terms(platform));
    };
    gate.frozen = true;
    event::emit(GateFrozenEvent {
        gate_id: object::id(gate),
        locked_commission: gate.locked_commission,
        timestamp_ms: ctx.epoch_timestamp_ms(),
    });
    let AdminCap { id, gate_id: _ } = cap;
    id.delete();
}

/// Update the gate price for future purchases. A paid price must be at least
/// `min_paid_price_mist(platform)` (`E_PRICE_TOO_LOW`); 0 is allowed only once the free-gate fee
/// has been paid (`E_FREE_FEE_UNPAID` — use `make_gate_free`).
public fun set_price(cap: &AdminCap, gate: &mut Gate, platform: &PlatformConfig, price_mist: u64) {
    assert_admin_mutable(cap, gate);
    if (price_mist == 0) assert!(gate.free_fee_paid, E_FREE_FEE_UNPAID)
    else assert!(price_mist >= min_paid_price_mist(platform), E_PRICE_TOO_LOW);
    gate.price_mist = price_mist;
}

/// Make the gate free (price 0), paying the platform's `free_gate_fee_mist` from `payment` unless it
/// was already paid for this gate; any excess is refunded.
public fun make_gate_free(
    cap: &AdminCap,
    gate: &mut Gate,
    platform: &PlatformConfig,
    payment: Coin<SUI>,
    ctx: &mut TxContext,
) {
    assert_admin_mutable(cap, gate);
    let fee = if (gate.free_fee_paid) 0 else platform.free_gate_fee_mist;
    pay_to(payment, fee, platform.treasury, ctx);
    gate.free_fee_paid = true;
    gate.price_mist = 0;
    event::emit(GateMadeFreeEvent {
        gate_id: object::id(gate),
        fee_paid_mist: fee,
        timestamp_ms: ctx.epoch_timestamp_ms(),
    });
}

/// Redirect future purchase payments to a new recipient address.
public fun set_payment_recipient(cap: &AdminCap, gate: &mut Gate, recipient: address) {
    assert_admin_mutable(cap, gate);
    gate.payment_recipient = recipient;
}

/// Pause or unpause `purchase` (and, per the gate's policy, `consume` and dependent access).
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

/// Toggle the auto-burn policy. The flag is read from the gate at `consume` time, so it
/// applies to **every** single-use NFT of this gate — already-minted ones included — whose
/// next consume reaches zero.
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

/// Update the platform treasury address (where commission and fees are routed).
public fun set_platform_treasury(
    _cap: &PlatformAdminCap,
    config: &mut PlatformConfig,
    treasury: address,
) {
    assert!(treasury != @0x0, E_ZERO_ADDRESS);
    config.treasury = treasury;
    emit_platform_updated(config);
}

/// Update the platform commission rate. Hard cap: 1000 bps (10%).
public fun set_commission_bps(
    _cap: &PlatformAdminCap,
    config: &mut PlatformConfig,
    commission_bps: u64,
) {
    assert!(commission_bps <= MAX_COMMISSION_BPS, E_COMMISSION_TOO_HIGH);
    config.commission_bps = commission_bps;
    emit_platform_updated(config);
}

/// Update the commission floor. Existing gates keep their price; their commission stays capped at
/// 10% of it. New and re-priced paid gates must meet the new `min_paid_price_mist`.
public fun set_min_commission_mist(
    _cap: &PlatformAdminCap,
    config: &mut PlatformConfig,
    min_commission_mist: u64,
) {
    config.min_commission_mist = min_commission_mist;
    emit_platform_updated(config);
}

/// Update the one-off fee for making a gate free (affects gates made free from now on).
public fun set_free_gate_fee_mist(
    _cap: &PlatformAdminCap,
    config: &mut PlatformConfig,
    free_gate_fee_mist: u64,
) {
    config.free_gate_fee_mist = free_gate_fee_mist;
    emit_platform_updated(config);
}

fun emit_platform_updated(config: &PlatformConfig) {
    event::emit(PlatformConfigUpdatedEvent {
        treasury: config.treasury,
        commission_bps: config.commission_bps,
        min_commission_mist: config.min_commission_mist,
        free_gate_fee_mist: config.free_gate_fee_mist,
    });
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

/// The gate's immutable policy.
public fun gate_policy(gate: &Gate): GatePolicy { gate.policy }

/// True if `make_gate_immutable` refuses to freeze this gate while it is paused.
public fun gate_freeze_requires_unpaused(gate: &Gate): bool { gate.policy.freeze_requires_unpaused }

/// True if freezing snapshots the platform commission for this gate.
public fun gate_lock_commission_on_freeze(gate: &Gate): bool { gate.policy.lock_commission_on_freeze }

/// True if dependent decryption policies (Seal `nft_gate`) must deny access while paused.
public fun gate_pause_blocks_decryption(gate: &Gate): bool { gate.policy.pause_blocks_decryption }

/// True if `consume` and access gateways must deny holders while the gate is paused.
public fun gate_pause_blocks_access(gate: &Gate): bool { gate.policy.pause_blocks_access }

/// The freeze-time commission terms, if this gate locked them.
public fun gate_locked_commission(gate: &Gate): Option<CommissionTerms> { gate.locked_commission }

/// True once the free-gate fee has been paid for this gate (its price may then be 0).
public fun gate_free_fee_paid(gate: &Gate): bool { gate.free_fee_paid }

/// `GatePolicy` field accessors (for PTBs / other packages holding a policy value).
public fun policy_freeze_requires_unpaused(p: &GatePolicy): bool { p.freeze_requires_unpaused }
public fun policy_lock_commission_on_freeze(p: &GatePolicy): bool { p.lock_commission_on_freeze }
public fun policy_pause_blocks_decryption(p: &GatePolicy): bool { p.pause_blocks_decryption }
public fun policy_pause_blocks_access(p: &GatePolicy): bool { p.pause_blocks_access }

/// `CommissionTerms` field accessors.
public fun terms_bps(t: &CommissionTerms): u64 { t.bps }
public fun terms_min_mist(t: &CommissionTerms): u64 { t.min_mist }

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

/// Floor on a paid mint's commission, in MIST.
public fun platform_min_commission_mist(config: &PlatformConfig): u64 { config.min_commission_mist }

/// One-off fee to make a gate free, in MIST.
public fun platform_free_gate_fee_mist(config: &PlatformConfig): u64 { config.free_gate_fee_mist }

// ── Test-only helpers ─────────────────────────────────────────────────────────────

#[test_only]
/// Run `init` in a test scenario (creates Publisher, both Displays, PlatformAdminCap and the
/// shared PlatformConfig exactly as publish does).
public fun init_for_testing(ctx: &mut TxContext) {
    init(ACCESS_GATE {}, ctx);
}

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
    let treasury = ctx.sender();
    share_platform_config_full_for_testing(treasury, 0, 0, 0, ctx);
}

#[test_only]
/// Create and share a `PlatformConfig` with an explicit `treasury` + `commission_bps` for tests
/// that exercise the commission split. (Bypasses the `set_commission_bps` cap by construction —
/// use `set_commission_bps` itself to test the `E_COMMISSION_TOO_HIGH` boundary.)
public fun share_platform_config_for_testing(treasury: address, commission_bps: u64, ctx: &mut TxContext) {
    share_platform_config_full_for_testing(treasury, commission_bps, 0, 0, ctx);
}

#[test_only]
/// Create and share a `PlatformConfig` with every term explicit.
public fun share_platform_config_full_for_testing(
    treasury: address,
    commission_bps: u64,
    min_commission_mist: u64,
    free_gate_fee_mist: u64,
    ctx: &mut TxContext,
) {
    transfer::share_object(PlatformConfig {
        id: object::new(ctx),
        treasury,
        commission_bps,
        min_commission_mist,
        free_gate_fee_mist,
    });
}

#[test_only]
/// Build `CommissionTerms` directly (for `commission_for_price` tests).
public fun commission_terms_for_testing(bps: u64, min_mist: u64): CommissionTerms {
    CommissionTerms { bps, min_mist }
}

#[test_only]
/// Mint a `PlatformAdminCap` for tests exercising the platform setters.
public fun new_platform_admin_cap_for_testing(ctx: &mut TxContext): PlatformAdminCap {
    PlatformAdminCap { id: object::new(ctx) }
}

#[test_only]
public fun burn_platform_admin_cap_for_testing(cap: PlatformAdminCap) {
    let PlatformAdminCap { id } = cap;
    id.delete();
}
