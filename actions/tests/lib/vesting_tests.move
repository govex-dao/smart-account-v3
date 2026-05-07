#[test_only]
module account_actions::vesting_tests;

use account_actions::vesting::{Self, Vesting, VestingCap};
use account_protocol::account::{Self, Account};
use account_protocol::metadata;
use account_protocol::deps;
use account_protocol::package_registry::{
    Self as package_registry,
    PackageRegistry,
    PackageAdminCap
};
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::sui::SUI;
use sui::test_scenario::{Self as ts, Scenario};
use sui::test_utils::destroy;
use sui::vec_map;

// === Constants ===

const OWNER: address = @0xCAFE;
const BENEFICIARY: address = @0xBEEF;

// === Structs ===

public struct Witness() has drop;
public struct Config has copy, drop, store {}

// === Helpers ===

fun start(): (Scenario, PackageRegistry, Account, Clock) {
    let mut scenario = ts::begin(OWNER);
    // publish package
    package_registry::init_for_testing(scenario.ctx());
    // retrieve objects
    scenario.next_tx(OWNER);
    let mut extensions = scenario.take_shared<PackageRegistry>();
    let cap = scenario.take_from_sender<PackageAdminCap>();
    // Register AccountActions package
    package_registry::add_for_testing(
        &mut extensions,
        b"AccountActions".to_string(),
        @account_actions,
        1,
    );

    let deps = deps::new_for_testing(&extensions, object::id_from_address(@0x0));
    let account = account::new(
        Config {},
        metadata::empty(),
        deps,
        Witness(),
        scenario.ctx(),
    );
    let clock = clock::create_for_testing(scenario.ctx());
    destroy(cap);
    (scenario, extensions, account, clock)
}

fun end(scenario: Scenario, extensions: PackageRegistry, account: Account, clock: Clock) {
    destroy(extensions);
    destroy(account);
    destroy(clock);
    ts::end(scenario);
}

// === Tests ===

#[test]
fun test_create_vesting_and_claim() {
    let (mut scenario, extensions, mut account, mut clock) = start();

    // Create vesting: 100 tokens per iteration, 10 iterations = 1000 total
    let coin = coin::mint_for_testing<SUI>(1000, scenario.ctx());
    let (mut vesting, cap) = vesting::create_vesting_for_testing<SUI>(
        coin,
        account.addr(),
        100, // amount_per_iteration
        clock.timestamp_ms(), // start_time (now)
        10, // iterations_total
        10_000, // iteration_period_ms (10 seconds)
        true, // is_cancellable
        scenario.ctx(),
    );

    // Verify initial state
    assert!(vesting::balance_value(&vesting) == 1000, 0);
    assert!(vesting::vesting_is_cancellable(&vesting), 2);
    assert!(vesting::total_amount(&vesting) == 1000, 3);

    // At time 0, nothing is claimable yet (haven't completed first iteration)
    let claimable = vesting::calculate_claimable(&vesting, &clock);
    assert!(claimable == 0, 4);

    // Advance time by 1 iteration period
    clock.increment_for_testing(10_000);

    // Now 1 iteration has completed, 100 tokens claimable
    let claimable = vesting::calculate_claimable(&vesting, &clock);
    assert!(claimable == 100, 5);

    // Claim as beneficiary (with cap)
    scenario.next_tx(BENEFICIARY);
    let claimed_coin = vesting::claim<SUI>(
        &mut vesting,
        &cap,
        100,
        &clock,
        scenario.ctx(),
    );
    assert!(claimed_coin.value() == 100, 6);

    // Verify claimed amount updated
    assert!(vesting::vesting_claimed_amount(&vesting) == 100, 7);
    assert!(vesting::balance_value(&vesting) == 900, 8);

    // Clean up
    destroy(claimed_coin);
    destroy(vesting);
    destroy(cap);
    end(scenario, extensions, account, clock);
}

