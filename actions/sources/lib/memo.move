// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Generic memo emission actions for Account Protocol
/// Works with any Account type
/// Provides text memos
///
/// Can be used for:
/// - Simple text memos: "This is important"
/// - Accept decisions: "Accept" + Some(proposal_id)
/// - Reject decisions: "Reject" + Some(proposal_id)
/// - Comments on objects: "Looks good!" + Some(object_id)

module account_actions::memo;

public struct ExecutionProgressWitness has drop {}

use account_protocol::account::{Self, Account};
use account_protocol::bcs_validation;
use account_protocol::executable::{Self, Executable};
use account_protocol::intents;
use account_protocol::package_registry::PackageRegistry;
use std::string::{Self, String};
use sui::bcs;
use sui::clock::Clock;
use sui::event;
use account_actions::actions_constants;

// === Errors ===

const EEmptyMemo: u64 = 0;
const EMemoTooLong: u64 = 1;
const EUnsupportedActionVersion: u64 = 2;

// === Action Type Markers ===

/// Emit a text memo
public struct Memo has drop {}

public(package) fun memo(): Memo { Memo {} }

// === Events ===

public struct MemoEmitted has copy, drop {
    /// DAO that emitted the memo
    dao_id: object::ID,
    /// The memo content
    memo: String,
    /// When it was emitted
    timestamp: u64,
    /// Who triggered the emission
    emitter: address,
}

// === Public Functions ===

/// Execute an emit memo action
public fun do_emit_memo<Config: store, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    registry: &PackageRegistry,
    _intent_witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    account::assert_execution_authorized(account, registry, executable, ExecutionProgressWitness {});

    // Get BCS bytes from ActionSpec
    let specs = executable.intent().action_specs();
    let action_spec = specs.borrow(executable.action_idx());
    account_protocol::action_validation::assert_action_type<Memo>(action_spec);

    let action_data = intents::action_spec_data(action_spec);

    // Check version before deserialization
    let spec_version = intents::action_spec_version(action_spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Create BCS reader and deserialize
    // BCS format: String (memo)
    let mut reader = bcs::new(*action_data);
    let memo_bytes = reader.peel_vec_u8();
    let memo = string::utf8(memo_bytes);

    // Validate all bytes consumed
    bcs_validation::validate_all_bytes_consumed(reader);

    // Validate memo
    assert!(memo.length() > 0, EEmptyMemo);
    assert!(memo.length() <= actions_constants::max_memo_length(), EMemoTooLong);

    // Emit the event
    event::emit(MemoEmitted {
        dao_id: object::id(account),
        memo,
        timestamp: clock.timestamp_ms(),
        emitter: tx_context::sender(ctx),
    });

    executable::increment_action_idx<_, Memo, _>(executable, registry, ExecutionProgressWitness {});
}
