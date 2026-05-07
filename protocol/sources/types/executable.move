// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

// Portions of this file are derived from the account.tech Move Framework project.
// Those portions remain licensed under the Apache License, Version 2.0.

/// Hot potato constructed from a resolved Intent. Cannot be stored, transferred, or dropped.
/// Enforces: sequential action processing via witness-validated index advancement,
/// completion requirement (destroy_complete asserts all actions executed),
/// account binding (intent carries account address), and resource bag management
/// (UID hosts dynamic fields for passing coins/objects between actions).
/// Only constructable/destroyable within this package (new/destroy_complete are package-private).

module account_protocol::executable;

use account_protocol::action_validation;
use account_protocol::intents::{Self, Intent};
use account_protocol::package_registry::{Self as package_registry, PackageRegistry};
use std::type_name::{Self, TypeName};
use sui::address;
use sui::hex;
use sui::object::{Self, UID};

// === Imports ===

// === Errors ===

const E_INVALID_IDX: u64 = 0;
const E_INCOMPLETE_EXECUTION: u64 = 1;
const E_UNAUTHORIZED_INCREMENT: u64 = 2;

const EXECUTION_WITNESS_STRUCT: vector<u8> = b"ExecutionProgressWitness";
const ASCII_LT: u8 = 60;

// === Structs ===

/// Hot potato ensuring the actions in the intent are executed as intended.
public struct Executable<Outcome: store> {
    // UID for attaching resources (e.g., coins passed between actions)
    id: UID,
    // intent to return or destroy (if execution_times empty) after execution
    intent: Intent<Outcome>,
    // current action index for sequential processing
    action_idx: u64,
}

// === View functions ===

/// Returns a reference to the intent
public fun intent<Outcome: store>(executable: &Executable<Outcome>): &Intent<Outcome> {
    &executable.intent
}

/// Returns the current action index
public fun action_idx<Outcome: store>(executable: &Executable<Outcome>): u64 {
    executable.action_idx
}

/// Returns mutable reference to the UID.
///
/// SECURITY: restricted to this package so external PTB code can't access the UID directly and
/// bypass witness-gated APIs via `sui::dynamic_field`.
public(package) fun uid_mut<Outcome: store>(executable: &mut Executable<Outcome>): &mut UID {
    &mut executable.id
}

/// Returns immutable reference to the UID
public(package) fun uid<Outcome: store>(executable: &Executable<Outcome>): &UID {
    &executable.id
}

// Actions are now stored as BCS bytes in ActionSpec
// The dispatcher must deserialize them when needed

/// Get the type of the current action
/// Panics if action_idx is out of bounds (>= action count)
public fun current_action_type<Outcome: store>(executable: &Executable<Outcome>): TypeName {
    let specs = executable.intent().action_specs();
    assert!(executable.action_idx < specs.length(), E_INVALID_IDX);
    intents::action_spec_type(specs.borrow(executable.action_idx))
}

/// Increment the action index after validating the current action type and witness.
public fun increment_action_idx<Outcome: store, ActionType: drop, W: drop>(
    executable: &mut Executable<Outcome>,
    _registry: &PackageRegistry,
    _witness: W,
) {
    let specs = executable.intent().action_specs();
    assert!(executable.action_idx < specs.length(), E_INVALID_IDX);
    assert_can_increment_for_current_action<Outcome, W>(executable);
    assert!(
        action_validation::is_action_type<ActionType>(specs.borrow(executable.action_idx)),
        E_UNAUTHORIZED_INCREMENT,
    );
    executable.action_idx = executable.action_idx + 1;
}

/// Asserts that the provided witness is the execution-progress witness for the
/// current action module in this executable context.
public fun assert_current_action_witness<Outcome: store, W: drop>(
    executable: &Executable<Outcome>,
    _registry: &PackageRegistry,
    _witness: W,
) {
    let specs = executable.intent().action_specs();
    assert!(executable.action_idx < specs.length(), E_INVALID_IDX);
    assert_can_increment_for_current_action<Outcome, W>(executable);
}

/// Check if all actions have been executed (action_idx == action count)
public fun is_complete<Outcome: store>(executable: &Executable<Outcome>): bool {
    executable.action_idx == executable.intent().action_specs().length()
}

// === Helper Functions ===