#[test]
fun test_vesting_full_claim() {
    let (mut scenario, extensions, mut account, mut clock) = start();

    // Create vesting: 200 tokens per iteration, 5 iterations = 1000 total
    let coin = coin::mint_for_testing<SUI>(1000, scenario.ctx());
    let (mut vesting, cap) = vesting::create_vesting_for_testing<SUI>(
        coin,
        account.addr(),
        200,
        clock.timestamp_ms(),
        5,
        20_000, // 20 second iterations
        false, // not cancellable
        scenario.ctx(),
    );

    // Advance past all iterations
    clock.increment_for_testing(100_000); // 100 seconds > 5 * 20 seconds

    // All 1000 tokens should be claimable
    let claimable = vesting::calculate_claimable(&vesting, &clock);
    assert!(claimable == 1000, 0);

    // Claim all
    scenario.next_tx(BENEFICIARY);
    let claimed = vesting::claim<SUI>(
        &mut vesting,
        &cap,
        1000,
        &clock,
        scenario.ctx(),
    );
    assert!(claimed.value() == 1000, 1);

    // Vesting should now be empty and destroyable
    assert!(vesting::balance_value(&vesting) == 0, 2);

    destroy(claimed);
    vesting::destroy_empty(vesting, cap, &mut account, &extensions);
    end(scenario, extensions, account, clock);
}

#[test]
fun test_vesting_partial_claims() {
    let (mut scenario, extensions, account, mut clock) = start();

    // Create vesting
    let coin = coin::mint_for_testing<SUI>(1000, scenario.ctx());
    let (mut vesting, cap) = vesting::create_vesting_for_testing<SUI>(
        coin,
        account.addr(),
        100,
        clock.timestamp_ms(),
        10,
        10_000,
        true,
        scenario.ctx(),
    );

    // Advance 3 iterations
    clock.increment_for_testing(30_000);

    // 300 claimable
    let claimable = vesting::calculate_claimable(&vesting, &clock);
    assert!(claimable == 300, 0);

    // Claim only 150
    scenario.next_tx(BENEFICIARY);
    let claimed1 = vesting::claim<SUI>(
        &mut vesting,
        &cap,
        150,
        &clock,
        scenario.ctx(),
    );
    assert!(claimed1.value() == 150, 1);

    // 150 still claimable from first 3 iterations
    let claimable_after = vesting::calculate_claimable(&vesting, &clock);
    assert!(claimable_after == 150, 2);

    // Claim the remaining 150
    let claimed2 = vesting::claim<SUI>(
        &mut vesting,
        &cap,
        150,
        &clock,
        scenario.ctx(),
    );
    assert!(claimed2.value() == 150, 3);

    // Now 0 claimable until next iteration
    let claimable_final = vesting::calculate_claimable(&vesting, &clock);
    assert!(claimable_final == 0, 4);

    destroy(claimed1);
    destroy(claimed2);
    destroy(vesting);
    destroy(cap);
    end(scenario, extensions, account, clock);
}

#[test]
#[expected_failure(abort_code = vesting::ETooEarly)]
fun test_claim_before_start_fails() {
    let (mut scenario, extensions, account, clock) = start();

    // Create vesting that starts in the future
    let coin = coin::mint_for_testing<SUI>(1000, scenario.ctx());
    let (mut vesting, cap) = vesting::create_vesting_for_testing<SUI>(
        coin,
        account.addr(),
        100,
        clock.timestamp_ms() + 10_000, // starts in 10 seconds
        10,
        10_000,
        true,
        scenario.ctx(),
    );

    // Try to claim before start - should fail
    scenario.next_tx(BENEFICIARY);
    let claimed = vesting::claim<SUI>(
        &mut vesting,
        &cap,
        100,
        &clock,
        scenario.ctx(),
    );

    destroy(claimed);
    destroy(vesting);
    destroy(cap);
    end(scenario, extensions, account, clock);
}

#[test]
#[expected_failure(abort_code = vesting::EInsufficientVestedAmount)]
fun test_claim_more_than_vested_fails() {
    let (mut scenario, extensions, account, mut clock) = start();

    let coin = coin::mint_for_testing<SUI>(1000, scenario.ctx());
    let (mut vesting, cap) = vesting::create_vesting_for_testing<SUI>(
        coin,
        account.addr(),
        100,
        clock.timestamp_ms(),
        10,
        10_000,
        true,
        scenario.ctx(),
    );

    // Advance 2 iterations - 200 claimable
    clock.increment_for_testing(20_000);

    // Try to claim 300 - should fail
    scenario.next_tx(BENEFICIARY);
    let claimed = vesting::claim<SUI>(
        &mut vesting,
        &cap,
        300,
        &clock,
        scenario.ctx(),
    );

    destroy(claimed);
    destroy(vesting);
    destroy(cap);
    end(scenario, extensions, account, clock);
}

