// SPDX-License-Identifier: 0BSD
// Licensed under the 0BSD license; see the LICENSE file.

#[test_only]
module access_gate::access_gate_tests;

use access_gate::access_gate::{Self, Gate, AdminCap, AccessNFT, SoulboundAccessNFT, PlatformConfig, PlatformAdminCap, ACCESS_GATE};
use sui::display::Display;
use sui::package::Publisher;
use sui::coin;
use sui::sui::SUI;
use sui::test_scenario as ts;

const CREATOR: address = @0xA1;
const BUYER: address = @0xB0B;
const PAYEE: address = @0xFEE;
const TREASURY: address = @0x7EA;

// Helper: share a PlatformConfig with explicit terms and move to the next tx (so it can be taken).
fun setup_platform_with(
    s: &mut ts::Scenario,
    treasury: address,
    commission_bps: u64,
    min_commission_mist: u64,
    free_gate_fee_mist: u64,
) {
    access_gate::share_platform_config_full_for_testing(
        treasury, commission_bps, min_commission_mist, free_gate_fee_mist, s.ctx(),
    );
    let sender = s.sender();
    s.next_tx(sender);
}

// Helper: a zero-commission, zero-fee PlatformConfig (exact payment amounts in tests).
fun setup_platform(s: &mut ts::Scenario) {
    let sender = s.sender();
    setup_platform_with(s, sender, 0, 0, 0);
}

// Helper: create a gate with explicit policy flags (sets up a zero-fee platform if none exists).
// Price 0 goes through `create_free_gate`, paying the platform's free-gate fee exactly.
fun new_gate_full(
    s: &mut ts::Scenario,
    price: u64,
    default_uses: u64,
    soulbound: bool,
    auto_burn: bool,
    policy: access_gate::GatePolicy,
) {
    if (!ts::has_most_recent_shared<PlatformConfig>()) setup_platform(s);
    let platform = s.take_shared<PlatformConfig>();
    if (price == 0) {
        let fee = coin::mint_for_testing<SUI>(platform.platform_free_gate_fee_mist(), s.ctx());
        access_gate::create_free_gate(
            &platform, fee, PAYEE, default_uses, soulbound, auto_burn,
            b"".to_string(), b"".to_string(), b"".to_string(), policy, s.ctx(),
        );
    } else {
        access_gate::create_gate(
            &platform, price, PAYEE, default_uses, soulbound, auto_burn,
            b"".to_string(), b"".to_string(), b"".to_string(), policy, s.ctx(),
        );
    };
    ts::return_shared(platform);
}

// Helpers: the version-gated calls take the shared PlatformConfig; borrow it for the call.
fun consume_t(s: &mut ts::Scenario, nft: AccessNFT, gate: &Gate, nonce: vector<u8>) {
    let platform = s.take_shared<PlatformConfig>();
    access_gate::consume(nft, gate, &platform, nonce, s.ctx());
    ts::return_shared(platform);
}

fun consume_soulbound_t(s: &mut ts::Scenario, nft: SoulboundAccessNFT, gate: &Gate, nonce: vector<u8>) {
    let platform = s.take_shared<PlatformConfig>();
    access_gate::consume_soulbound(nft, gate, &platform, nonce, s.ctx());
    ts::return_shared(platform);
}

fun set_paused_t(s: &mut ts::Scenario, cap: &AdminCap, gate: &mut Gate, v: bool) {
    let platform = s.take_shared<PlatformConfig>();
    access_gate::set_paused(cap, gate, &platform, v);
    ts::return_shared(platform);
}



fun set_auto_burn_at_zero_t(s: &mut ts::Scenario, cap: &AdminCap, gate: &mut Gate, v: bool) {
    let platform = s.take_shared<PlatformConfig>();
    access_gate::set_auto_burn_at_zero(cap, gate, &platform, v);
    ts::return_shared(platform);
}


// Helper: create a gate with the unrestricted default policy.
fun new_gate(s: &mut ts::Scenario, price: u64, default_uses: u64, soulbound: bool, auto_burn: bool) {
    new_gate_full(s, price, default_uses, soulbound, auto_burn, access_gate::default_gate_policy());
}

// Helper: freeze `gate` with the shared PlatformConfig (must already exist).
fun freeze_gate(s: &mut ts::Scenario, cap: AdminCap, gate: &mut Gate) {
    let platform = s.take_shared<PlatformConfig>();
    access_gate::make_gate_immutable(cap, gate, &platform, s.ctx());
    ts::return_shared(platform);
}

// Helper: create a paid, unlimited gate with explicit policy flags.
fun new_gate_with_policy(
    s: &mut ts::Scenario,
    price: u64,
    freeze_requires_unpaused: bool,
    lock_commission_on_freeze: bool,
    pause_blocks_decryption: bool,
) {
    new_gate_full(
        s, price, 0, false, false,
        access_gate::new_gate_policy(freeze_requires_unpaused, lock_commission_on_freeze, pause_blocks_decryption, false),
    );
}

// Helper: set a price with the shared PlatformConfig.
fun set_price(s: &mut ts::Scenario, cap: &AdminCap, gate: &mut Gate, price: u64) {
    let platform = s.take_shared<PlatformConfig>();
    access_gate::set_price(cap, gate, &platform, price);
    ts::return_shared(platform);
}

// Helper: airdrop, paying exactly the commission due (from a minted coin).
fun airdrop(s: &mut ts::Scenario, cap: &AdminCap, gate: &Gate, recipient: address) {
    let platform = s.take_shared<PlatformConfig>();
    let due = access_gate::gate_commission_mist(gate, &platform);
    let payment = coin::mint_for_testing<SUI>(due, s.ctx());
    access_gate::airdrop(cap, gate, &platform, payment, recipient, s.ctx());
    ts::return_shared(platform);
}

#[test]
fun test_create_gate_shares_gate_and_grants_cap() {
    let mut s = ts::begin(CREATOR);
    new_gate(&mut s, 1_000, 0, false, false);
    s.next_tx(CREATOR);

    // Gate is shared; creator holds the AdminCap.
    assert!(ts::has_most_recent_shared<Gate>(), 0);
    assert!(s.has_most_recent_for_sender<AdminCap>(), 1);

    let gate = s.take_shared<Gate>();
    assert!(gate.gate_price_mist() == 1_000, 2);
    assert!(gate.gate_default_uses() == 0, 3);
    assert!(!gate.gate_is_soulbound(), 4);
    assert!(!gate.gate_is_paused(), 5);
    assert!(gate.gate_payment_recipient() == PAYEE, 6);
    ts::return_shared(gate);
    s.end();
}

#[test]
fun test_purchase_unlimited_pass_routes_payment_and_mints() {
    let mut s = ts::begin(CREATOR);
    setup_platform(&mut s);
    new_gate(&mut s, 500, 0, false, false);
    s.next_tx(BUYER);

    let gate = s.take_shared<Gate>();
    let platform = s.take_shared<PlatformConfig>();
    let payment = coin::mint_for_testing<SUI>(500, s.ctx());
    access_gate::purchase(&gate, &platform, payment, s.ctx());
    ts::return_shared(gate);
    ts::return_shared(platform);

    s.next_tx(BUYER);
    // Buyer received a transferable NFT.
    assert!(s.has_most_recent_for_sender<AccessNFT>(), 0);
    let nft = s.take_from_sender<AccessNFT>();
    assert!(nft.uses_remaining().is_none(), 1); // unlimited pass
    s.return_to_sender(nft);

    s.next_tx(PAYEE);
    // Commission is 0 (test helper), so payee received the full price.
    let paid = s.take_from_sender<coin::Coin<SUI>>();
    assert!(paid.value() == 500, 2);
    s.return_to_sender(paid);
    s.end();
}

#[test]
fun test_purchase_overpay_refunds_remainder() {
    let mut s = ts::begin(CREATOR);
    setup_platform(&mut s);
    new_gate(&mut s, 500, 0, false, false);
    s.next_tx(BUYER);

    let gate = s.take_shared<Gate>();
    let platform = s.take_shared<PlatformConfig>();
    let payment = coin::mint_for_testing<SUI>(800, s.ctx());
    access_gate::purchase(&gate, &platform, payment, s.ctx());
    ts::return_shared(gate);
    ts::return_shared(platform);

    s.next_tx(BUYER);
    // 300 refunded to buyer.
    let refund = s.take_from_sender<coin::Coin<SUI>>();
    assert!(refund.value() == 300, 0);
    s.return_to_sender(refund);
    s.end();
}

#[test]
fun test_purchase_free_gate() {
    let mut s = ts::begin(CREATOR);
    setup_platform(&mut s);
    new_gate(&mut s, 0, 0, false, false);
    s.next_tx(BUYER);

    let gate = s.take_shared<Gate>();
    let platform = s.take_shared<PlatformConfig>();
    let payment = coin::mint_for_testing<SUI>(0, s.ctx());
    access_gate::purchase(&gate, &platform, payment, s.ctx());
    ts::return_shared(gate);
    ts::return_shared(platform);

    s.next_tx(BUYER);
    assert!(s.has_most_recent_for_sender<AccessNFT>(), 0);
    s.end();
}