fun assert_can_increment_for_current_action<Outcome: store, W: drop>(
    executable: &Executable<Outcome>,
) {
    let witness_type = type_name::with_original_ids<W>();
    assert!(!type_name::is_primitive(&witness_type), E_UNAUTHORIZED_INCREMENT);

    let action_type = current_action_type(executable);
    assert!(!type_name::is_primitive(&action_type), E_UNAUTHORIZED_INCREMENT);
    assert!(
        type_name_package_addr(&witness_type) == type_name_package_addr(&action_type) &&
            type_name::module_string(&witness_type) == type_name::module_string(&action_type) &&
            &struct_name_bytes(&witness_type) == &EXECUTION_WITNESS_STRUCT,
        E_UNAUTHORIZED_INCREMENT,
    );
}

fun type_name_package_addr(type_name_ref: &TypeName): address {
    address::from_bytes(hex::decode(type_name::address_string(type_name_ref).into_bytes()))
}

fun struct_name_bytes(type_name_ref: &TypeName): vector<u8> {
    let full_type_bytes = type_name::as_string(type_name_ref).as_bytes();
    let address_len = type_name::address_string(type_name_ref).as_bytes().length();
    let module_len = type_name::module_string(type_name_ref).as_bytes().length();
    let start = address_len + 2 + module_len + 2; // <addr>::<module>::

    if (start >= full_type_bytes.length()) {
        return vector[]
    };

    let mut struct_name = vector[];
    let mut i = start;
    while (i < full_type_bytes.length()) {
        let c = full_type_bytes[i];
        if (c == ASCII_LT) {
            break
        };
        struct_name.push_back(c);
        i = i + 1;
    };
    struct_name
}

// === Package functions ===

public(package) fun new<Outcome: store>(
    intent: Intent<Outcome>,
    ctx: &mut TxContext,
): Executable<Outcome> {
    Executable {
        id: object::new(ctx),
        intent,
        action_idx: 0,
    }
}

fun destroy<Outcome: store>(executable: Executable<Outcome>): Intent<Outcome> {
    let Executable { id, intent, .. } = executable;
    object::delete(id);
    intent
}

/// Destroy only if all actions have been executed (action_idx == action count).
/// This provides safety against partial execution when required by the dispatcher.
public(package) fun destroy_complete<Outcome: store>(executable: Executable<Outcome>): Intent<Outcome> {
    assert!(executable.is_complete(), E_INCOMPLETE_EXECUTION);
    destroy(executable)
}

//**************************************************************************************************//
// Tests                                                                                            //
//**************************************************************************************************//

#[test_only]
use sui::test_utils::{assert_eq, destroy as test_destroy};
#[test_only]
use sui::clock;
// intents already imported at top of module

#[test_only]
public struct TestOutcome has copy, drop, store {}
#[test_only]
public struct TestAction has drop, store {}
#[test_only]
public struct TestActionType has drop {}
#[test_only]
public struct TestActionType2 has drop {}
#[test_only]
public struct ExecutionProgressWitness has drop {}
#[test_only]
public struct WrongModuleWitness has drop {}
#[test_only]
public struct TestIntentWitness() has drop;

#[test_only]
fun new_test_registry(ctx: &mut TxContext): PackageRegistry {
    let mut registry = package_registry::new_for_testing(ctx);
    package_registry::add_for_testing(
        &mut registry,
        b"AccountProtocol".to_string(),
        type_name_package_addr(&type_name::with_original_ids<TestActionType>()),
        1,
    );
    registry
}

#[test_only]
public fun new_for_testing<Outcome: store>(
    intent: Intent<Outcome>,
    ctx: &mut TxContext,
): Executable<Outcome> {
    new(intent, ctx)
}

#[test_only]
public fun new_single_action_for_testing(
    account_addr: address,
    clock: &sui::clock::Clock,
    ctx: &mut TxContext,
): Executable<TestOutcome> {
    let params = intents::new_params(
        b"test_key".to_string(),
        b"test_description".to_string(),
        vector[1000],
        2000,
        clock,
        ctx,
    );

    let mut intent = intents::new_intent(
        params,
        TestOutcome {},
        account_addr,
        TestIntentWitness(),
        ctx,
    );

    intents::add_action_spec(
        &mut intent,
        TestActionType {},
        vector[1],
        TestIntentWitness(),
    );

    new(intents::finish_pending(intent), ctx)
}

#[test_only]
public fun new_execution_progress_witness_for_testing(): ExecutionProgressWitness {
    ExecutionProgressWitness {}
}

#[test_only]
public fun action_type_at<Outcome: store>(executable: &Executable<Outcome>, idx: u64): TypeName {
    let specs = executable.intent().action_specs();
    assert!(idx < specs.length(), E_INVALID_IDX);
    intents::action_spec_type(specs.borrow(idx))
}