#[test]
#[expected_failure(abort_code = vesting::EVestingCapMismatch)]
fun test_claim_with_wrong_cap_fails() {
    let (mut scenario, extensions, account, mut clock) = start();

    // Create two vestings
    let coin1 = coin::mint_for_testing<SUI>(1000, scenario.ctx());
    let (mut vesting1, _cap1) = vesting::create_vesting_for_testing<SUI>(
        coin1,
        account.addr(),
        100,
        clock.timestamp_ms(),
        10,
        10_000,
        true,
        scenario.ctx(),
    );

    let coin2 = coin::mint_for_testing<SUI>(500, scenario.ctx());
    let (_vesting2, cap2) = vesting::create_vesting_for_testing<SUI>(
        coin2,
        account.addr(),
        50,
        clock.timestamp_ms(),
        10,
        10_000,
        true,
        scenario.ctx(),
    );

    // Advance time
    clock.increment_for_testing(10_000);

    // Try to claim from vesting1 using cap2 — should fail
    scenario.next_tx(BENEFICIARY);
    let claimed = vesting::claim<SUI>(
        &mut vesting1,
        &cap2,
        100,
        &clock,
        scenario.ctx(),
    );

    destroy(claimed);
    destroy(vesting1);
    destroy(_vesting2);
    destroy(_cap1);
    destroy(cap2);
    end(scenario, extensions, account, clock);
}

#[test]
fun test_vesting_view_functions() {
    let (mut scenario, extensions, account, clock) = start();

    let coin = coin::mint_for_testing<SUI>(1000, scenario.ctx());
    let (vesting, cap) = vesting::create_vesting_for_testing<SUI>(
        coin,
        account.addr(),
        100,
        1000, // start_time
        10, // iterations_total
        10_000, // iteration_period_ms
        true, // is_cancellable
        scenario.ctx(),
    );

    // Test view functions
    assert!(vesting::vesting_dao(&vesting) == account.addr(), 0);
    assert!(vesting::vesting_amount_per_iteration(&vesting) == 100, 2);
    assert!(vesting::vesting_iterations_total(&vesting) == 10, 3);
    assert!(vesting::vesting_iteration_period_ms(&vesting) == 10_000, 4);
    assert!(vesting::vesting_start_time(&vesting) == 1000, 5);
    assert!(vesting::vesting_is_cancellable(&vesting), 6);
    assert!(vesting::vesting_claimed_amount(&vesting) == 0, 7);

    // Test cap accessors
    assert!(vesting::vesting_cap_vesting_id(&cap) == object::id(&vesting), 11);
    assert!(vesting::vesting_cap_dao_address(&cap) == account.addr(), 12);

    destroy(vesting);
    destroy(cap);
    end(scenario, extensions, account, clock);
}

#[test]
fun test_next_vest_time() {
    let (mut scenario, extensions, account, mut clock) = start();

    let start_time = clock.timestamp_ms() + 5000; // 5 seconds in future
    let coin = coin::mint_for_testing<SUI>(1000, scenario.ctx());
    let (vesting, cap) = vesting::create_vesting_for_testing<SUI>(
        coin,
        account.addr(),
        100,
        start_time,
        10,
        10_000,
        true,
        scenario.ctx(),
    );

    // Before start, next vest time is start_time + iteration_period (first actual unlock)
    let next = vesting::next_vest_time(&vesting, &clock);
    assert!(next.is_some(), 0);
    assert!(*next.borrow() == start_time + 10_000, 1);

    // Advance past start
    clock.increment_for_testing(5000);

    // Next vest time is start_time + iteration_period
    let next = vesting::next_vest_time(&vesting, &clock);
    assert!(next.is_some(), 2);
    assert!(*next.borrow() == start_time + 10_000, 3);

    // Advance past all iterations
    clock.increment_for_testing(100_000);

    // No more vest times
    let next = vesting::next_vest_time(&vesting, &clock);
    assert!(next.is_none(), 4);
    destroy(vesting);
    destroy(cap);
    end(scenario, extensions, account, clock);
}

#[test]
fun test_vesting_not_cancellable() {
    let (mut scenario, extensions, account, clock) = start();

    // Create non-cancellable vesting
    let coin = coin::mint_for_testing<SUI>(1000, scenario.ctx());
    let (vesting, cap) = vesting::create_vesting_for_testing<SUI>(
        coin,
        account.addr(),
        100,
        clock.timestamp_ms(),
        10,
        10_000,
        false, // NOT cancellable - GUARANTEED to recipient
        scenario.ctx(),
    );

    // Verify not cancellable
    assert!(!vesting::vesting_is_cancellable(&vesting), 0);
    destroy(vesting);
    destroy(cap);
    end(scenario, extensions, account, clock);
}

