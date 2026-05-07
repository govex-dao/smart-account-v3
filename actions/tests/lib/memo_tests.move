#[test_only]
module account_actions::memo_tests;

use account_actions::memo;
use account_actions::actions_version as version;
use account_protocol::account::{Self, Account};
use account_protocol::metadata;
use account_protocol::deps;
use account_protocol::intent_interface;
use account_protocol::intents;
use account_protocol::package_registry::{
    Self as package_registry,
    PackageRegistry,
    PackageAdminCap
};
use sui::bcs;
use sui::clock::{Self, Clock};
use sui::test_scenario::{Self as ts, Scenario};
use sui::test_utils::destroy;

// === Macros ===

use fun intent_interface::build_intent as Account.build_intent;

// === Constants ===

const OWNER: address = @0xCAFE;

// === Structs ===

public struct Witness() has drop;
public struct Config has copy, drop, store {}
public struct Outcome has copy, drop, store {}

// Intent witness for testing
public struct MemoIntent() has copy, drop;

// === Helpers ===

fun start(): (Scenario, PackageRegistry, Account, Clock) {
    let mut scenario = ts::begin(OWNER);
    // publish package
    package_registry::init_for_testing(scenario.ctx());
    // retrieve objects
    scenario.next_tx(OWNER);
    let mut extensions = scenario.take_shared<PackageRegistry>();
    let cap = scenario.take_from_sender<PackageAdminCap>();
    // Register AccountActions package - uses the address from Move.toml
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
    // create world
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
fun test_emit_memo_basic() {
    let (mut scenario, extensions, mut account, clock) = start();
    let key = b"test_memo".to_string();

    // Create an intent with a memo action
    let outcome = Outcome {};
    let params = intents::new_params(
        key,
        b"Test memo".to_string(),
        vector[0],
        1000,
        &clock,
        scenario.ctx(),
    );

    account.build_intent!(
        &extensions,
        params,
        outcome,
        version::current(),
        MemoIntent(),
        scenario.ctx(),
        |intent, iw| {
            // action_data format: memo (String as bytes)
            let memo_text = b"Hello from the DAO!";
            let action_data = bcs::to_bytes(&memo_text);
            intents::add_typed_action(intent, memo::memo(), action_data, iw);
        },
    );

    // Create executable
    let (_, mut executable) = account.create_executable<Config, Outcome, Witness>(
        &extensions,
        key,
        &clock,
        Witness(),
        scenario.ctx(),
    );

    // Execute the memo - this emits an event
    memo::do_emit_memo<Config, Outcome, MemoIntent>(
        &mut executable,
        &mut account,
        &extensions,
        MemoIntent(),
        &clock,
        scenario.ctx(),
    );

    account.confirm_execution(executable);

    end(scenario, extensions, account, clock);
}

#[test]
fun test_emit_memo_long_text() {
    let (mut scenario, extensions, mut account, clock) = start();
    let key = b"test_long_memo".to_string();

    // Create a longer memo
    let outcome = Outcome {};
    let params = intents::new_params(
        key,
        b"Test long memo".to_string(),
        vector[0],
        1000,
        &clock,
        scenario.ctx(),
    );

    account.build_intent!(
        &extensions,
        params,
        outcome,
        version::current(),
        MemoIntent(),
        scenario.ctx(),
        |intent, iw| {
            // Longer memo text
            let memo_text =
                b"This is a longer memo that contains multiple sentences. It describes a proposal decision or important DAO communication. The memo can contain detailed reasoning for governance decisions.";
            let action_data = bcs::to_bytes(&memo_text);
            intents::add_typed_action(intent, memo::memo(), action_data, iw);
        },
    );

    let (_, mut executable) = account.create_executable<Config, Outcome, Witness>(
        &extensions,
        key,
        &clock,
        Witness(),
        scenario.ctx(),
    );

    memo::do_emit_memo<Config, Outcome, MemoIntent>(
        &mut executable,
        &mut account,
        &extensions,
        MemoIntent(),
        &clock,
        scenario.ctx(),
    );

    account.confirm_execution(executable);

    end(scenario, extensions, account, clock);
}

#[test]
#[expected_failure(abort_code = memo::EEmptyMemo)]
fun test_empty_memo_fails() {
    let (mut scenario, extensions, mut account, clock) = start();
    let key = b"test_empty_memo".to_string();

    let outcome = Outcome {};
    let params = intents::new_params(
        key,
        b"Test empty memo".to_string(),
        vector[0],
        1000,
        &clock,
        scenario.ctx(),
    );

    account.build_intent!(
        &extensions,
        params,
        outcome,
        version::current(),
        MemoIntent(),
        scenario.ctx(),
        |intent, iw| {
            // Empty memo
            let memo_text = b"";
            let action_data = bcs::to_bytes(&memo_text);
            intents::add_typed_action(intent, memo::memo(), action_data, iw);
        },
    );

    let (_, mut executable) = account.create_executable<Config, Outcome, Witness>(
        &extensions,
        key,
        &clock,
        Witness(),
        scenario.ctx(),
    );

    // This should fail with EEmptyMemo
    memo::do_emit_memo<Config, Outcome, MemoIntent>(
        &mut executable,
        &mut account,
        &extensions,
        MemoIntent(),
        &clock,
        scenario.ctx(),
    );

    account.confirm_execution(executable);
    end(scenario, extensions, account, clock);
}

#[test]
fun test_multiple_memos_in_intent() {
    let (mut scenario, extensions, mut account, clock) = start();
    let key = b"test_multi_memo".to_string();

    let outcome = Outcome {};
    let params = intents::new_params(
        key,
        b"Test multiple memos".to_string(),
        vector[0],
        1000,
        &clock,
        scenario.ctx(),
    );

    account.build_intent!(
        &extensions,
        params,
        outcome,
        version::current(),
        MemoIntent(),
        scenario.ctx(),
        |intent, iw| {
            // First memo
            let memo1 = b"First memo: Proposal accepted";
            let action_data1 = bcs::to_bytes(&memo1);
            intents::add_typed_action(intent, memo::memo(), action_data1, iw);

            // Second memo
            let memo2 = b"Second memo: Implementation details";
            let action_data2 = bcs::to_bytes(&memo2);
            intents::add_typed_action(intent, memo::memo(), action_data2, iw);

            // Third memo
            let memo3 = b"Third memo: Timeline confirmed";
            let action_data3 = bcs::to_bytes(&memo3);
            intents::add_typed_action(intent, memo::memo(), action_data3, iw);
        },
    );

    let (_, mut executable) = account.create_executable<Config, Outcome, Witness>(
        &extensions,
        key,
        &clock,
        Witness(),
        scenario.ctx(),
    );

    // Execute all three memos
    memo::do_emit_memo<Config, Outcome, MemoIntent>(
        &mut executable,
        &mut account,
        &extensions,
        MemoIntent(),
        &clock,
        scenario.ctx(),
    );
    memo::do_emit_memo<Config, Outcome, MemoIntent>(
        &mut executable,
        &mut account,
        &extensions,
        MemoIntent(),
        &clock,
        scenario.ctx(),
    );
    memo::do_emit_memo<Config, Outcome, MemoIntent>(
        &mut executable,
        &mut account,
        &extensions,
        MemoIntent(),
        &clock,
        scenario.ctx(),
    );

    account.confirm_execution(executable);

    end(scenario, extensions, account, clock);
}

#[test]
fun test_delete_memo_action() {
    let (mut scenario, extensions, mut account, clock) = start();
    let key = b"test_delete_memo".to_string();

    let outcome = Outcome {};
    let params = intents::new_params(
        key,
        b"Test delete memo".to_string(),
        vector[0],
        clock.timestamp_ms() + 1000,
        &clock,
        scenario.ctx(),
    );

    account.build_intent!(
        &extensions,
        params,
        outcome,
        version::current(),
        MemoIntent(),
        scenario.ctx(),
        |intent, iw| {
            let memo_text = b"Memo to be executed then deleted";
            let action_data = bcs::to_bytes(&memo_text);
            intents::add_typed_action(intent, memo::memo(), action_data, iw);
        },
    );

    // Execute the intent
    let (_, mut executable) = account.create_executable<Config, Outcome, Witness>(
        &extensions,
        key,
        &clock,
        Witness(),
        scenario.ctx(),
    );

    memo::do_emit_memo<Config, Outcome, MemoIntent>(
        &mut executable,
        &mut account,
        &extensions,
        MemoIntent(),
        &clock,
        scenario.ctx(),
    );
    account.confirm_execution(executable);

    // Now destroy the empty intent
    destroy(account.destroy_empty_intent<Outcome, Witness>(key, Witness(), scenario.ctx()));

    end(scenario, extensions, account, clock);
}