#[test]
#[expected_failure(abort_code = 2)]
fun test_purchase_underpay_aborts() {
    let mut s = ts::begin(CREATOR);
    setup_platform(&mut s);
    new_gate(&mut s, 500, 0, false, false);
    s.next_tx(BUYER);

    let gate = s.take_shared<Gate>();
    let platform = s.take_shared<PlatformConfig>();
    let payment = coin::mint_for_testing<SUI>(499, s.ctx());
    access_gate::purchase(&gate, &platform, payment, s.ctx()); // aborts E_INSUFFICIENT_PAYMENT
    ts::return_shared(platform);
    ts::return_shared(gate);
    s.end();
}

#[test]
#[expected_failure(abort_code = 1)]
fun test_purchase_paused_aborts() {
    let mut s = ts::begin(CREATOR);
    setup_platform(&mut s);
    new_gate(&mut s, 500, 0, false, false);
    s.next_tx(CREATOR);
    let cap = s.take_from_sender<AdminCap>();
    let mut gate = s.take_shared<Gate>();
    set_paused_t(&mut s, &cap, &mut gate, true);
    s.return_to_sender(cap);
    ts::return_shared(gate);

    s.next_tx(BUYER);
    let gate = s.take_shared<Gate>();
    let platform = s.take_shared<PlatformConfig>();
    let payment = coin::mint_for_testing<SUI>(500, s.ctx());
    access_gate::purchase(&gate, &platform, payment, s.ctx()); // aborts E_PAUSED
    ts::return_shared(platform);
    ts::return_shared(gate);
    s.end();
}

#[test]
fun test_single_use_consume_decrements_and_returns_receipt() {
    let mut s = ts::begin(CREATOR);
    setup_platform(&mut s);
    new_gate(&mut s, 0, 3, false, false); // 3 uses, no auto-burn
    s.next_tx(BUYER);

    let gate = s.take_shared<Gate>();
    let platform = s.take_shared<PlatformConfig>();
    access_gate::purchase(&gate, &platform, coin::mint_for_testing<SUI>(0, s.ctx()), s.ctx());
    ts::return_shared(gate);
    ts::return_shared(platform);

    s.next_tx(BUYER);
    let gate = s.take_shared<Gate>();
    let nft = s.take_from_sender<AccessNFT>();
    assert!(nft.uses_remaining() == option::some(3), 0);
    consume_t(&mut s, nft, &gate, b"nonce-01");
    ts::return_shared(gate);

    s.next_tx(BUYER);
    // Receipt returned with 2 uses left (no auto-burn).
    let nft = s.take_from_sender<AccessNFT>();
    assert!(nft.uses_remaining() == option::some(2), 1);
    s.return_to_sender(nft);
    s.end();
}

#[test]
fun test_single_use_auto_burn_at_zero_deletes() {
    let mut s = ts::begin(CREATOR);
    setup_platform(&mut s);
    new_gate(&mut s, 0, 1, false, true); // 1 use, auto-burn
    s.next_tx(BUYER);

    let gate = s.take_shared<Gate>();
    let platform = s.take_shared<PlatformConfig>();
    access_gate::purchase(&gate, &platform, coin::mint_for_testing<SUI>(0, s.ctx()), s.ctx());
    ts::return_shared(gate);
    ts::return_shared(platform);

    s.next_tx(BUYER);
    let gate = s.take_shared<Gate>();
    let nft = s.take_from_sender<AccessNFT>();
    consume_t(&mut s, nft, &gate, b"nonce-01");
    ts::return_shared(gate);

    s.next_tx(BUYER);
    // NFT was deleted at zero — nothing left for the sender.
    assert!(!s.has_most_recent_for_sender<AccessNFT>(), 0);
    s.end();
}

#[test]
fun test_single_use_no_auto_burn_keeps_zero_receipt() {
    let mut s = ts::begin(CREATOR);
    setup_platform(&mut s);
    new_gate(&mut s, 0, 1, false, false); // 1 use, keep receipt
    s.next_tx(BUYER);

    let gate = s.take_shared<Gate>();
    let platform = s.take_shared<PlatformConfig>();
    access_gate::purchase(&gate, &platform, coin::mint_for_testing<SUI>(0, s.ctx()), s.ctx());
    ts::return_shared(gate);
    ts::return_shared(platform);

    s.next_tx(BUYER);
    let gate = s.take_shared<Gate>();
    let nft = s.take_from_sender<AccessNFT>();
    consume_t(&mut s, nft, &gate, b"nonce-01");
    ts::return_shared(gate);

    s.next_tx(BUYER);
    let nft = s.take_from_sender<AccessNFT>();
    assert!(nft.uses_remaining() == option::some(0), 0); // spent receipt
    s.return_to_sender(nft);
    s.end();
}

#[test]
#[expected_failure(abort_code = 8)]
fun test_consume_short_nonce_aborts() {
    let mut s = ts::begin(CREATOR);
    setup_platform(&mut s);
    new_gate(&mut s, 0, 2, false, false);
    s.next_tx(BUYER);

    let gate = s.take_shared<Gate>();
    let platform = s.take_shared<PlatformConfig>();
    access_gate::purchase(&gate, &platform, coin::mint_for_testing<SUI>(0, s.ctx()), s.ctx());
    ts::return_shared(gate);
    ts::return_shared(platform);

    s.next_tx(BUYER);
    let gate = s.take_shared<Gate>();
    let nft = s.take_from_sender<AccessNFT>();
    consume_t(&mut s, nft, &gate, b"short"); // 5 bytes < MIN_NONCE_LENGTH -> abort E_INVALID_NONCE
    ts::return_shared(gate);
    s.end();
}

#[test]
#[expected_failure(abort_code = 3)]
fun test_consume_unlimited_pass_aborts() {
    let mut s = ts::begin(CREATOR);
    setup_platform(&mut s);
    new_gate(&mut s, 0, 0, false, false);
    s.next_tx(BUYER);

    let gate = s.take_shared<Gate>();
    let platform = s.take_shared<PlatformConfig>();
    access_gate::purchase(&gate, &platform, coin::mint_for_testing<SUI>(0, s.ctx()), s.ctx());
    ts::return_shared(gate);
    ts::return_shared(platform);

    s.next_tx(BUYER);
    let gate = s.take_shared<Gate>();
    let nft = s.take_from_sender<AccessNFT>();
    consume_t(&mut s, nft, &gate, b"00000001"); // aborts E_NOT_SINGLE_USE
    ts::return_shared(gate);
    s.end();
}

#[test]
#[expected_failure(abort_code = 4)]
fun test_consume_exhausted_aborts() {
    let mut s = ts::begin(CREATOR);
    setup_platform(&mut s);
    new_gate(&mut s, 0, 1, false, false); // keep zero receipt, then try again
    s.next_tx(BUYER);

    let gate = s.take_shared<Gate>();
    let platform = s.take_shared<PlatformConfig>();
    access_gate::purchase(&gate, &platform, coin::mint_for_testing<SUI>(0, s.ctx()), s.ctx());
    ts::return_shared(gate);
    ts::return_shared(platform);

    s.next_tx(BUYER);
    let gate = s.take_shared<Gate>();
    let nft = s.take_from_sender<AccessNFT>();
    consume_t(&mut s, nft, &gate, b"00000001");
    ts::return_shared(gate);

    s.next_tx(BUYER);
    let gate = s.take_shared<Gate>();
    let nft = s.take_from_sender<AccessNFT>();
    consume_t(&mut s, nft, &gate, b"00000002"); // zero uses -> abort E_NO_USES_REMAINING
    ts::return_shared(gate);
    s.end();
}

#[test]
fun test_soulbound_mint_and_consume() {
    let mut s = ts::begin(CREATOR);
    setup_platform(&mut s);
    new_gate(&mut s, 0, 2, true, false); // soulbound, single-use
    s.next_tx(BUYER);

    let gate = s.take_shared<Gate>();
    let platform = s.take_shared<PlatformConfig>();
    access_gate::purchase(&gate, &platform, coin::mint_for_testing<SUI>(0, s.ctx()), s.ctx());
    ts::return_shared(gate);
    ts::return_shared(platform);

    s.next_tx(BUYER);
    // Soulbound type minted, not the transferable one.
    assert!(s.has_most_recent_for_sender<SoulboundAccessNFT>(), 0);
    assert!(!s.has_most_recent_for_sender<AccessNFT>(), 1);

    let gate = s.take_shared<Gate>();
    let nft = s.take_from_sender<SoulboundAccessNFT>();
    assert!(nft.uses_remaining_soulbound() == option::some(2), 2);
    consume_soulbound_t(&mut s, nft, &gate, b"nonce-sb");
    ts::return_shared(gate);

    s.next_tx(BUYER);
    let nft = s.take_from_sender<SoulboundAccessNFT>();
    assert!(nft.uses_remaining_soulbound() == option::some(1), 3);
    s.return_to_sender(nft);
    s.end();
}

#[test]
#[expected_failure(abort_code = 5)]
fun test_consume_wrong_gate_aborts() {
    let mut s = ts::begin(CREATOR);
    setup_platform(&mut s);
    // Gate A (buyer mints from it), then a second gate B.
    new_gate(&mut s, 0, 2, false, false);
    s.next_tx(BUYER);
    let gate_a = s.take_shared<Gate>();
    let platform = s.take_shared<PlatformConfig>();
    access_gate::purchase(&gate_a, &platform, coin::mint_for_testing<SUI>(0, s.ctx()), s.ctx());
    ts::return_shared(gate_a);
    ts::return_shared(platform);

    s.next_tx(CREATOR);
    new_gate(&mut s, 0, 2, false, false); // second gate

    s.next_tx(BUYER);
    let nft = s.take_from_sender<AccessNFT>();
    // Take the OTHER gate (the newest shared one is gate B).
    let gate_b = s.take_shared<Gate>();
    consume_t(&mut s, nft, &gate_b, b"00000001"); // NFT belongs to gate A -> abort E_WRONG_GATE
    ts::return_shared(gate_b);
    s.end();
}