#[test_only]
public fun remaining_actions<Outcome: store>(executable: &Executable<Outcome>): u64 {
    let specs = executable.intent().action_specs();
    let total = specs.length();
    if (executable.action_idx >= total) {
        0
    } else {
        total - executable.action_idx
    }
}

#[test]
fun test_new_executable() {
    let ctx = &mut tx_context::dummy();
    let clock = clock::create_for_testing(ctx);

    let params = intents::new_params(
        b"test_key".to_string(),
        b"test_description".to_string(),
        vector[1000],
        2000,
        &clock,
        ctx,
    );

    let intent = intents::new_intent(
        params,
        TestOutcome {},
        @0xCAFE,
        TestIntentWitness(),
        ctx,
    );

    let executable = new(intents::finish_pending(intent), ctx);

    assert_eq(action_idx(&executable), 0);
    assert_eq(intent(&executable).key(), b"test_key".to_string());

    test_destroy(executable);
    test_destroy(clock);
}

#[test]
fun test_destroy_executable() {
    let ctx = &mut tx_context::dummy();
    let clock = clock::create_for_testing(ctx);

    let params = intents::new_params(
        b"test_key".to_string(),
        b"test_description".to_string(),
        vector[1000],
        2000,
        &clock,
        ctx,
    );

    let intent = intents::new_intent(
        params,
        TestOutcome {},
        @0xCAFE,
        TestIntentWitness(),
        ctx,
    );

    let executable = new(intents::finish_pending(intent), ctx);
    let recovered_intent = destroy(executable);

    assert_eq(recovered_intent.key(), b"test_key".to_string());
    assert_eq(recovered_intent.description(), b"test_description".to_string());

    test_destroy(recovered_intent);
    test_destroy(clock);
}

#[test]
fun test_executable_with_multiple_actions() {
    let ctx = &mut tx_context::dummy();
    let clock = clock::create_for_testing(ctx);

    let params = intents::new_params(
        b"test_key".to_string(),
        b"test_description".to_string(),
        vector[1000],
        2000,
        &clock,
        ctx,
    );

    let mut intent = intents::new_intent(
        params,
        TestOutcome {},
        @0xCAFE,
        TestIntentWitness(),
        ctx,
    );

    // Add 3 action specs so incrementing is valid.
    intents::add_action_spec(
        &mut intent,
        TestActionType {},
        vector[1],
        TestIntentWitness(),
    );
    intents::add_action_spec(
        &mut intent,
        TestActionType {},
        vector[2],
        TestIntentWitness(),
    );
    intents::add_action_spec(
        &mut intent,
        TestActionType {},
        vector[3],
        TestIntentWitness(),
    );

	let mut executable = new(intents::finish_pending(intent), ctx);
    let registry = new_test_registry(ctx);

	assert_eq(action_idx(&executable), 0);
	assert_eq(intent(&executable).action_specs().length(), 3);

    increment_action_idx<_, TestActionType, _>(&mut executable, &registry, ExecutionProgressWitness {});
    assert_eq(action_idx(&executable), 1);
    increment_action_idx<_, TestActionType, _>(&mut executable, &registry, ExecutionProgressWitness {});
    assert_eq(action_idx(&executable), 2);
    increment_action_idx<_, TestActionType, _>(&mut executable, &registry, ExecutionProgressWitness {});
    assert_eq(action_idx(&executable), 3);

	test_destroy(executable);
    test_destroy(registry);
	test_destroy(clock);
}

#[test]
fun test_intent_access() {
    let ctx = &mut tx_context::dummy();
    let clock = clock::create_for_testing(ctx);

    let params = intents::new_params(
        b"test_key".to_string(),
        b"test_description".to_string(),
        vector[1000],
        2000,
        &clock,
        ctx,
    );

    let intent = intents::new_intent(
        params,
        TestOutcome {},
        @0xCAFE,
        TestIntentWitness(),
        ctx,
    );

    let executable = new(intents::finish_pending(intent), ctx);
    let intent_ref = intent(&executable);

    assert_eq(intent_ref.key(), b"test_key".to_string());
    assert_eq(intent_ref.description(), b"test_description".to_string());
    assert_eq(intent_ref.account(), @0xCAFE);

    test_destroy(executable);
    test_destroy(clock);
}

