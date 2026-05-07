#[test_only]
module account_protocol::executable_resources_security_tests;

use account_protocol::config;
use account_protocol::executable;
use account_protocol::executable_resources;
use account_protocol::intents;
use account_protocol::package_registry::{Self as package_registry, PackageRegistry};
use sui::clock;
use sui::coin;
use sui::sui::SUI;
use sui::test_scenario as ts;
use sui::test_utils::destroy;
use sui::tx_context::TxContext;

const OWNER: address = @0xCAFE;

public struct DummyIntent() has drop;
public struct Outcome has copy, drop, store {}

// Current-action marker for the success-path test.
public struct DummyActionType has drop {}

// The witness type required for action-authorized access to `executable_resources`.
public struct ExecutionProgressWitness has drop {}

fun new_registry(ctx: &mut TxContext): PackageRegistry {
    let mut registry = package_registry::new_for_testing(ctx);
    package_registry::add_for_testing(
        &mut registry,
        b"AccountProtocol".to_string(),
        @account_protocol,
        1,
    );
    registry
}

#[test]
fun test_take_coin_with_correct_action_witness_succeeds() {
    let mut scenario = ts::begin(OWNER);
    let clock = clock::create_for_testing(scenario.ctx());

    let params = intents::new_params(
        b"one".to_string(),
        b"".to_string(),
        vector[0],
        1,
        &clock,
        scenario.ctx(),
    );

    let mut intent = intents::new_intent(
        params,
        Outcome {},
        @0xACC,
        DummyIntent(),
        scenario.ctx(),
    );

    // Set the current action type to this test module so `ExecutionProgressWitness {}` is valid.
    intent.add_typed_action(DummyActionType {}, vector[], DummyIntent());

    let mut exec = executable::new(intents::finish_pending(intent), scenario.ctx());
    let registry = new_registry(scenario.ctx());

    let coin_in = coin::mint_for_testing<SUI>(42, scenario.ctx());
    executable_resources::provide_coin_for_testing<SUI, Outcome>(
        &mut exec,
        b"c".to_string(),
        coin_in,
        scenario.ctx(),
    );

    let coin_out: coin::Coin<SUI> = executable_resources::take_coin(
        &mut exec,
        &registry,
        ExecutionProgressWitness {},
        b"c".to_string(),
    );
    assert!(coin::value(&coin_out) == 42, 0);
    coin::burn_for_testing(coin_out);

    exec.increment_action_idx<_, DummyActionType, _>(&registry, ExecutionProgressWitness {});
    let intent = exec.destroy_complete();

    destroy(intent);
    destroy(registry);
    destroy(clock);
    scenario.end();
}

#[test, expected_failure(abort_code = 2)]
fun test_take_coin_wrong_witness_aborts() {
    let mut scenario = ts::begin(OWNER);
    let clock = clock::create_for_testing(scenario.ctx());

    let params = intents::new_params(
        b"one".to_string(),
        b"".to_string(),
        vector[0],
        1,
        &clock,
        scenario.ctx(),
    );

    let mut intent = intents::new_intent(
        params,
        Outcome {},
        @0xACC,
        DummyIntent(),
        scenario.ctx(),
    );

    // Current action is in `account_protocol::config`, so our witness below is unauthorized.
    intent.add_typed_action(config::config_add_dep(), vector[], DummyIntent());

    let mut exec = executable::new(intents::finish_pending(intent), scenario.ctx());
    let registry = new_registry(scenario.ctx());

    let coin_in = coin::mint_for_testing<SUI>(1, scenario.ctx());
    executable_resources::provide_coin_for_testing<SUI, Outcome>(
        &mut exec,
        b"c".to_string(),
        coin_in,
        scenario.ctx(),
    );

    // Simulate a malicious PTB step trying to steal from the scratch bag.
    let stolen: coin::Coin<SUI> = executable_resources::take_coin(
        &mut exec,
        &registry,
        ExecutionProgressWitness {},
        b"c".to_string(),
    );

    // Unreachable when the witness-gating is correct, but required to satisfy the type system.
    coin::burn_for_testing(stolen);
    destroy(exec);
    destroy(registry);
    destroy(clock);
    scenario.end();
}