#[test]
fun test_airdrop_grants_without_payment() {
    let mut s = ts::begin(CREATOR);
    new_gate(&mut s, 1_000_000, 0, false, false);
    s.next_tx(CREATOR);
    let cap = s.take_from_sender<AdminCap>();
    let gate = s.take_shared<Gate>();
    airdrop(&mut s, &cap, &gate, BUYER);
    s.return_to_sender(cap);
    ts::return_shared(gate);

    s.next_tx(BUYER);
    assert!(s.has_most_recent_for_sender<AccessNFT>(), 0);
    s.end();
}

#[test]
fun test_admin_setters() {
    let mut s = ts::begin(CREATOR);
    new_gate(&mut s, 100, 0, false, false);
    s.next_tx(CREATOR);
    let cap = s.take_from_sender<AdminCap>();
    let mut gate = s.take_shared<Gate>();

    // One borrow of the shared PlatformConfig per transaction (test_scenario rule).
    let platform = s.take_shared<PlatformConfig>();
    access_gate::set_price(&cap, &mut gate, &platform, 250);
    access_gate::set_default_uses(&cap, &mut gate, &platform, 5);
    access_gate::set_soulbound(&cap, &mut gate, &platform, true);
    access_gate::set_auto_burn_at_zero(&cap, &mut gate, &platform, true);
    access_gate::set_payment_recipient(&cap, &mut gate, &platform, BUYER);
    ts::return_shared(platform);

    assert!(gate.gate_price_mist() == 250, 0);
    assert!(gate.gate_default_uses() == 5, 1);
    assert!(gate.gate_is_soulbound(), 2);
    assert!(gate.gate_auto_burn_at_zero(), 3);
    assert!(gate.gate_payment_recipient() == BUYER, 4);

    s.return_to_sender(cap);
    ts::return_shared(gate);
    s.end();
}

#[test]
fun test_burn_voluntary() {
    let mut s = ts::begin(CREATOR);
    setup_platform(&mut s);
    new_gate(&mut s, 0, 0, false, false);
    s.next_tx(BUYER);
    let gate = s.take_shared<Gate>();
    let platform = s.take_shared<PlatformConfig>();
    access_gate::purchase(&gate, &platform, coin::mint_for_testing<SUI>(0, s.ctx()), s.ctx());
    ts::return_shared(gate);
    ts::return_shared(platform);

    s.next_tx(BUYER);
    let nft = s.take_from_sender<AccessNFT>();
    access_gate::burn(nft, s.ctx());

    s.next_tx(BUYER);
    assert!(!s.has_most_recent_for_sender<AccessNFT>(), 0);
    s.end();
}

#[test]
fun test_make_gate_immutable_renounces_cap_and_freezes() {
    let mut s = ts::begin(CREATOR);
    setup_platform(&mut s);
    new_gate(&mut s, 100, 0, false, false);
    s.next_tx(CREATOR);
    let cap = s.take_from_sender<AdminCap>();
    let mut gate = s.take_shared<Gate>();
    assert!(!gate.gate_is_frozen(), 0);

    freeze_gate(&mut s, cap, &mut gate); // consumes cap
    assert!(gate.gate_is_frozen(), 1);
    ts::return_shared(gate);

    s.next_tx(CREATOR);
    // The AdminCap was destroyed — nothing left for the creator.
    assert!(!s.has_most_recent_for_sender<AdminCap>(), 2);

    // purchase still works on a frozen gate (permissionless path unaffected).
    s.next_tx(BUYER);
    let gate = s.take_shared<Gate>();
    let platform = s.take_shared<PlatformConfig>();
    access_gate::purchase(&gate, &platform, coin::mint_for_testing<SUI>(100, s.ctx()), s.ctx());
    ts::return_shared(gate);
    ts::return_shared(platform);

    s.next_tx(BUYER);
    assert!(s.has_most_recent_for_sender<AccessNFT>(), 3);
    s.end();
}

#[test]
#[expected_failure(abort_code = 6)]
fun test_setter_on_frozen_gate_aborts() {
    // Demonstrates the defensive frozen guard: if a cap somehow coexists with a frozen
    // gate, setters abort E_GATE_FROZEN. We freeze via a first cap, then attempt a setter
    // with a second (test-only) cap minted for the same gate.
    let mut s = ts::begin(CREATOR);
    setup_platform(&mut s);
    new_gate(&mut s, 100, 0, false, false);
    s.next_tx(CREATOR);
    let cap = s.take_from_sender<AdminCap>();
    let mut gate = s.take_shared<Gate>();
    let cap2 = access_gate::new_admin_cap_for_testing(&gate, s.ctx());
    let platform = s.take_shared<PlatformConfig>();
    access_gate::make_gate_immutable(cap, &mut gate, &platform, s.ctx());
    access_gate::set_price(&cap2, &mut gate, &platform, 1); // gate frozen -> abort E_GATE_FROZEN
    access_gate::burn_admin_cap_for_testing(cap2);
    ts::return_shared(platform);
    ts::return_shared(gate);
    s.end();
}

// ── Commission split (C.1) ─────────────────────────────────────────────────────

#[test]
fun test_purchase_nonzero_commission_splits_payment() {
    let mut s = ts::begin(CREATOR);
    // 2.5% commission to TREASURY; gate price 1000 → commission 25, operator share 975.
    setup_platform_with(&mut s, TREASURY, 250, 0, 0);
    new_gate(&mut s, 1_000, 0, false, false);
    s.next_tx(BUYER);

    let gate = s.take_shared<Gate>();
    let platform = s.take_shared<PlatformConfig>();
    let payment = coin::mint_for_testing<SUI>(1_000, s.ctx());
    access_gate::purchase(&gate, &platform, payment, s.ctx());
    ts::return_shared(gate);
    ts::return_shared(platform);

    // Treasury receives exactly the 2.5% commission.
    s.next_tx(TREASURY);
    let commission = s.take_from_sender<coin::Coin<SUI>>();
    assert!(commission.value() == 25, 0);
    s.return_to_sender(commission);

    // Payee receives exactly the operator share (price − commission).
    s.next_tx(PAYEE);
    let paid = s.take_from_sender<coin::Coin<SUI>>();
    assert!(paid.value() == 975, 1);
    s.return_to_sender(paid);
    s.end();
}

// ── Commission cap boundary (E_COMMISSION_TOO_HIGH = 7) ─────────────────────────

#[test]
fun test_set_commission_at_cap_succeeds() {
    let mut s = ts::begin(CREATOR);
    setup_platform_with(&mut s, TREASURY, 0, 0, 0);
    let cap = access_gate::new_platform_admin_cap_for_testing(s.ctx());
    s.next_tx(CREATOR);

    let mut platform = s.take_shared<PlatformConfig>();
    access_gate::set_commission_bps(&cap, &mut platform, 1000); // exactly 10% — inclusive cap
    assert!(platform.platform_commission_bps() == 1000, 0);
    ts::return_shared(platform);
    access_gate::burn_platform_admin_cap_for_testing(cap);
    s.end();
}

#[test]
#[expected_failure(abort_code = 7)] // E_COMMISSION_TOO_HIGH
fun test_set_commission_above_cap_aborts() {
    let mut s = ts::begin(CREATOR);
    setup_platform_with(&mut s, TREASURY, 0, 0, 0);
    let cap = access_gate::new_platform_admin_cap_for_testing(s.ctx());
    s.next_tx(CREATOR);

    let mut platform = s.take_shared<PlatformConfig>();
    access_gate::set_commission_bps(&cap, &mut platform, 1001); // > cap → abort
    ts::return_shared(platform);
    access_gate::burn_platform_admin_cap_for_testing(cap);
    s.end();
}

// ── Arithmetic boundary (no u64 overflow) ─────────────────────────────────────────

#[test]
fun test_purchase_max_price_max_commission_does_not_overflow() {
    let max = 18_446_744_073_709_551_615; // u64::MAX
    let mut s = ts::begin(CREATOR);
    setup_platform_with(&mut s, TREASURY, 1000, 0, 0); // 10% cap
    new_gate(&mut s, max, 0, false, false);
    s.next_tx(BUYER);

    let gate = s.take_shared<Gate>();
    let platform = s.take_shared<PlatformConfig>();
    access_gate::purchase(&gate, &platform, coin::mint_for_testing<SUI>(max, s.ctx()), s.ctx());
    ts::return_shared(gate);
    ts::return_shared(platform);

    // floor(MAX * 1000 / 10000) = 1_844_674_407_370_955_161; operator gets the rest.
    s.next_tx(TREASURY);
    let commission = s.take_from_sender<coin::Coin<SUI>>();
    assert!(commission.value() == 1_844_674_407_370_955_161, 0);
    s.return_to_sender(commission);
    s.next_tx(PAYEE);
    let paid = s.take_from_sender<coin::Coin<SUI>>();
    assert!(paid.value() == max - 1_844_674_407_370_955_161, 1);
    s.return_to_sender(paid);
    s.end();
}