#[test]
fun test_is_complete() {
    let ctx = &mut tx_context::dummy();
    let clock = clock::create_for_testing(ctx);

    let params = intents::new_params(
        b"test_key".to_string(),
        b"test_description".to_string(),
        vector[1000],
        2000,
        &clock,
        ctx,
    );

    let intent = intents::new_intent(
        params,
        TestOutcome {},
        @0xCAFE,
        TestIntentWitness(),
        ctx,
    );

    let mut executable = new(intents::finish_pending(intent), ctx);

    // No actions, so should be complete at index 0
    assert!(is_complete(&executable));

    test_destroy(executable);
    test_destroy(clock);
}

#[test, expected_failure(abort_code = E_INVALID_IDX)]
fun test_oob_current_action_type() {
    let ctx = &mut tx_context::dummy();
    let clock = clock::create_for_testing(ctx);

    let params = intents::new_params(
        b"test_key".to_string(),
        b"test_description".to_string(),
        vector[1000],
        2000,
        &clock,
        ctx,
    );

    let intent = intents::new_intent(
        params,
        TestOutcome {},
        @0xCAFE,
        TestIntentWitness(),
        ctx,
    );

	let mut executable = new(intents::finish_pending(intent), ctx);
    let registry = new_test_registry(ctx);

    // Increment past empty action list—should panic when accessing
    increment_action_idx<_, TestActionType, _>(&mut executable, &registry, ExecutionProgressWitness {});
    let _ = current_action_type(&executable);

	test_destroy(executable);
    test_destroy(registry);
	test_destroy(clock);
}

#[test, expected_failure(abort_code = E_INVALID_IDX)]
fun test_oob_action_type_at() {
    let ctx = &mut tx_context::dummy();
    let clock = clock::create_for_testing(ctx);

    let params = intents::new_params(
        b"test_key".to_string(),
        b"test_description".to_string(),
        vector[1000],
        2000,
        &clock,
        ctx,
    );

    let intent = intents::new_intent(
        params,
        TestOutcome {},
        @0xCAFE,
        TestIntentWitness(),
        ctx,
    );

    let executable = new(intents::finish_pending(intent), ctx);

    // Try to access an action at index 0 when no actions exist
    let _ = action_type_at(&executable, 0);

    test_destroy(executable);
    test_destroy(clock);
}

#[test, expected_failure(abort_code = E_INCOMPLETE_EXECUTION)]
fun test_destroy_complete_incomplete() {
    let ctx = &mut tx_context::dummy();
    let clock = clock::create_for_testing(ctx);

    let params = intents::new_params(
        b"test_key".to_string(),
        b"test_description".to_string(),
        vector[1000],
        2000,
        &clock,
        ctx,
    );

    let mut intent = intents::new_intent(
        params,
        TestOutcome {},
        @0xCAFE,
        TestIntentWitness(),
        ctx,
    );
    intents::add_action_spec(
        &mut intent,
        TestActionType {},
        vector[1],
        TestIntentWitness(),
    );

    let executable = new(intents::finish_pending(intent), ctx);

    let intent = destroy_complete(executable);
    intents::destroy_intent_for_testing(intent);

    test_destroy(clock);
}

#[test]
fun test_remaining_actions() {
    let ctx = &mut tx_context::dummy();
    let clock = clock::create_for_testing(ctx);

    let params = intents::new_params(
        b"test_key".to_string(),
        b"test_description".to_string(),
        vector[1000],
        2000,
        &clock,
        ctx,
    );

    let mut intent = intents::new_intent(
        params,
        TestOutcome {},
        @0xCAFE,
        TestIntentWitness(),
        ctx,
    );
    intents::add_action_spec(
        &mut intent,
        TestActionType {},
        vector[1],
        TestIntentWitness(),
    );

	let mut executable = new(intents::finish_pending(intent), ctx);
    let registry = new_test_registry(ctx);

	assert_eq(remaining_actions(&executable), 1);

    increment_action_idx<_, TestActionType, _>(&mut executable, &registry, ExecutionProgressWitness {});
    assert_eq(remaining_actions(&executable), 0);

	test_destroy(executable);
    test_destroy(registry);
	test_destroy(clock);
}

// === Type ID Tests ===
// These tests verify that ActionSpec and execution matching use the same TypeName source.