#[test]
fun test_destroy_empty_with_cap() {
    let (mut scenario, extensions, mut account, mut clock) = start();

    let coin = coin::mint_for_testing<SUI>(1000, scenario.ctx());
    let (mut vesting, cap) = vesting::create_vesting_for_testing<SUI>(
        coin,
        account.addr(),
        1000, // all in one iteration
        clock.timestamp_ms(),
        1,
        10_000,
        true,
        scenario.ctx(),
    );

    // Claim everything
    clock.increment_for_testing(10_000);
    scenario.next_tx(BENEFICIARY);
    let claimed = vesting::claim<SUI>(&mut vesting, &cap, 1000, &clock, scenario.ctx());
    destroy(claimed);

    // Destroy both
    vesting::destroy_empty(vesting, cap, &mut account, &extensions);
    end(scenario, extensions, account, clock);
}

// === Registry Tests ===

#[test]
fun test_registry_insert_and_read() {
    let (mut scenario, extensions, mut account, clock) = start();

    // No registry initially
    assert!(!vesting::has_vesting_registry(&account), 0);

    // Create a vesting and register it
    let coin = coin::mint_for_testing<SUI>(1000, scenario.ctx());
    let (vesting, cap) = vesting::create_vesting_for_testing<SUI>(
        coin,
        account.addr(),
        100,
        clock.timestamp_ms(),
        10,
        10_000,
        true,
        scenario.ctx(),
    );
    let vesting_id = object::id(&vesting);

    vesting::add_registry_entry_for_testing<SUI>(
        &mut account,
        &extensions,
        vesting_id,
        true,
    );

    // Registry now exists with 1 entry
    assert!(vesting::has_vesting_registry(&account), 1);
    let entries = vesting::vesting_registry_entries(&account, &extensions);
    assert!(vec_map::size(entries) == 1, 2);
    assert!(vec_map::contains(entries, &vesting_id), 3);

    // Check entry fields
    let entry = vec_map::get(entries, &vesting_id);
    assert!(vesting::vesting_entry_is_cancellable(entry) == true, 4);

    destroy(vesting);
    destroy(cap);
    end(scenario, extensions, account, clock);
}

#[test]
fun test_registry_multiple_entries() {
    let (mut scenario, extensions, mut account, clock) = start();

    let coin1 = coin::mint_for_testing<SUI>(1000, scenario.ctx());
    let (vesting1, cap1) = vesting::create_vesting_for_testing<SUI>(
        coin1,
        account.addr(),
        100,
        clock.timestamp_ms(),
        10,
        10_000,
        true,
        scenario.ctx(),
    );
    let id1 = object::id(&vesting1);

    let coin2 = coin::mint_for_testing<SUI>(500, scenario.ctx());
    let (vesting2, cap2) = vesting::create_vesting_for_testing<SUI>(
        coin2,
        account.addr(),
        50,
        clock.timestamp_ms(),
        10,
        10_000,
        false,
        scenario.ctx(),
    );
    let id2 = object::id(&vesting2);

    vesting::add_registry_entry_for_testing<SUI>(&mut account, &extensions, id1, true);
    vesting::add_registry_entry_for_testing<SUI>(&mut account, &extensions, id2, false);

    let entries = vesting::vesting_registry_entries(&account, &extensions);
    assert!(vec_map::size(entries) == 2, 0);
    assert!(vec_map::contains(entries, &id1), 1);
    assert!(vec_map::contains(entries, &id2), 2);

    // Verify different is_cancellable flags
    assert!(vesting::vesting_entry_is_cancellable(vec_map::get(entries, &id1)) == true, 3);
    assert!(vesting::vesting_entry_is_cancellable(vec_map::get(entries, &id2)) == false, 4);

    destroy(vesting1);
    destroy(vesting2);
    destroy(cap1);
    destroy(cap2);
    end(scenario, extensions, account, clock);
}