#[test]
fun test_commission_dust_rounds_to_zero() {
    // 20 bps on a 499 MIST price: floor(499 * 20 / 10000) = 0 → operator receives everything.
    let mut s = ts::begin(CREATOR);
    setup_platform_with(&mut s, TREASURY, 20, 0, 0);
    new_gate(&mut s, 499, 0, false, false);
    s.next_tx(BUYER);
    let gate = s.take_shared<Gate>();
    let platform = s.take_shared<PlatformConfig>();
    access_gate::purchase(&gate, &platform, coin::mint_for_testing<SUI>(499, s.ctx()), s.ctx());
    ts::return_shared(gate);
    ts::return_shared(platform);

    s.next_tx(TREASURY);
    assert!(!s.has_most_recent_for_sender<coin::Coin<SUI>>(), 0);
    s.next_tx(PAYEE);
    let paid = s.take_from_sender<coin::Coin<SUI>>();
    assert!(paid.value() == 499, 1);
    s.return_to_sender(paid);
    s.end();
}

// ── Platform treasury setter (E_ZERO_ADDRESS = 9) ────────────────────────────────

#[test]
fun test_set_platform_treasury_updates() {
    let mut s = ts::begin(CREATOR);
    setup_platform_with(&mut s, TREASURY, 20, 0, 0);
    let cap = access_gate::new_platform_admin_cap_for_testing(s.ctx());
    s.next_tx(CREATOR);
    let mut platform = s.take_shared<PlatformConfig>();
    access_gate::set_platform_treasury(&cap, &mut platform, PAYEE);
    assert!(platform.platform_treasury() == PAYEE, 0);
    ts::return_shared(platform);
    access_gate::burn_platform_admin_cap_for_testing(cap);
    s.end();
}

#[test]
#[expected_failure(abort_code = 9)] // E_ZERO_ADDRESS
fun test_set_platform_treasury_zero_address_aborts() {
    let mut s = ts::begin(CREATOR);
    setup_platform_with(&mut s, TREASURY, 20, 0, 0);
    let cap = access_gate::new_platform_admin_cap_for_testing(s.ctx());
    s.next_tx(CREATOR);
    let mut platform = s.take_shared<PlatformConfig>();
    access_gate::set_platform_treasury(&cap, &mut platform, @0x0);
    ts::return_shared(platform);
    access_gate::burn_platform_admin_cap_for_testing(cap);
    s.end();
}

// ── init defaults ─────────────────────────────────────────────────────────────────

#[test]
fun test_init_creates_platform_objects() {
    let mut s = ts::begin(CREATOR);
    access_gate::init_for_testing(s.ctx());
    s.next_tx(CREATOR);

    let platform = s.take_shared<PlatformConfig>();
    assert!(platform.platform_commission_bps() == 20, 0);
    assert!(platform.platform_treasury() == CREATOR, 1);
    assert!(platform.platform_min_commission_mist() == 1_000_000, 7);
    assert!(platform.platform_free_gate_fee_mist() == 100_000_000, 8);
    assert!(access_gate::min_paid_price_mist(&platform) == 10_000_000, 9);
    ts::return_shared(platform);

    assert!(s.has_most_recent_for_sender<PlatformAdminCap>(), 2);
    assert!(s.has_most_recent_for_sender<Publisher>(), 3);
    assert!(s.has_most_recent_for_sender<Display<AccessNFT>>(), 4);
    assert!(s.has_most_recent_for_sender<Display<SoulboundAccessNFT>>(), 5);
    let publisher = s.take_from_sender<Publisher>();
    assert!(publisher.from_module<ACCESS_GATE>(), 6);
    s.return_to_sender(publisher);
    s.end();
}

// ── Soulbound variants of the consume/burn paths ─────────────────────────────────

// Helper: buyer obtains a soulbound NFT from a fresh gate with `uses` (0 = unlimited).
fun buy_soulbound(s: &mut ts::Scenario, uses: u64) {
    setup_platform(s);
    new_gate(s, 0, uses, true, false);
    s.next_tx(BUYER);
    let gate = s.take_shared<Gate>();
    let platform = s.take_shared<PlatformConfig>();
    access_gate::purchase(&gate, &platform, coin::mint_for_testing<SUI>(0, s.ctx()), s.ctx());
    ts::return_shared(gate);
    ts::return_shared(platform);
    s.next_tx(BUYER);
}

#[test]
fun test_burn_soulbound() {
    let mut s = ts::begin(CREATOR);
    buy_soulbound(&mut s, 0);
    let nft = s.take_from_sender<SoulboundAccessNFT>();
    access_gate::burn_soulbound(nft, s.ctx());
    s.next_tx(BUYER);
    assert!(!s.has_most_recent_for_sender<SoulboundAccessNFT>(), 0);
    s.end();
}

#[test]
#[expected_failure(abort_code = 3)] // E_NOT_SINGLE_USE
fun test_consume_soulbound_unlimited_aborts() {
    let mut s = ts::begin(CREATOR);
    buy_soulbound(&mut s, 0);
    let gate = s.take_shared<Gate>();
    let nft = s.take_from_sender<SoulboundAccessNFT>();
    consume_soulbound_t(&mut s, nft, &gate, b"00000001");
    ts::return_shared(gate);
    s.end();
}

#[test]
#[expected_failure(abort_code = 4)] // E_NO_USES_REMAINING
fun test_consume_soulbound_exhausted_aborts() {
    let mut s = ts::begin(CREATOR);
    buy_soulbound(&mut s, 1);
    let gate = s.take_shared<Gate>();
    let nft = s.take_from_sender<SoulboundAccessNFT>();
    consume_soulbound_t(&mut s, nft, &gate, b"00000001");
    ts::return_shared(gate);
    s.next_tx(BUYER);
    let gate = s.take_shared<Gate>();
    let nft = s.take_from_sender<SoulboundAccessNFT>();
    consume_soulbound_t(&mut s, nft, &gate, b"00000002");
    ts::return_shared(gate);
    s.end();
}

#[test]
#[expected_failure(abort_code = 5)] // E_WRONG_GATE
fun test_consume_soulbound_wrong_gate_aborts() {
    let mut s = ts::begin(CREATOR);
    buy_soulbound(&mut s, 2);
    s.next_tx(CREATOR);
    new_gate(&mut s, 0, 2, true, false); // gate B
    s.next_tx(BUYER);
    let nft = s.take_from_sender<SoulboundAccessNFT>();
    let gate_b = s.take_shared<Gate>();
    consume_soulbound_t(&mut s, nft, &gate_b, b"00000001");
    ts::return_shared(gate_b);
    s.end();
}

#[test]
#[expected_failure(abort_code = 8)] // E_INVALID_NONCE
fun test_consume_soulbound_short_nonce_aborts() {
    let mut s = ts::begin(CREATOR);
    buy_soulbound(&mut s, 2);
    let gate = s.take_shared<Gate>();
    let nft = s.take_from_sender<SoulboundAccessNFT>();
    consume_soulbound_t(&mut s, nft, &gate, b"1234567"); // 7 bytes
    ts::return_shared(gate);
    s.end();
}

// ── AdminCap binding & frozen-gate behaviour ─────────────────────────────────────

#[test]
#[expected_failure(abort_code = 5)] // E_WRONG_GATE
fun test_setter_with_foreign_admin_cap_aborts() {
    let mut s = ts::begin(CREATOR);
    new_gate(&mut s, 100, 0, false, false); // gate A → cap A
    s.next_tx(CREATOR);
    let cap_a = s.take_from_sender<AdminCap>();
    new_gate(&mut s, 100, 0, false, false); // gate B
    s.next_tx(CREATOR);
    let mut gate_b = s.take_shared<Gate>();
    set_price(&mut s, &cap_a, &mut gate_b, 1); // cap A on gate B
    ts::return_shared(gate_b);
    s.return_to_sender(cap_a);
    s.end();
}

#[test]
#[expected_failure(abort_code = 6)] // E_GATE_FROZEN
fun test_airdrop_on_frozen_gate_aborts() {
    let mut s = ts::begin(CREATOR);
    setup_platform(&mut s);
    new_gate(&mut s, 100, 0, false, false);
    s.next_tx(CREATOR);
    let cap = s.take_from_sender<AdminCap>();
    let mut gate = s.take_shared<Gate>();
    let cap2 = access_gate::new_admin_cap_for_testing(&gate, s.ctx());
    let platform = s.take_shared<PlatformConfig>();
    access_gate::make_gate_immutable(cap, &mut gate, &platform, s.ctx());
    let payment = coin::mint_for_testing<SUI>(0, s.ctx());
    access_gate::airdrop(&cap2, &gate, &platform, payment, BUYER, s.ctx()); // frozen -> E_GATE_FROZEN
    access_gate::burn_admin_cap_for_testing(cap2);
    ts::return_shared(platform);
    ts::return_shared(gate);
    s.end();
}

