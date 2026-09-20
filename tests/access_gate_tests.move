// SPDX-License-Identifier: CC0-1.0
// This work is dedicated to the public domain under CC0.

#[test_only]
module access_gate::access_gate_tests;

use access_gate::access_gate::{Self, Gate, AdminCap, AccessNFT, SoulboundAccessNFT, PlatformConfig};
use sui::coin;
use sui::sui::SUI;
use sui::test_scenario as ts;

const CREATOR: address = @0xA1;
const BUYER: address = @0xB0B;
const PAYEE: address = @0xFEE;
const TREASURY: address = @0x7EA;

// Helper: create a gate in the current tx with empty display metadata.
fun new_gate(
    s: &mut ts::Scenario,
    price: u64,
    default_uses: u64,
    soulbound: bool,
    auto_burn: bool,
) {
    access_gate::create_gate(
        price, PAYEE, default_uses, soulbound, auto_burn,
        b"".to_string(), b"".to_string(), b"".to_string(),
        s.ctx(),
    );
}

// Helper: create and share a zero-commission PlatformConfig in the current tx.
// Take it with `s.take_shared<PlatformConfig>()` after the next `s.next_tx(...)`.
fun setup_platform(s: &mut ts::Scenario) {
    access_gate::share_platform_config_zero_commission_for_testing(s.ctx());
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
    access_gate::set_paused(&cap, &mut gate, true);
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
    access_gate::consume(nft, &gate, b"nonce-01", s.ctx());
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
    access_gate::consume(nft, &gate, b"nonce-01", s.ctx());
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
    access_gate::consume(nft, &gate, b"nonce-01", s.ctx());
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
    access_gate::consume(nft, &gate, b"short", s.ctx()); // 5 bytes < MIN_NONCE_LENGTH -> abort E_INVALID_NONCE
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
    access_gate::consume(nft, &gate, b"00000001", s.ctx()); // aborts E_NOT_SINGLE_USE
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
    access_gate::consume(nft, &gate, b"00000001", s.ctx());
    ts::return_shared(gate);

    s.next_tx(BUYER);
    let gate = s.take_shared<Gate>();
    let nft = s.take_from_sender<AccessNFT>();
    access_gate::consume(nft, &gate, b"00000002", s.ctx()); // zero uses -> abort E_NO_USES_REMAINING
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
    access_gate::consume_soulbound(nft, &gate, b"nonce-sb", s.ctx());
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
    access_gate::consume(nft, &gate_b, b"00000001", s.ctx()); // NFT belongs to gate A -> abort E_WRONG_GATE
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
    access_gate::airdrop(&cap, &gate, BUYER, s.ctx());
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

    access_gate::set_price(&cap, &mut gate, 250);
    access_gate::set_default_uses(&cap, &mut gate, 5);
    access_gate::set_soulbound(&cap, &mut gate, true);
    access_gate::set_auto_burn_at_zero(&cap, &mut gate, true);
    access_gate::set_payment_recipient(&cap, &mut gate, BUYER);

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

    access_gate::make_gate_immutable(cap, &mut gate, s.ctx()); // consumes cap
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
    new_gate(&mut s, 100, 0, false, false);
    s.next_tx(CREATOR);
    let cap = s.take_from_sender<AdminCap>();
    let mut gate = s.take_shared<Gate>();
    let cap2 = access_gate::new_admin_cap_for_testing(&gate, s.ctx());
    access_gate::make_gate_immutable(cap, &mut gate, s.ctx());
    access_gate::set_price(&cap2, &mut gate, 1); // gate frozen -> abort E_GATE_FROZEN
    access_gate::burn_admin_cap_for_testing(cap2);
    ts::return_shared(gate);
    s.end();
}

// ── Commission split (C.1) ─────────────────────────────────────────────────────

#[test]
fun test_purchase_nonzero_commission_splits_payment() {
    let mut s = ts::begin(CREATOR);
    // 2.5% commission to TREASURY; gate price 1000 → commission 25, operator share 975.
    access_gate::share_platform_config_for_testing(TREASURY, 250, s.ctx());
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
    access_gate::share_platform_config_for_testing(TREASURY, 0, s.ctx());
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
    access_gate::share_platform_config_for_testing(TREASURY, 0, s.ctx());
    let cap = access_gate::new_platform_admin_cap_for_testing(s.ctx());
    s.next_tx(CREATOR);

    let mut platform = s.take_shared<PlatformConfig>();
    access_gate::set_commission_bps(&cap, &mut platform, 1001); // > cap → abort
    ts::return_shared(platform);
    access_gate::burn_platform_admin_cap_for_testing(cap);
    s.end();
}
