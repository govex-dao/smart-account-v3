// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Init action staging and dispatching for streams
///
/// This module provides action structs and builders for creating
/// vesting streams during DAO initialization.
module account_actions::stream_init_actions;

use account_actions::actions_constants;
use account_protocol::intents::{Self};
use std::option::Option;
use std::string::String;

// === Errors ===
const EInvalidStreamParams: u64 = 1;
const EZeroBeneficiary: u64 = 2;
/// Streams (empty whitelist) do not honor expiry_ms, so accepting Some(_)
/// would silently drop the parameter at execution time.
const EExpiryNotSupportedForStream: u64 = 3;
/// Spending limit whitelist must not contain @0x0.
const EZeroWhitelistRecipient: u64 = 4;
/// Spending limit whitelist exceeds max_beneficiaries() bound.
const ETooManyRecipients: u64 = 5;
/// Spending limit whitelist must not contain duplicate recipients.
const EDuplicateRecipient: u64 = 6;

// === Action Structs (for staging/dispatching) ===

/// Action to create an iteration-based vesting stream or spending limit.
/// Stored in InitActionSpecs with BCS serialization.
/// If whitelisted_recipients is empty -> regular stream, mints StreamCap to beneficiary.
/// If whitelisted_recipients is non-empty -> spending limit, mints SpendingCap to delegate.
/// Note: All streams/spending limits are always cancellable by DAO governance.
public struct CreateStreamAction has copy, drop, store {
    vault_name: String,
    beneficiary: address, // Stream beneficiary or spending limit delegate
    amount_per_iteration: u64, // Tokens per iteration (NO DIVISION)
    start_time: Option<u64>, // None = use clock time at execution
    iterations_total: u64,
    iteration_period_ms: u64,
    claim_window_ms: Option<u64>,
    expiry_ms: Option<u64>, // Spending limits only; MUST be none for streams
    whitelisted_recipients: vector<address>, // Empty = stream, non-empty = spending limit
}

// === Spec Builders (for PTB construction) ===

/// Add CreateStreamAction to Builder
/// Used for staging actions in launchpad raises via PTB
/// Note: All streams are always cancellable by DAO governance (cancel & recreate to modify)
/// CoinType must match the stream's coin type
///
/// Mode contract enforced at staging time:
/// - Stream mode (empty whitelist): expiry_ms MUST be option::none(). The stream
///   handler ignores expiry, so accepting Some(_) here would silently drop it and
///   mislead callers/indexers.
/// - Spending-limit mode (non-empty whitelist): expiry_ms is optional. The
///   whitelist must not contain @0x0 and must not contain duplicates.
public fun add_create_stream_spec<CoinType>(
    builder: &mut account_actions::action_spec_builder::Builder,
    vault_name: String,
    beneficiary: address, // Stream beneficiary or spending limit delegate
    amount_per_iteration: u64,
    start_time: Option<u64>, // None = use clock time at execution
    iterations_total: u64,
    iteration_period_ms: u64,
    claim_window_ms: Option<u64>,
    expiry_ms: Option<u64>, // Spending limits only (must be none for streams)
    whitelisted_recipients: vector<address>, // Empty = stream, non-empty = spending limit
) {
    use account_actions::action_spec_builder as builder_mod;
    use sui::bcs;

    assert!(beneficiary != @0x0, EZeroBeneficiary);
    assert!(amount_per_iteration > 0, EInvalidStreamParams);
    assert!(iterations_total > 0, EInvalidStreamParams);
    assert!(iteration_period_ms > 0, EInvalidStreamParams);

    // Mode-specific validation. Stream mode never honors expiry_ms; spending
    // limit mode requires non-zero recipients within the bounded list size.
    if (whitelisted_recipients.is_empty()) {
        assert!(expiry_ms.is_none(), EExpiryNotSupportedForStream);
    } else {
        let len = whitelisted_recipients.length();
        assert!(len <= actions_constants::max_beneficiaries(), ETooManyRecipients);
        let mut i = 0;
        while (i < len) {
            let recipient = *whitelisted_recipients.borrow(i);
            assert!(recipient != @0x0, EZeroWhitelistRecipient);

            let mut j = i + 1;
            while (j < len) {
                assert!(recipient != *whitelisted_recipients.borrow(j), EDuplicateRecipient);
                j = j + 1;
            };
            i = i + 1;
        };
    };


    // Create action struct (streams/spending limits are always cancellable)
    let action = CreateStreamAction {
        vault_name,
        beneficiary,
        amount_per_iteration,
        start_time,
        iterations_total,
        iteration_period_ms,
        claim_window_ms,
        expiry_ms,
        whitelisted_recipients,
    };

    // Serialize
    let action_data = bcs::to_bytes(&action);

    // Add to builder with marker type from vault module (NOT the action struct!)
    let action_spec = intents::new_action_spec(
        account_actions::vault::create_stream_marker<CoinType>(),
        action_data,
        1, // version
    );
    builder_mod::add(builder, action_spec);

}