#[test]
#[expected_failure(abort_code = 1)] // E_PAUSED — a gate frozen while paused can never sell again
fun test_frozen_while_paused_gate_cannot_be_purchased() {
    let mut s = ts::begin(CREATOR);
    setup_platform(&mut s);
    new_gate(&mut s, 0, 0, false, false);
    s.next_tx(CREATOR);
    let cap = s.take_from_sender<AdminCap>();
    let mut gate = s.take_shared<Gate>();
    let platform = s.take_shared<PlatformConfig>();
    access_gate::set_paused(&cap, &mut gate, &platform, true);
    access_gate::make_gate_immutable(cap, &mut gate, &platform, s.ctx());
    ts::return_shared(platform);
    ts::return_shared(gate);

    s.next_tx(BUYER);
    let gate = s.take_shared<Gate>();
    let platform = s.take_shared<PlatformConfig>();
    access_gate::purchase(&gate, &platform, coin::mint_for_testing<SUI>(0, s.ctx()), s.ctx());
    ts::return_shared(gate);
    ts::return_shared(platform);
    s.end();
}

#[test]
fun test_auto_burn_change_applies_to_existing_nfts() {
    // Documents current semantics: auto_burn_at_zero is read at consume time.
    let mut s = ts::begin(CREATOR);
    setup_platform(&mut s);
    new_gate(&mut s, 0, 1, false, false); // minted with auto-burn OFF
    s.next_tx(BUYER);
    let gate = s.take_shared<Gate>();
    let platform = s.take_shared<PlatformConfig>();
    access_gate::purchase(&gate, &platform, coin::mint_for_testing<SUI>(0, s.ctx()), s.ctx());
    ts::return_shared(gate);
    ts::return_shared(platform);

    s.next_tx(CREATOR);
    let cap = s.take_from_sender<AdminCap>();
    let mut gate = s.take_shared<Gate>();
    set_auto_burn_at_zero_t(&mut s, &cap, &mut gate, true); // turned ON after mint
    s.return_to_sender(cap);
    ts::return_shared(gate);

    s.next_tx(BUYER);
    let gate = s.take_shared<Gate>();
    let nft = s.take_from_sender<AccessNFT>();
    consume_t(&mut s, nft, &gate, b"00000001");
    ts::return_shared(gate);
    s.next_tx(BUYER);
    assert!(!s.has_most_recent_for_sender<AccessNFT>(), 0); // deleted, not kept as receipt
    s.end();
}

// ── Gate policy (operator-selectable restrictions) ────────────────────────────────

#[test]
fun test_create_gate_uses_default_unrestricted_policy() {
    let mut s = ts::begin(CREATOR);
    new_gate(&mut s, 100, 0, false, false);
    s.next_tx(CREATOR);
    let gate = s.take_shared<Gate>();
    assert!(!gate.gate_freeze_requires_unpaused(), 0);
    assert!(!gate.gate_lock_commission_on_freeze(), 1);
    assert!(!gate.gate_pause_blocks_decryption(), 2);
    assert!(gate.gate_locked_commission().is_none(), 3);
    assert!(!gate.gate_pause_blocks_access(), 4);
    ts::return_shared(gate);
    s.end();
}

#[test]
fun test_create_gate_with_policy_stores_policy() {
    let mut s = ts::begin(CREATOR);
    new_gate_with_policy(&mut s, 100, true, true, true);
    s.next_tx(CREATOR);
    let gate = s.take_shared<Gate>();
    let policy = gate.gate_policy();
    assert!(policy.policy_freeze_requires_unpaused(), 0);
    assert!(policy.policy_lock_commission_on_freeze(), 1);
    assert!(policy.policy_pause_blocks_decryption(), 2);
    assert!(gate.gate_pause_blocks_decryption(), 3);
    ts::return_shared(gate);
    s.end();
}

#[test]
#[expected_failure(abort_code = 10)] // E_FREEZE_WHILE_PAUSED
fun test_freeze_requires_unpaused_blocks_freezing_paused_gate() {
    let mut s = ts::begin(CREATOR);
    setup_platform(&mut s);
    new_gate_with_policy(&mut s, 100, true, false, false);
    s.next_tx(CREATOR);
    let cap = s.take_from_sender<AdminCap>();
    let mut gate = s.take_shared<Gate>();
    let platform = s.take_shared<PlatformConfig>();
    access_gate::set_paused(&cap, &mut gate, &platform, true);
    access_gate::make_gate_immutable(cap, &mut gate, &platform, s.ctx());
    ts::return_shared(platform);
    ts::return_shared(gate);
    s.end();
}

#[test]
fun test_freeze_requires_unpaused_allows_freezing_unpaused_gate() {
    let mut s = ts::begin(CREATOR);
    setup_platform(&mut s);
    new_gate_with_policy(&mut s, 100, true, false, false);
    s.next_tx(CREATOR);
    let cap = s.take_from_sender<AdminCap>();
    let mut gate = s.take_shared<Gate>();
    freeze_gate(&mut s, cap, &mut gate);
    assert!(gate.gate_is_frozen(), 0);
    ts::return_shared(gate);
    s.end();
}

// Freezes a 1000-MIST gate at 250 bps, raises the platform rate to the 1000-bps cap, then buys.
fun freeze_then_raise_commission_then_buy(lock: bool): u64 {
    let mut s = ts::begin(CREATOR);
    setup_platform_with(&mut s, TREASURY, 250, 0, 0);
    new_gate_with_policy(&mut s, 1_000, false, lock, false);
    s.next_tx(CREATOR);
    let cap = s.take_from_sender<AdminCap>();
    let mut gate = s.take_shared<Gate>();
    freeze_gate(&mut s, cap, &mut gate);
    let locked = gate.gate_locked_commission();
    assert!(locked.is_some() == lock, 100);
    if (lock) assert!(locked.borrow().terms_bps() == 250, 101);
    ts::return_shared(gate);

    s.next_tx(CREATOR);
    let admin = access_gate::new_platform_admin_cap_for_testing(s.ctx());
    let mut platform = s.take_shared<PlatformConfig>();
    access_gate::set_commission_bps(&admin, &mut platform, 1000);
    ts::return_shared(platform);
    access_gate::burn_platform_admin_cap_for_testing(admin);

    s.next_tx(BUYER);
    let gate = s.take_shared<Gate>();
    let platform = s.take_shared<PlatformConfig>();
    access_gate::purchase(&gate, &platform, coin::mint_for_testing<SUI>(1_000, s.ctx()), s.ctx());
    ts::return_shared(gate);
    ts::return_shared(platform);

    s.next_tx(TREASURY);
    let commission = s.take_from_sender<coin::Coin<SUI>>();
    let value = commission.value();
    s.return_to_sender(commission);
    s.end();
    value
}

#[test]
fun test_lock_commission_on_freeze_uses_snapshot() {
    assert!(freeze_then_raise_commission_then_buy(true) == 25, 0); // 2.5% snapshot, not 10%
}

#[test]
fun test_frozen_gate_without_lock_follows_live_commission() {
    assert!(freeze_then_raise_commission_then_buy(false) == 100, 0); // live 10%
}

// ── Commission floor, minimum price and the 10% cap ───────────────────────────────

// Buys one pass from the most recent gate paying `price`, returns what the treasury received.
fun buy_and_read_treasury(s: &mut ts::Scenario, price: u64): u64 {
    s.next_tx(BUYER);
    let gate = s.take_shared<Gate>();
    let platform = s.take_shared<PlatformConfig>();
    access_gate::purchase(&gate, &platform, coin::mint_for_testing<SUI>(price, s.ctx()), s.ctx());
    ts::return_shared(gate);
    ts::return_shared(platform);
    s.next_tx(TREASURY);
    if (!s.has_most_recent_for_sender<coin::Coin<SUI>>()) return 0;
    let c = s.take_from_sender<coin::Coin<SUI>>();
    let v = c.value();
    s.return_to_sender(c);
    v
}

#[test]
fun test_min_commission_applies_to_cheap_purchases() {
    let mut s = ts::begin(CREATOR);
    setup_platform_with(&mut s, TREASURY, 20, 1_000_000, 0);
    new_gate(&mut s, 10_000_000, 0, false, false); // 0.2% would be 20_000 < floor
    assert!(buy_and_read_treasury(&mut s, 10_000_000) == 1_000_000, 0);
    s.next_tx(PAYEE);
    let paid = s.take_from_sender<coin::Coin<SUI>>();
    assert!(paid.value() == 9_000_000, 1);
    s.return_to_sender(paid);
    s.end();
}

#[test]
fun test_percentage_applies_above_the_floor() {
    let mut s = ts::begin(CREATOR);
    setup_platform_with(&mut s, TREASURY, 20, 1_000_000, 0);
    new_gate(&mut s, 1_000_000_000_000, 0, false, false); // 1000 SUI → 0.2% = 2 SUI
    assert!(buy_and_read_treasury(&mut s, 1_000_000_000_000) == 2_000_000_000, 0);
    s.end();
}

#[test]
fun test_commission_capped_at_ten_percent_after_floor_raise() {
    let mut s = ts::begin(CREATOR);
    setup_platform_with(&mut s, TREASURY, 20, 1_000_000, 0);
    new_gate(&mut s, 10_000_000, 0, false, false);
    s.next_tx(CREATOR);
    let admin = access_gate::new_platform_admin_cap_for_testing(s.ctx());
    let mut platform = s.take_shared<PlatformConfig>();
    access_gate::set_min_commission_mist(&admin, &mut platform, 5_000_000); // floor now > 10% of price
    ts::return_shared(platform);
    access_gate::burn_platform_admin_cap_for_testing(admin);
    assert!(buy_and_read_treasury(&mut s, 10_000_000) == 1_000_000, 0); // capped at 10%
    s.end();
}

