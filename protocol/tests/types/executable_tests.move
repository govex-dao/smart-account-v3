#[test_only]
module account_protocol::executable_tests;

public struct ExecutionProgressWitness has drop {}


use account_protocol::deps;
use account_protocol::executable;
use account_protocol::intents;
use account_protocol::package_registry::{Self as package_registry, PackageRegistry};
use account_protocol::version_witness;
use sui::bcs;
use sui::clock;
use sui::test_scenario as ts;
use sui::test_utils::destroy;
use sui::tx_context::TxContext;

// === Imports ===

// === Constants ===

const OWNER: address = @0xCAFE;
const ACCOUNT_ID_ADDR: address = @0xACC;
const ACCOUNT_DEP_ADDR: address = @0x2222;

// === Structs ===

public struct DummyIntent() has drop;
public struct WrongIntent() has drop;

public struct Outcome has copy, drop, store {}
public struct Action has drop, store {}
public struct ActionType has drop {}

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

fun test_account_id(): sui::object::ID {
    sui::object::id_from_address(ACCOUNT_ID_ADDR)
}

fun account_deps_with_custom_dep(
    registry: &PackageRegistry,
    ctx: &mut TxContext,
): sui::table::Table<address, deps::DepInfo> {
    let aid = test_account_id();
    let whitelist_deps = deps::new_for_testing_with_level(
        registry,
        deps::auth_level_whitelist(),
        aid,
    );
    let mut account_deps = deps::new_account_deps_table(ctx);
    let mut dep_names = deps::new_dep_names_map();
    deps::add_dep(
        &whitelist_deps,
        &mut account_deps,
        &mut dep_names,
        registry,
        ACCOUNT_DEP_ADDR,
        b"AccountPkg".to_string(),
        1,
        aid,
    );
    account_deps
}

// === Tests ===

#[test]
fun test_executable_flow() {
    let mut scenario = ts::begin(OWNER);
    let clock = clock::create_for_testing(scenario.ctx());

    let params = intents::new_params(
        b"one".to_string(),
        b"".to_string(),
        vector[1],
        2,
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
    let action_data = bcs::to_bytes(&Action {});
    intent.add_typed_action(ActionType {}, action_data, DummyIntent());

    let mut executable = executable::new(intents::finish_pending(intent), scenario.ctx());
    let registry = new_registry(scenario.ctx());
    // verify initial state (pending action)
    assert!(executable.intent().key() == b"one".to_string());
    assert!(executable.action_idx() == 0);
    // first step: verify and increment action idx
    executable.increment_action_idx<_, ActionType, _>(&registry, ExecutionProgressWitness {});
    assert!(executable.action_idx() == 1);
    // second step: destroy executable after all actions are completed
    let intent = executable.destroy_complete();

    destroy(intent);
    destroy(registry);
    destroy(clock);
    ts::end(scenario);
}

#[test]
fun test_check_strict_whitelist_allows_account_dep() {
    let mut scenario = ts::begin(OWNER);
    let registry = package_registry::new_for_testing(scenario.ctx());
    let aid = test_account_id();
    let account_deps = account_deps_with_custom_dep(&registry, scenario.ctx());
    let deps = deps::new_for_testing_with_level(
        &registry,
        deps::auth_level_whitelist(),
        aid,
    );
    let witness = version_witness::new_for_testing(ACCOUNT_DEP_ADDR);
    deps::check_strict(&deps, witness, &registry, &account_deps, aid);

    destroy(registry);
    destroy(account_deps);
    ts::end(scenario);
}

#[test, expected_failure(abort_code = 2, location = account_protocol::deps)]
fun test_check_strict_global_only_rejects_account_dep() {
    let mut scenario = ts::begin(OWNER);
    let registry = package_registry::new_for_testing(scenario.ctx());
    let aid = test_account_id();
    let account_deps = account_deps_with_custom_dep(&registry, scenario.ctx());
    let deps = deps::new_for_testing_with_level(
        &registry,
        deps::auth_level_global_only(),
        aid,
    );
    let witness = version_witness::new_for_testing(ACCOUNT_DEP_ADDR);
    deps::check_strict(&deps, witness, &registry, &account_deps, aid);

    destroy(registry);
    destroy(account_deps);
    ts::end(scenario);
}