#[test]
/// Verify that action type stored in ActionSpec uses with_original_ids
/// and matches what current_action_type returns.
fun test_type_ids_consistent_for_action_matching() {
    let ctx = &mut tx_context::dummy();
    let clock = clock::create_for_testing(ctx);

    let params = intents::new_params(
        b"test_key".to_string(),
        b"test_description".to_string(),
        vector[1000],
        2000,
        &clock,
        ctx,
    );

    let mut intent = intents::new_intent(
        params,
        TestOutcome {},
        @0xCAFE,
        TestIntentWitness(),
        ctx,
    );

    intents::add_action_spec(
        &mut intent,
        TestActionType {},
        vector[1],
        TestIntentWitness(),
    );

    let executable = new(intents::finish_pending(intent), ctx);

    // The action type stored in the ActionSpec must equal with_original_ids<T>
    let stored_type = current_action_type(&executable);
    let expected_type = type_name::with_original_ids<TestActionType>();
    assert_eq(stored_type, expected_type);

    test_destroy(executable);
    test_destroy(clock);
}

#[test, expected_failure(abort_code = E_UNAUTHORIZED_INCREMENT)]
/// Verify that a witness from a different module cannot increment the action index,
/// even if it has the name "ExecutionProgressWitness". The package/module address
/// must match the action's package/module.
fun test_cross_module_witness_rejected() {
    let ctx = &mut tx_context::dummy();
    let clock = clock::create_for_testing(ctx);

    let params = intents::new_params(
        b"test_key".to_string(),
        b"test_description".to_string(),
        vector[1000],
        2000,
        &clock,
        ctx,
    );

    let mut intent = intents::new_intent(
        params,
        TestOutcome {},
        @0xCAFE,
        TestIntentWitness(),
        ctx,
    );

    // Add action for TestActionType (defined in this module)
    intents::add_action_spec(
        &mut intent,
        TestActionType {},
        vector[1],
        TestIntentWitness(),
    );

	let mut executable = new(intents::finish_pending(intent), ctx);
    let registry = new_test_registry(ctx);

    // WrongModuleWitness is NOT named "ExecutionProgressWitness",
    // so it should fail the struct name check
    increment_action_idx<_, TestActionType, _>(&mut executable, &registry, WrongModuleWitness {});

    test_destroy(executable);
    test_destroy(registry);
    test_destroy(clock);
}

#[test, expected_failure(abort_code = E_UNAUTHORIZED_INCREMENT)]
/// Verify that a same-module witness cannot advance the index for the wrong action type.
fun test_same_module_wrong_action_type_rejected() {
    let ctx = &mut tx_context::dummy();
    let clock = clock::create_for_testing(ctx);

    let params = intents::new_params(
        b"test_key".to_string(),
        b"test_description".to_string(),
        vector[1000],
        2000,
        &clock,
        ctx,
    );

    let mut intent = intents::new_intent(
        params,
        TestOutcome {},
        @0xCAFE,
        TestIntentWitness(),
        ctx,
    );

    intents::add_action_spec(
        &mut intent,
        TestActionType {},
        vector[1],
        TestIntentWitness(),
    );

    let mut executable = new(intents::finish_pending(intent), ctx);
    let registry = new_test_registry(ctx);

    increment_action_idx<_, TestActionType2, _>(&mut executable, &registry, ExecutionProgressWitness {});

	test_destroy(executable);
    test_destroy(registry);
	test_destroy(clock);
}

#[test]
/// Verify that different action types in the same module are distinguished.
/// This ensures that incrementing action_idx with the correct witness for one
/// action type doesn't accidentally satisfy a different action type.
fun test_different_action_types_distinguished() {
    let ctx = &mut tx_context::dummy();
    let clock = clock::create_for_testing(ctx);

    let params = intents::new_params(
        b"test_key".to_string(),
        b"test_description".to_string(),
        vector[1000],
        2000,
        &clock,
        ctx,
    );

    let mut intent = intents::new_intent(
        params,
        TestOutcome {},
        @0xCAFE,
        TestIntentWitness(),
        ctx,
    );

    intents::add_action_spec(
        &mut intent,
        TestActionType {},
        vector[1],
        TestIntentWitness(),
    );
    intents::add_action_spec(
        &mut intent,
        TestActionType2 {},
        vector[2],
        TestIntentWitness(),
    );

    let executable = new(intents::finish_pending(intent), ctx);

    // Verify action types are stored distinctly
    let type1 = action_type_at(&executable, 0);
    let type2 = action_type_at(&executable, 1);
    assert!(type1 != type2);

    // Verify they match their respective with_original_ids values
    assert_eq(type1, type_name::with_original_ids<TestActionType>());
    assert_eq(type2, type_name::with_original_ids<TestActionType2>());

    test_destroy(executable);
    test_destroy(clock);
}