#[test]
fun test_min_paid_price_is_ten_times_the_floor() {
    let mut s = ts::begin(CREATOR);
    setup_platform_with(&mut s, TREASURY, 20, 0, 0);
    let admin = access_gate::new_platform_admin_cap_for_testing(s.ctx());
    let mut platform = s.take_shared<PlatformConfig>();
    assert!(access_gate::min_paid_price_mist(&platform) == 1, 0);
    access_gate::set_min_commission_mist(&admin, &mut platform, 1);
    assert!(access_gate::min_paid_price_mist(&platform) == 10, 1);
    access_gate::set_min_commission_mist(&admin, &mut platform, 1_000_000);
    assert!(access_gate::min_paid_price_mist(&platform) == 10_000_000, 2);
    access_gate::set_min_commission_mist(&admin, &mut platform, 18_446_744_073_709_551_615);
    assert!(access_gate::min_paid_price_mist(&platform) == 18_446_744_073_709_551_615, 3); // saturates
    ts::return_shared(platform);
    access_gate::burn_platform_admin_cap_for_testing(admin);
    s.end();
}

#[test]
fun test_commission_for_price_formula() {
    let t = access_gate::commission_terms_for_testing(20, 1_000_000);
    assert!(access_gate::commission_for_price(0, &t) == 0, 0);
    assert!(access_gate::commission_for_price(10_000_000, &t) == 1_000_000, 1);
    assert!(access_gate::commission_for_price(5_000_000, &t) == 500_000, 2); // capped at 10%
    assert!(access_gate::commission_for_price(1_000_000_000, &t) == 2_000_000, 3); // 0.2%
}

#[test]
#[expected_failure(abort_code = 11)] // E_PRICE_TOO_LOW
fun test_create_gate_below_min_price_aborts() {
    let mut s = ts::begin(CREATOR);
    setup_platform_with(&mut s, TREASURY, 20, 1_000_000, 0);
    new_gate(&mut s, 9_999_999, 0, false, false);
    s.end();
}

#[test]
#[expected_failure(abort_code = 11)] // E_PRICE_TOO_LOW — free gates go through create_free_gate
fun test_create_gate_zero_price_aborts() {
    let mut s = ts::begin(CREATOR);
    setup_platform(&mut s);
    let platform = s.take_shared<PlatformConfig>();
    access_gate::create_gate(
        &platform, 0, PAYEE, 0, false, false,
        b"".to_string(), b"".to_string(), b"".to_string(), access_gate::default_gate_policy(), s.ctx(),
    );
    ts::return_shared(platform);
    s.end();
}

#[test]
#[expected_failure(abort_code = 11)] // E_PRICE_TOO_LOW
fun test_set_price_below_min_aborts() {
    let mut s = ts::begin(CREATOR);
    setup_platform_with(&mut s, TREASURY, 20, 1_000_000, 0);
    new_gate(&mut s, 10_000_000, 0, false, false);
    s.next_tx(CREATOR);
    let cap = s.take_from_sender<AdminCap>();
    let mut gate = s.take_shared<Gate>();
    set_price(&mut s, &cap, &mut gate, 9_999_999);
    s.return_to_sender(cap);
    ts::return_shared(gate);
    s.end();
}

// ── Free gates ──────────────────────────────────────────────────────────────────

#[test]
fun test_create_free_gate_pays_fee_and_refunds_excess() {
    let mut s = ts::begin(CREATOR);
    setup_platform_with(&mut s, TREASURY, 20, 1_000_000, 100);
    let platform = s.take_shared<PlatformConfig>();
    access_gate::create_free_gate(
        &platform, coin::mint_for_testing<SUI>(150, s.ctx()), PAYEE, 0, false, false,
        b"".to_string(), b"".to_string(), b"".to_string(), access_gate::default_gate_policy(), s.ctx(),
    );
    ts::return_shared(platform);
    s.next_tx(CREATOR);
    let gate = s.take_shared<Gate>();
    assert!(gate.gate_price_mist() == 0, 0);
    assert!(gate.gate_free_fee_paid(), 1);
    ts::return_shared(gate);
    let refund = s.take_from_sender<coin::Coin<SUI>>();
    assert!(refund.value() == 50, 2);
    s.return_to_sender(refund);
    s.next_tx(TREASURY);
    let fee = s.take_from_sender<coin::Coin<SUI>>();
    assert!(fee.value() == 100, 3);
    s.return_to_sender(fee);
    // Buying from a free gate pays nothing.
    assert!(buy_and_read_treasury(&mut s, 0) == 100, 4); // still only the fee coin
    s.end();
}

#[test]
#[expected_failure(abort_code = 2)] // E_INSUFFICIENT_PAYMENT
fun test_create_free_gate_underpaid_fee_aborts() {
    let mut s = ts::begin(CREATOR);
    setup_platform_with(&mut s, TREASURY, 20, 0, 100);
    let platform = s.take_shared<PlatformConfig>();
    access_gate::create_free_gate(
        &platform, coin::mint_for_testing<SUI>(99, s.ctx()), PAYEE, 0, false, false,
        b"".to_string(), b"".to_string(), b"".to_string(), access_gate::default_gate_policy(), s.ctx(),
    );
    ts::return_shared(platform);
    s.end();
}

#[test]
#[expected_failure(abort_code = 12)] // E_FREE_FEE_UNPAID
fun test_set_price_zero_without_fee_aborts() {
    let mut s = ts::begin(CREATOR);
    setup_platform_with(&mut s, TREASURY, 20, 0, 100);
    new_gate(&mut s, 1_000, 0, false, false);
    s.next_tx(CREATOR);
    let cap = s.take_from_sender<AdminCap>();
    let mut gate = s.take_shared<Gate>();
    set_price(&mut s, &cap, &mut gate, 0);
    s.return_to_sender(cap);
    ts::return_shared(gate);
    s.end();
}

#[test]
fun test_make_gate_free_charges_once_then_price_can_toggle() {
    let mut s = ts::begin(CREATOR);
    setup_platform_with(&mut s, TREASURY, 20, 0, 100);
    new_gate(&mut s, 1_000, 0, false, false);
    s.next_tx(CREATOR);
    let cap = s.take_from_sender<AdminCap>();
    let mut gate = s.take_shared<Gate>();
    let platform = s.take_shared<PlatformConfig>();
    access_gate::make_gate_free(&cap, &mut gate, &platform, coin::mint_for_testing<SUI>(100, s.ctx()), s.ctx());
    assert!(gate.gate_price_mist() == 0 && gate.gate_free_fee_paid(), 0);
    access_gate::set_price(&cap, &mut gate, &platform, 2_000); // back to paid
    access_gate::set_price(&cap, &mut gate, &platform, 0);     // free again: fee already paid
    // A second make_gate_free charges nothing and refunds the coin.
    access_gate::make_gate_free(&cap, &mut gate, &platform, coin::mint_for_testing<SUI>(7, s.ctx()), s.ctx());
    ts::return_shared(platform);
    ts::return_shared(gate);
    s.return_to_sender(cap);
    s.next_tx(CREATOR);
    let refund = s.take_from_sender<coin::Coin<SUI>>();
    assert!(refund.value() == 7, 1);
    s.return_to_sender(refund);
    s.next_tx(TREASURY);
    let fee = s.take_from_sender<coin::Coin<SUI>>();
    assert!(fee.value() == 100, 2);
    s.return_to_sender(fee);
    s.end();
}

// ── Airdrop commission ───────────────────────────────────────────────────────────

#[test]
fun test_airdrop_pays_commission_on_paid_gate() {
    let mut s = ts::begin(CREATOR);
    setup_platform_with(&mut s, TREASURY, 20, 1_000_000, 0);
    new_gate(&mut s, 10_000_000, 0, false, false);
    s.next_tx(CREATOR);
    let cap = s.take_from_sender<AdminCap>();
    let gate = s.take_shared<Gate>();
    airdrop(&mut s, &cap, &gate, BUYER); // pays exactly gate_commission_mist = 1_000_000
    s.return_to_sender(cap);
    ts::return_shared(gate);
    s.next_tx(TREASURY);
    let c = s.take_from_sender<coin::Coin<SUI>>();
    assert!(c.value() == 1_000_000, 0);
    s.return_to_sender(c);
    s.next_tx(BUYER);
    assert!(s.has_most_recent_for_sender<AccessNFT>(), 1);
    s.end();
}

#[test]
#[expected_failure(abort_code = 2)] // E_INSUFFICIENT_PAYMENT
fun test_airdrop_underpaid_commission_aborts() {
    let mut s = ts::begin(CREATOR);
    setup_platform_with(&mut s, TREASURY, 20, 1_000_000, 0);
    new_gate(&mut s, 10_000_000, 0, false, false);
    s.next_tx(CREATOR);
    let cap = s.take_from_sender<AdminCap>();
    let gate = s.take_shared<Gate>();
    let platform = s.take_shared<PlatformConfig>();
    access_gate::airdrop(&cap, &gate, &platform, coin::mint_for_testing<SUI>(999_999, s.ctx()), BUYER, s.ctx());
    ts::return_shared(platform);
    ts::return_shared(gate);
    s.return_to_sender(cap);
    s.end();
}

// ── pause_blocks_access ───────────────────────────────────────────────────────────