#[test]
fun test_destroy_empty_cleans_registry_entry() {
    let (mut scenario, extensions, mut account, mut clock) = start();

    let coin = coin::mint_for_testing<SUI>(1000, scenario.ctx());
    let (mut vesting, cap) = vesting::create_vesting_for_testing<SUI>(
        coin,
        account.addr(),
        1000,
        clock.timestamp_ms(),
        1,
        10_000,
        true,
        scenario.ctx(),
    );
    let vesting_id = object::id(&vesting);

    // Add registry entry
    vesting::add_registry_entry_for_testing<SUI>(&mut account, &extensions, vesting_id, true);
    let entries = vesting::vesting_registry_entries(&account, &extensions);
    assert!(vec_map::size(entries) == 1, 0);

    // Claim all and destroy
    clock.increment_for_testing(10_000);
    scenario.next_tx(BENEFICIARY);
    let claimed = vesting::claim<SUI>(&mut vesting, &cap, 1000, &clock, scenario.ctx());
    destroy(claimed);
    vesting::destroy_empty(vesting, cap, &mut account, &extensions);

    // Registry entry should be removed
    let entries = vesting::vesting_registry_entries(&account, &extensions);
    assert!(vec_map::size(entries) == 0, 1);

    end(scenario, extensions, account, clock);
}

#[test]
#[expected_failure(abort_code = vesting::EVestingStillActive, location = account_actions::vesting)]
fun test_destroy_vesting_cap_rejects_registered_active_vesting() {
    let (mut scenario, extensions, mut account, clock) = start();

    let coin = coin::mint_for_testing<SUI>(1000, scenario.ctx());
    let (vesting, cap) = vesting::create_vesting_for_testing<SUI>(
        coin,
        account.addr(),
        100,
        clock.timestamp_ms(),
        10,
        10_000,
        false,
        scenario.ctx(),
    );
    let vesting_id = object::id(&vesting);
    vesting::add_registry_entry_for_testing<SUI>(&mut account, &extensions, vesting_id, false);

    vesting::destroy_vesting_cap(cap, &account, &extensions);

    destroy(vesting);
    end(scenario, extensions, account, clock);
}

#[test]
#[expected_failure(abort_code = vesting::EVestingRegistryMissing, location = account_actions::vesting)]
fun test_destroy_vesting_cap_rejects_missing_registry() {
    let (mut scenario, extensions, account, clock) = start();

    let coin = coin::mint_for_testing<SUI>(1000, scenario.ctx());
    let (_vesting, cap) = vesting::create_vesting_for_testing<SUI>(
        coin,
        account.addr(),
        100,
        clock.timestamp_ms(),
        10,
        10_000,
        false,
        scenario.ctx(),
    );

    vesting::destroy_vesting_cap(cap, &account, &extensions);

    destroy(_vesting);
    end(scenario, extensions, account, clock);
}

#[test]
fun test_destroy_vesting_cap_after_registry_cleanup() {
    let (mut scenario, extensions, mut account, mut clock) = start();

    let coin = coin::mint_for_testing<SUI>(1000, scenario.ctx());
    let (mut vesting, cap) = vesting::create_vesting_for_testing<SUI>(
        coin,
        account.addr(),
        1000,
        clock.timestamp_ms(),
        1,
        10_000,
        false,
        scenario.ctx(),
    );
    let vesting_id = object::id(&vesting);
    vesting::add_registry_entry_for_testing<SUI>(&mut account, &extensions, vesting_id, false);

    clock.increment_for_testing(10_000);
    scenario.next_tx(BENEFICIARY);
    let claimed = vesting::claim<SUI>(&mut vesting, &cap, 1000, &clock, scenario.ctx());
    destroy(claimed);

    vesting::cleanup_depleted_vesting(&vesting, &mut account, &extensions);
    vesting::destroy_vesting_cap(cap, &account, &extensions);

    assert!(vec_map::size(vesting::vesting_registry_entries(&account, &extensions)) == 0, 0);
    destroy(vesting);
    end(scenario, extensions, account, clock);
}

