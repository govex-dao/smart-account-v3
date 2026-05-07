// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Init action staging for memos
///
/// This module provides action structs and builders for emitting
/// memos during proposal execution.
module account_actions::memo_init_actions;

use account_actions::actions_constants;
use account_protocol::intents;
use std::string::String;

// === Errors ===
const EEmptyMemo: u64 = 1;
const EMemoTooLong: u64 = 2;

// === Action Structs (for staging) ===

/// Action to emit a text memo
public struct EmitMemoAction has copy, drop, store {
    memo: String,
}

// === Spec Builders (for PTB construction) ===

/// Add EmitMemoAction to Builder
/// Used for staging memo emissions in proposals via PTB
public fun add_emit_memo_spec(
    builder: &mut account_actions::action_spec_builder::Builder,
    memo: String,
) {
    use account_actions::action_spec_builder as builder_mod;
    use sui::bcs;

    // Validate at staging time to prevent poison-pill proposals
    assert!(memo.length() > 0, EEmptyMemo);
    assert!(memo.length() <= actions_constants::max_memo_length(), EMemoTooLong);


    // Create action struct
    let action = EmitMemoAction {
        memo,
    };

    // Serialize
    let action_data = bcs::to_bytes(&action);

    // Add to builder with marker type from memo module
    let action_spec = intents::new_action_spec(
        account_actions::memo::memo(),
        action_data,
        1, // version
    );
    builder_mod::add(builder, action_spec);

}