// Mints a 2-use pass from a gate with `pause_blocks_access = block`, pauses the gate, then consumes.
fun consume_while_paused(block: bool) {
    let mut s = ts::begin(CREATOR);
    setup_platform(&mut s);
    new_gate_full(&mut s, 0, 2, false, false, access_gate::new_gate_policy(false, false, false, block));
    s.next_tx(BUYER);
    let gate = s.take_shared<Gate>();
    let platform = s.take_shared<PlatformConfig>();
    access_gate::purchase(&gate, &platform, coin::mint_for_testing<SUI>(0, s.ctx()), s.ctx());
    ts::return_shared(gate);
    ts::return_shared(platform);
    s.next_tx(CREATOR);
    let cap = s.take_from_sender<AdminCap>();
    let mut gate = s.take_shared<Gate>();
    set_paused_t(&mut s, &cap, &mut gate, true);
    assert!(gate.gate_pause_blocks_access() == block, 0);
    s.return_to_sender(cap);
    ts::return_shared(gate);
    s.next_tx(BUYER);
    let gate = s.take_shared<Gate>();
    let nft = s.take_from_sender<AccessNFT>();
    consume_t(&mut s, nft, &gate, b"00000001");
    ts::return_shared(gate);
    s.end();
}

#[test]
#[expected_failure(abort_code = 1)] // E_PAUSED
fun test_pause_blocks_access_stops_consume() {
    consume_while_paused(true);
}

#[test]
fun test_pause_without_access_policy_allows_consume() {
    consume_while_paused(false);
}

// ── Locked terms include the floor ────────────────────────────────────────────────

fun freeze_then_raise_floor_then_buy(lock: bool): u64 {
    let mut s = ts::begin(CREATOR);
    setup_platform_with(&mut s, TREASURY, 20, 1_000_000, 0);
    new_gate_full(&mut s, 100_000_000, 0, false, false, access_gate::new_gate_policy(false, lock, false, false));
    s.next_tx(CREATOR);
    let cap = s.take_from_sender<AdminCap>();
    let mut gate = s.take_shared<Gate>();
    freeze_gate(&mut s, cap, &mut gate);
    ts::return_shared(gate);
    s.next_tx(CREATOR);
    let admin = access_gate::new_platform_admin_cap_for_testing(s.ctx());
    let mut platform = s.take_shared<PlatformConfig>();
    access_gate::set_min_commission_mist(&admin, &mut platform, 5_000_000);
    ts::return_shared(platform);
    access_gate::burn_platform_admin_cap_for_testing(admin);
    let v = buy_and_read_treasury(&mut s, 100_000_000);
    s.end();
    v
}

#[test]
fun test_locked_terms_keep_the_floor() {
    assert!(freeze_then_raise_floor_then_buy(true) == 1_000_000, 0);
    assert!(freeze_then_raise_floor_then_buy(false) == 5_000_000, 1);
}

// ── Platform fee setters ──────────────────────────────────────────────────────────

#[test]
fun test_platform_fee_setters_update() {
    let mut s = ts::begin(CREATOR);
    setup_platform_with(&mut s, TREASURY, 20, 0, 0);
    let admin = access_gate::new_platform_admin_cap_for_testing(s.ctx());
    let mut platform = s.take_shared<PlatformConfig>();
    access_gate::set_min_commission_mist(&admin, &mut platform, 42);
    access_gate::set_free_gate_fee_mist(&admin, &mut platform, 7);
    assert!(platform.platform_min_commission_mist() == 42, 0);
    assert!(platform.platform_free_gate_fee_mist() == 7, 1);
    ts::return_shared(platform);
    access_gate::burn_platform_admin_cap_for_testing(admin);
    s.end();
}


// ── Version gating (E_WRONG_VERSION = 13, E_NOT_UPGRADE = 14) ───────────────────

// Helper: a paid 2-use gate (soulbound if `soulbound`), the buyer holding one NFT, then the shared
// PlatformConfig moved to `version` — as if a newer package had migrated it, so this package's calls
// must abort. Ends in a fresh CREATOR transaction.
fun versioned_setup(s: &mut ts::Scenario, soulbound: bool, version: u64) {
    setup_platform(s);
    new_gate(s, 100, 2, soulbound, false);
    s.next_tx(BUYER);
    let gate = s.take_shared<Gate>();
    let platform = s.take_shared<PlatformConfig>();
    access_gate::purchase(&gate, &platform, coin::mint_for_testing<SUI>(100, s.ctx()), s.ctx());
    ts::return_shared(gate);
    ts::return_shared(platform);
    s.next_tx(CREATOR);
    let mut platform = s.take_shared<PlatformConfig>();
    access_gate::set_platform_version_for_testing(&mut platform, version);
    ts::return_shared(platform);
    s.next_tx(CREATOR);
}

#[test]
#[expected_failure(abort_code = 13)]
fun test_wrong_version_blocks_airdrop() {
    let mut s = ts::begin(CREATOR);
    versioned_setup(&mut s, false, 2);
    let cap = s.take_from_sender<AdminCap>();
    let mut gate = s.take_shared<Gate>();
    let platform = s.take_shared<PlatformConfig>();
    access_gate::airdrop(&cap, &gate, &platform, coin::mint_for_testing<SUI>(0, s.ctx()), BUYER, s.ctx());
    s.return_to_sender(cap);
    ts::return_shared(gate);
    ts::return_shared(platform);
    s.end();
}

#[test]
#[expected_failure(abort_code = 13)]
fun test_wrong_version_blocks_set_price() {
    let mut s = ts::begin(CREATOR);
    versioned_setup(&mut s, false, 2);
    let cap = s.take_from_sender<AdminCap>();
    let mut gate = s.take_shared<Gate>();
    let platform = s.take_shared<PlatformConfig>();
    access_gate::set_price(&cap, &mut gate, &platform, 250);
    s.return_to_sender(cap);
    ts::return_shared(gate);
    ts::return_shared(platform);
    s.end();
}

#[test]
#[expected_failure(abort_code = 13)]
fun test_wrong_version_blocks_make_gate_free() {
    let mut s = ts::begin(CREATOR);
    versioned_setup(&mut s, false, 2);
    let cap = s.take_from_sender<AdminCap>();
    let mut gate = s.take_shared<Gate>();
    let platform = s.take_shared<PlatformConfig>();
    access_gate::make_gate_free(&cap, &mut gate, &platform, coin::mint_for_testing<SUI>(0, s.ctx()), s.ctx());
    s.return_to_sender(cap);
    ts::return_shared(gate);
    ts::return_shared(platform);
    s.end();
}

#[test]
#[expected_failure(abort_code = 13)]
fun test_wrong_version_blocks_set_payment_recipient() {
    let mut s = ts::begin(CREATOR);
    versioned_setup(&mut s, false, 2);
    let cap = s.take_from_sender<AdminCap>();
    let mut gate = s.take_shared<Gate>();
    let platform = s.take_shared<PlatformConfig>();
    access_gate::set_payment_recipient(&cap, &mut gate, &platform, BUYER);
    s.return_to_sender(cap);
    ts::return_shared(gate);
    ts::return_shared(platform);
    s.end();
}

#[test]
#[expected_failure(abort_code = 13)]
fun test_wrong_version_blocks_set_paused() {
    let mut s = ts::begin(CREATOR);
    versioned_setup(&mut s, false, 2);
    let cap = s.take_from_sender<AdminCap>();
    let mut gate = s.take_shared<Gate>();
    let platform = s.take_shared<PlatformConfig>();
    access_gate::set_paused(&cap, &mut gate, &platform, true);
    s.return_to_sender(cap);
    ts::return_shared(gate);
    ts::return_shared(platform);
    s.end();
}

#[test]
#[expected_failure(abort_code = 13)]
fun test_wrong_version_blocks_set_default_uses() {
    let mut s = ts::begin(CREATOR);
    versioned_setup(&mut s, false, 2);
    let cap = s.take_from_sender<AdminCap>();
    let mut gate = s.take_shared<Gate>();
    let platform = s.take_shared<PlatformConfig>();
    access_gate::set_default_uses(&cap, &mut gate, &platform, 5);
    s.return_to_sender(cap);
    ts::return_shared(gate);
    ts::return_shared(platform);
    s.end();
}

#[test]
#[expected_failure(abort_code = 13)]
fun test_wrong_version_blocks_set_soulbound() {
    let mut s = ts::begin(CREATOR);
    versioned_setup(&mut s, false, 2);
    let cap = s.take_from_sender<AdminCap>();
    let mut gate = s.take_shared<Gate>();
    let platform = s.take_shared<PlatformConfig>();
    access_gate::set_soulbound(&cap, &mut gate, &platform, true);
    s.return_to_sender(cap);
    ts::return_shared(gate);
    ts::return_shared(platform);
    s.end();
}

#[test]
#[expected_failure(abort_code = 13)]
fun test_wrong_version_blocks_set_auto_burn_at_zero() {
    let mut s = ts::begin(CREATOR);
    versioned_setup(&mut s, false, 2);
    let cap = s.take_from_sender<AdminCap>();
    let mut gate = s.take_shared<Gate>();
    let platform = s.take_shared<PlatformConfig>();
    access_gate::set_auto_burn_at_zero(&cap, &mut gate, &platform, true);
    s.return_to_sender(cap);
    ts::return_shared(gate);
    ts::return_shared(platform);
    s.end();
}