#[test]
fun test_destroy_empty_frees_registry_slot() {
    let (mut scenario, extensions, mut account, mut clock) = start();

    // Fill registry to 100 with dummy entries
    let mut i = 0;
    while (i < 100) {
        let addr = sui::address::from_u256((i as u256));
        let fake_id = object::id_from_address(addr);
        vesting::add_registry_entry_for_testing<SUI>(&mut account, &extensions, fake_id, true);
        i = i + 1;
    };
    let entries = vesting::vesting_registry_entries(&account, &extensions);
    assert!(vec_map::size(entries) == 100, 0);

    // Create a real vesting and add it to registry (test helper bypasses cap)
    let coin = coin::mint_for_testing<SUI>(1000, scenario.ctx());
    let (mut vesting, cap) = vesting::create_vesting_for_testing<SUI>(
        coin,
        account.addr(),
        1000,
        clock.timestamp_ms(),
        1,
        10_000,
        true,
        scenario.ctx(),
    );
    let vesting_id = object::id(&vesting);
    vesting::add_registry_entry_for_testing<SUI>(&mut account, &extensions, vesting_id, true);
    assert!(vec_map::size(vesting::vesting_registry_entries(&account, &extensions)) == 101, 1);

    // Claim and destroy — entry should be removed, freeing a slot
    clock.increment_for_testing(10_000);
    scenario.next_tx(BENEFICIARY);
    let claimed = vesting::claim<SUI>(&mut vesting, &cap, 1000, &clock, scenario.ctx());
    destroy(claimed);
    vesting::destroy_empty(vesting, cap, &mut account, &extensions);

    assert!(vec_map::size(vesting::vesting_registry_entries(&account, &extensions)) == 100, 2);

    end(scenario, extensions, account, clock);
}

#[test]
#[expected_failure(abort_code = vesting::EVestingCapMismatch)]
fun test_destroy_empty_wrong_account_fails() {
    let (mut scenario, extensions, mut account, mut clock) = start();

    let coin = coin::mint_for_testing<SUI>(1000, scenario.ctx());
    let (mut vesting, cap) = vesting::create_vesting_for_testing<SUI>(
        coin,
        account.addr(),
        1000,
        clock.timestamp_ms(),
        1,
        10_000,
        true,
        scenario.ctx(),
    );

    // Claim all
    clock.increment_for_testing(10_000);
    scenario.next_tx(BENEFICIARY);
    let claimed = vesting::claim<SUI>(&mut vesting, &cap, 1000, &clock, scenario.ctx());
    destroy(claimed);

    // Create a different account
    let deps = deps::new_for_testing(&extensions, object::id_from_address(@0x0));
    let mut wrong_account = account::new(
        Config {},
        metadata::empty(),
        deps,
        Witness(),
        scenario.ctx(),
    );

    // Should fail — cap.dao_address doesn't match wrong_account
    vesting::destroy_empty(vesting, cap, &mut wrong_account, &extensions);

    destroy(wrong_account);
    end(scenario, extensions, account, clock);
}

// === VestingCap Tests ===

#[test]
fun test_cap_fields_match_vesting() {
    let (mut scenario, extensions, account, clock) = start();

    let coin = coin::mint_for_testing<SUI>(1000, scenario.ctx());
    let (vesting, cap) = vesting::create_vesting_for_testing<SUI>(
        coin,
        account.addr(),
        100,
        clock.timestamp_ms(),
        10,
        10_000,
        true,
        scenario.ctx(),
    );

    // Cap fields should match vesting
    assert!(vesting::vesting_cap_vesting_id(&cap) == object::id(&vesting), 0);
    assert!(vesting::vesting_cap_dao_address(&cap) == vesting::vesting_dao(&vesting), 1);
    assert!(vesting::vesting_cap_dao_address(&cap) == account.addr(), 2);

    destroy(vesting);
    destroy(cap);
    end(scenario, extensions, account, clock);
}

#[test]
#[expected_failure(abort_code = vesting::EVestingCapMismatch)]
fun test_cap_from_different_dao_fails() {
    let (mut scenario, extensions, account, mut clock) = start();

    // Create vesting for DAO account
    let coin = coin::mint_for_testing<SUI>(1000, scenario.ctx());
    let (mut vesting, _cap) = vesting::create_vesting_for_testing<SUI>(
        coin,
        account.addr(),
        100,
        clock.timestamp_ms(),
        10,
        10_000,
        true,
        scenario.ctx(),
    );

    // Create a cap with a DIFFERENT dao_address (simulating a different DAO)
    let coin2 = coin::mint_for_testing<SUI>(500, scenario.ctx());
    let (_vesting2, fake_cap) = vesting::create_vesting_for_testing<SUI>(
        coin2,
        @0xFA4E, // different DAO
        50,
        clock.timestamp_ms(),
        10,
        10_000,
        true,
        scenario.ctx(),
    );

    // Try to claim with cap from wrong DAO — should fail
    clock.increment_for_testing(10_000);
    scenario.next_tx(BENEFICIARY);
    let claimed = vesting::claim<SUI>(&mut vesting, &fake_cap, 100, &clock, scenario.ctx());

    destroy(claimed);
    destroy(vesting);
    destroy(_vesting2);
    destroy(_cap);
    destroy(fake_cap);
    end(scenario, extensions, account, clock);
}

