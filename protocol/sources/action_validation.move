// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

// ============================================================================
// Action Type Validation Helper Module
// ============================================================================
// This module provides a centralized type validation helper for action handlers.
// It ensures type safety by verifying that action specs match expected types
// before deserialization, preventing type confusion vulnerabilities.
//
// SECURITY: This is a critical security module that prevents wrong actions
// from being executed by wrong handlers.
// ============================================================================

module account_protocol::action_validation;

use account_protocol::intents::{Self, ActionSpec};
use std::type_name::{Self};

// === Imports ===

// === Errors ===

const EWrongActionType: u64 = 0;

// === Public Functions ===

/// Assert that an ActionSpec has the expected action type.
/// This MUST be called before deserializing action data in any do_* function.
///
/// # Type Parameters
/// * `T` - The expected action type (must have `drop`)
///
/// # Arguments
/// * `action_spec` - The ActionSpec to validate
///
/// # Aborts
/// * `EWrongActionType` - If the action type doesn't match the expected type
///
/// # Example
/// ```move
/// public fun do_spend<...>(...) {
///     let action_spec = specs.borrow(executable.action_idx());
///     action_validation::assert_action_type<VaultSpend>(action_spec);
///     // Now safe to deserialize
///     let action_data = intents::action_spec_data(action_spec);
/// }
/// ```
public fun assert_action_type<T: drop>(action_spec: &ActionSpec) {
    let expected_type = type_name::with_original_ids<T>();
    assert!(intents::action_spec_type(action_spec) == expected_type, EWrongActionType);
}

/// Check if an ActionSpec matches the expected type without aborting.
/// Returns true if types match, false otherwise.
public fun is_action_type<T: drop>(action_spec: &ActionSpec): bool {
    let expected_type = type_name::with_original_ids<T>();
    intents::action_spec_type(action_spec) == expected_type
}

// === Test Functions ===

#[test_only]
public struct TestAction has drop {}

#[test_only]
fun create_test_action_spec<T: drop>(action_type_witness: T): ActionSpec {
    intents::new_action_spec(action_type_witness, vector::empty(), 1)
}

#[test_only]
public struct WrongAction has drop {}

#[test]
fun test_assert_action_type_success() {
    let action_spec = create_test_action_spec(TestAction {});
    assert_action_type<TestAction>(&action_spec);
    // Should not abort
}

#[test]
#[expected_failure(abort_code = EWrongActionType)]
fun test_assert_action_type_failure() {
    let action_spec = create_test_action_spec(TestAction {});
    assert_action_type<WrongAction>(&action_spec);
    // Should abort with EWrongActionType
}

#[test]
fun test_is_action_type() {
    let action_spec = create_test_action_spec(TestAction {});
    assert!(is_action_type<TestAction>(&action_spec));
    assert!(!is_action_type<WrongAction>(&action_spec));
}