#[test]
#[expected_failure(abort_code = 13)]
fun test_wrong_version_blocks_set_nft_name() {
    let mut s = ts::begin(CREATOR);
    versioned_setup(&mut s, false, 2);
    let cap = s.take_from_sender<AdminCap>();
    let mut gate = s.take_shared<Gate>();
    let platform = s.take_shared<PlatformConfig>();
    access_gate::set_nft_name(&cap, &mut gate, &platform, b"n".to_string());
    s.return_to_sender(cap);
    ts::return_shared(gate);
    ts::return_shared(platform);
    s.end();
}

#[test]
#[expected_failure(abort_code = 13)]
fun test_wrong_version_blocks_set_nft_image_url() {
    let mut s = ts::begin(CREATOR);
    versioned_setup(&mut s, false, 2);
    let cap = s.take_from_sender<AdminCap>();
    let mut gate = s.take_shared<Gate>();
    let platform = s.take_shared<PlatformConfig>();
    access_gate::set_nft_image_url(&cap, &mut gate, &platform, b"https://x".to_string());
    s.return_to_sender(cap);
    ts::return_shared(gate);
    ts::return_shared(platform);
    s.end();
}

#[test]
#[expected_failure(abort_code = 13)]
fun test_wrong_version_blocks_set_nft_description() {
    let mut s = ts::begin(CREATOR);
    versioned_setup(&mut s, false, 2);
    let cap = s.take_from_sender<AdminCap>();
    let mut gate = s.take_shared<Gate>();
    let platform = s.take_shared<PlatformConfig>();
    access_gate::set_nft_description(&cap, &mut gate, &platform, b"d".to_string());
    s.return_to_sender(cap);
    ts::return_shared(gate);
    ts::return_shared(platform);
    s.end();
}

#[test]
#[expected_failure(abort_code = 13)]
fun test_wrong_version_blocks_make_gate_immutable() {
    let mut s = ts::begin(CREATOR);
    versioned_setup(&mut s, false, 2);
    let cap = s.take_from_sender<AdminCap>();
    let mut gate = s.take_shared<Gate>();
    let platform = s.take_shared<PlatformConfig>();
    access_gate::make_gate_immutable(cap, &mut gate, &platform, s.ctx());
    ts::return_shared(gate);
    ts::return_shared(platform);
    s.end();
}

#[test]
#[expected_failure(abort_code = 13)]
fun test_wrong_version_blocks_create_gate() {
    let mut s = ts::begin(CREATOR);
    versioned_setup(&mut s, false, 2);
    let platform = s.take_shared<PlatformConfig>();
    access_gate::create_gate(
        &platform, 100, PAYEE, 0, false, false,
        b"".to_string(), b"".to_string(), b"".to_string(), access_gate::default_gate_policy(), s.ctx(),
    );
    ts::return_shared(platform);
    s.end();
}

#[test]
#[expected_failure(abort_code = 13)]
fun test_wrong_version_blocks_create_free_gate() {
    let mut s = ts::begin(CREATOR);
    versioned_setup(&mut s, false, 2);
    let platform = s.take_shared<PlatformConfig>();
    access_gate::create_free_gate(
        &platform, coin::mint_for_testing<SUI>(0, s.ctx()), PAYEE, 0, false, false,
        b"".to_string(), b"".to_string(), b"".to_string(), access_gate::default_gate_policy(), s.ctx(),
    );
    ts::return_shared(platform);
    s.end();
}

#[test]
#[expected_failure(abort_code = 13)]
fun test_wrong_version_blocks_purchase() {
    let mut s = ts::begin(CREATOR);
    versioned_setup(&mut s, false, 2);
    s.next_tx(BUYER);
    let gate = s.take_shared<Gate>();
    let platform = s.take_shared<PlatformConfig>();
    access_gate::purchase(&gate, &platform, coin::mint_for_testing<SUI>(100, s.ctx()), s.ctx());
    ts::return_shared(gate);
    ts::return_shared(platform);
    s.end();
}

#[test]
#[expected_failure(abort_code = 13)]
fun test_wrong_version_blocks_consume() {
    let mut s = ts::begin(CREATOR);
    versioned_setup(&mut s, false, 2);
    s.next_tx(BUYER);
    let gate = s.take_shared<Gate>();
    let nft = s.take_from_sender<AccessNFT>();
    consume_t(&mut s, nft, &gate, b"00000001");
    ts::return_shared(gate);
    s.end();
}

#[test]
#[expected_failure(abort_code = 13)]
fun test_wrong_version_blocks_consume_soulbound() {
    let mut s = ts::begin(CREATOR);
    versioned_setup(&mut s, true, 2);
    s.next_tx(BUYER);
    let gate = s.take_shared<Gate>();
    let nft = s.take_from_sender<SoulboundAccessNFT>();
    consume_soulbound_t(&mut s, nft, &gate, b"00000001");
    ts::return_shared(gate);
    s.end();
}

#[test]
#[expected_failure(abort_code = 13)]
fun test_wrong_version_blocks_set_platform_treasury() {
    let mut s = ts::begin(CREATOR);
    versioned_setup(&mut s, false, 2);
    let cap = access_gate::new_platform_admin_cap_for_testing(s.ctx());
    let mut platform = s.take_shared<PlatformConfig>();
    access_gate::set_platform_treasury(&cap, &mut platform, PAYEE);
    ts::return_shared(platform);
    access_gate::burn_platform_admin_cap_for_testing(cap);
    s.end();
}

#[test]
#[expected_failure(abort_code = 13)]
fun test_wrong_version_blocks_set_commission_bps() {
    let mut s = ts::begin(CREATOR);
    versioned_setup(&mut s, false, 2);
    let cap = access_gate::new_platform_admin_cap_for_testing(s.ctx());
    let mut platform = s.take_shared<PlatformConfig>();
    access_gate::set_commission_bps(&cap, &mut platform, 10);
    ts::return_shared(platform);
    access_gate::burn_platform_admin_cap_for_testing(cap);
    s.end();
}

#[test]
#[expected_failure(abort_code = 13)]
fun test_wrong_version_blocks_set_min_commission_mist() {
    let mut s = ts::begin(CREATOR);
    versioned_setup(&mut s, false, 2);
    let cap = access_gate::new_platform_admin_cap_for_testing(s.ctx());
    let mut platform = s.take_shared<PlatformConfig>();
    access_gate::set_min_commission_mist(&cap, &mut platform, 1);
    ts::return_shared(platform);
    access_gate::burn_platform_admin_cap_for_testing(cap);
    s.end();
}

#[test]
#[expected_failure(abort_code = 13)]
fun test_wrong_version_blocks_set_free_gate_fee_mist() {
    let mut s = ts::begin(CREATOR);
    versioned_setup(&mut s, false, 2);
    let cap = access_gate::new_platform_admin_cap_for_testing(s.ctx());
    let mut platform = s.take_shared<PlatformConfig>();
    access_gate::set_free_gate_fee_mist(&cap, &mut platform, 1);
    ts::return_shared(platform);
    access_gate::burn_platform_admin_cap_for_testing(cap);
    s.end();
}

#[test]
fun test_migrate_moves_an_older_config_forward() {
    let mut s = ts::begin(CREATOR);
    versioned_setup(&mut s, false, 0); // a config left at an older version: this package's calls abort
    let cap = access_gate::new_platform_admin_cap_for_testing(s.ctx());
    let mut platform = s.take_shared<PlatformConfig>();
    assert!(platform.platform_version() == 0, 0);
    access_gate::migrate(&cap, &mut platform);
    assert!(platform.platform_version() == access_gate::package_version(), 1);
    ts::return_shared(platform);
    access_gate::burn_platform_admin_cap_for_testing(cap);

    // After migrating, this version's calls work again.
    s.next_tx(BUYER);
    let gate = s.take_shared<Gate>();
    let platform = s.take_shared<PlatformConfig>();
    access_gate::purchase(&gate, &platform, coin::mint_for_testing<SUI>(100, s.ctx()), s.ctx());
    ts::return_shared(gate);
    ts::return_shared(platform);
    s.end();
}

#[test]
#[expected_failure(abort_code = 14)]
fun test_migrate_at_current_version_aborts() {
    let mut s = ts::begin(CREATOR);
    setup_platform(&mut s);
    let cap = access_gate::new_platform_admin_cap_for_testing(s.ctx());
    let mut platform = s.take_shared<PlatformConfig>();
    access_gate::migrate(&cap, &mut platform); // already at this version
    ts::return_shared(platform);
    access_gate::burn_platform_admin_cap_for_testing(cap);
    s.end();
}

#[test]
#[expected_failure(abort_code = 14)]
fun test_migrate_never_moves_backwards() {
    let mut s = ts::begin(CREATOR);
    versioned_setup(&mut s, false, 2); // migrated past this package by a newer one
    let cap = access_gate::new_platform_admin_cap_for_testing(s.ctx());
    let mut platform = s.take_shared<PlatformConfig>();
    access_gate::migrate(&cap, &mut platform);
    ts::return_shared(platform);
    access_gate::burn_platform_admin_cap_for_testing(cap);
    s.end();
}

#[test]
fun test_init_and_test_configs_start_at_the_package_version() {
    let mut s = ts::begin(CREATOR);
    access_gate::init_for_testing(s.ctx());
    s.next_tx(CREATOR);
    let platform = s.take_shared<PlatformConfig>();
    assert!(platform.platform_version() == access_gate::package_version(), 0);
    assert!(access_gate::package_version() == 1, 1);
    ts::return_shared(platform);
    s.end();
}