#[test]
fun test_cap_holder_claims_after_transfer() {
    let (mut scenario, extensions, account, mut clock) = start();

    let new_holder = @0xDEAD;
    let coin = coin::mint_for_testing<SUI>(1000, scenario.ctx());
    let (mut vesting, cap) = vesting::create_vesting_for_testing<SUI>(
        coin,
        account.addr(),
        100,
        clock.timestamp_ms(),
        10,
        10_000,
        true,
        scenario.ctx(),
    );

    // Advance time so tokens vest
    clock.increment_for_testing(10_000);

    // Simulate cap transfer: new holder claims (anyone with the cap can claim)
    scenario.next_tx(new_holder);
    let claimed = vesting::claim<SUI>(&mut vesting, &cap, 100, &clock, scenario.ctx());
    assert!(claimed.value() == 100, 0);

    destroy(claimed);
    destroy(vesting);
    destroy(cap);
    end(scenario, extensions, account, clock);
}

#[test]
fun test_multiple_claims_with_same_cap() {
    let (mut scenario, extensions, account, mut clock) = start();

    let coin = coin::mint_for_testing<SUI>(1000, scenario.ctx());
    let (mut vesting, cap) = vesting::create_vesting_for_testing<SUI>(
        coin,
        account.addr(),
        100,
        clock.timestamp_ms(),
        10,
        10_000,
        true,
        scenario.ctx(),
    );

    // Advance 3 iterations
    clock.increment_for_testing(30_000);
    scenario.next_tx(BENEFICIARY);

    // Claim in 3 separate calls
    let c1 = vesting::claim<SUI>(&mut vesting, &cap, 100, &clock, scenario.ctx());
    let c2 = vesting::claim<SUI>(&mut vesting, &cap, 100, &clock, scenario.ctx());
    let c3 = vesting::claim<SUI>(&mut vesting, &cap, 100, &clock, scenario.ctx());

    assert!(c1.value() == 100, 0);
    assert!(c2.value() == 100, 1);
    assert!(c3.value() == 100, 2);
    assert!(vesting::vesting_claimed_amount(&vesting) == 300, 3);

    destroy(c1);
    destroy(c2);
    destroy(c3);
    destroy(vesting);
    destroy(cap);
    end(scenario, extensions, account, clock);
}

#[test]
fun test_full_lifecycle_create_claim_destroy() {
    let (mut scenario, extensions, mut account, mut clock) = start();

    // Create vesting: 500 per iteration, 2 iterations = 1000 total
    let coin = coin::mint_for_testing<SUI>(1000, scenario.ctx());
    let (mut vesting, cap) = vesting::create_vesting_for_testing<SUI>(
        coin,
        account.addr(),
        500,
        clock.timestamp_ms(),
        2,
        10_000,
        false, // not cancellable — GUARANTEED
        scenario.ctx(),
    );

    // Advance past all iterations
    clock.increment_for_testing(20_000);
    scenario.next_tx(BENEFICIARY);

    // Claim all
    let claimed = vesting::claim<SUI>(&mut vesting, &cap, 1000, &clock, scenario.ctx());
    assert!(claimed.value() == 1000, 0);
    assert!(vesting::balance_value(&vesting) == 0, 1);

    // Destroy both vesting and cap
    destroy(claimed);
    vesting::destroy_empty(vesting, cap, &mut account, &extensions);

    end(scenario, extensions, account, clock);
}

#[test]
#[expected_failure(abort_code = vesting::EBalanceNotEmpty)]
fun test_destroy_empty_with_balance_fails() {
    let (mut scenario, extensions, mut account, clock) = start();

    let coin = coin::mint_for_testing<SUI>(1000, scenario.ctx());
    let (vesting, cap) = vesting::create_vesting_for_testing<SUI>(
        coin,
        account.addr(),
        100,
        clock.timestamp_ms(),
        10,
        10_000,
        true,
        scenario.ctx(),
    );

    // Try to destroy with balance — should fail
    vesting::destroy_empty(vesting, cap, &mut account, &extensions);
    end(scenario, extensions, account, clock);
}
