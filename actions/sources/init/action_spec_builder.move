// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// PTB helper for building vector<ActionSpec> in programmable transactions
///
/// This module provides a wrapper object that can be created, mutated, and consumed
/// in PTBs (Programmable Transaction Blocks). The builder pattern is necessary because
/// raw vectors cannot be directly created in PTBs.
///
/// NOTE: This is ONLY for PTB construction. Storage everywhere uses vector<ActionSpec> directly.
module account_actions::action_spec_builder;

use account_protocol::intents::ActionSpec;
use std::string::String;
use std::type_name::TypeName;
use std::vector;
use sui::object::ID;

// === Errors ===

/// A BorrowAction was added without a matching ReturnAction
/// Every borrow must have a corresponding return to prevent permanently unexecutable proposals
const EUnmatchedBorrow: u64 = 0;

/// remove_pending_borrow called but no matching borrow was found
const EBorrowNotFound: u64 = 1;

// === Structs ===

/// Tracks an unresolved borrow that needs a matching return
public struct PendingBorrow has copy, drop {
    cap_type: TypeName,
    name: String,
}

/// Builder wrapper for constructing vector<ActionSpec> in PTBs.
/// This has drop so it can be consumed by into_vector().
///
/// SECURITY NOTE: The `copy` ability is intentional for PTB flexibility.
/// Each copied Builder has an independent specs vector, so duplication
/// does not enable replay attacks. The execution layer validates action
/// indices and enforces hot potato consumption patterns.
public struct Builder has copy, drop {
    specs: vector<ActionSpec>,
    // Event context for ActionParamsStaged emission
    source_type: u8,
    source_id: ID,
    outcome_index: u64,
    // Tracks borrows that still need a matching return
    pending_borrows: vector<PendingBorrow>,
}

/// Create a new empty builder for PTB construction
public fun new(source_type: u8, source_id: ID, outcome_index: u64): Builder {
    Builder {
        specs: vector::empty(),
        source_type,
        source_id,
        outcome_index,
        pending_borrows: vector::empty(),
    }
}

/// Add an ActionSpec to the builder (used by helper functions)
public fun add(builder: &mut Builder, action_spec: ActionSpec) {
    vector::push_back(&mut builder.specs, action_spec);
}

/// Consume the builder and extract the vector<ActionSpec>
/// This is used at the end of PTB construction to pass to stage functions
///
/// SECURITY: Asserts all borrows have matching returns before returning.
/// This prevents proposals that pass governance but are permanently unexecutable.
public fun into_vector(builder: Builder): vector<ActionSpec> {
    let Builder {
        specs,
        source_type: _,
        source_id: _,
        outcome_index: _,
        pending_borrows,
    } = builder;
    assert!(vector::is_empty(&pending_borrows), EUnmatchedBorrow);
    specs
}

/// Get the number of specs in the builder
public fun length(builder: &Builder): u64 {
    vector::length(&builder.specs)
}

/// Check if the builder is empty
public fun is_empty(builder: &Builder): bool {
    vector::is_empty(&builder.specs)
}

/// Get the source type from the builder
public fun source_type(builder: &Builder): u8 {
    builder.source_type
}

/// Get the source ID from the builder
public fun source_id(builder: &Builder): ID {
    builder.source_id
}

/// Get the outcome index from the builder
public fun outcome_index(builder: &Builder): u64 {
    builder.outcome_index
}

/// Get the next action index (number of specs already added)
public fun next_action_index(builder: &Builder): u64 {
    vector::length(&builder.specs)
}

/// Read-only access to staged specs for cross-action validation.
public fun specs(builder: &Builder): &vector<ActionSpec> {
    &builder.specs
}

/// Register a pending borrow that needs a matching return.
/// Only action helper modules should mutate this bookkeeping; otherwise a PTB
/// caller could clear pending state without staging the matching return action.
public(package) fun add_pending_borrow(builder: &mut Builder, cap_type: TypeName, name: String) {
    vector::push_back(&mut builder.pending_borrows, PendingBorrow { cap_type, name });
}

/// Remove a pending borrow when its matching return is added
/// Called by add_return_spec to resolve the borrow
/// Aborts with EBorrowNotFound if no matching borrow exists
public(package) fun remove_pending_borrow(builder: &mut Builder, cap_type: TypeName, name: String) {
    let target = PendingBorrow { cap_type, name };
    let len = vector::length(&builder.pending_borrows);
    let mut i = 0;
    while (i < len) {
        if (vector::borrow(&builder.pending_borrows, i) == &target) {
            vector::swap_remove(&mut builder.pending_borrows, i);
            return
        };
        i = i + 1;
    };
    abort EBorrowNotFound
}

// === Test Helpers ===

/// Create a new builder for testing without requiring source context
/// Uses dummy values for source_type, source_id, and outcome_index
#[test_only]
public fun new_for_testing(): Builder {
    Builder {
        specs: vector::empty(),
        source_type: 0,
        source_id: object::id_from_address(@0x0),
        outcome_index: 0,
        pending_borrows: vector::empty(),
    }
}
