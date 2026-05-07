// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Common utilities for time-based streaming/vesting functionality.
/// Shared between vault streams and vesting modules to avoid duplication.
/// Provides reusable math helpers for vesting and stream modules.
/// - Vested/unvested split calculations for cancellations
///
/// This enables both vault streams and standalone vestings to have:
/// - Consistent mathematical accuracy
/// - Shared security validations
/// - Unified approach to time-based fund releases

module account_actions::stream_utils;

// === Imports ===
use account_actions::actions_constants;

// === Constants ===

/// Maximum beneficiaries per stream/vesting.
/// Delegates to constants module for centralized configuration.
public fun max_beneficiaries(): u64 { actions_constants::max_beneficiaries() }

// === Iteration-Based Vesting Functions ===

/// Multiply iteration count by per-iteration amount with overflow protection.
fun iteration_amount(iterations: u64, amount_per_iteration: u64): u64 {
    let amount_u128 = (iterations as u128) * (amount_per_iteration as u128);
    assert!(amount_u128 <= (18446744073709551615 as u128), 0); // u64::MAX check
    (amount_u128 as u64)
}

/// Calculate current/forfeited iteration windows.
/// Returns: (completed_iterations, claimable_iterations, forfeited_iterations)
fun iteration_window_state(
    start_time: u64,
    iterations_total: u64,
    iteration_period_ms: u64,
    current_time: u64,
    claim_window_ms_opt: &Option<u64>,
): (u64, u64, u64) {
    // Before start time, nothing is completed.
    if (current_time < start_time) {
        return (0, 0, 0)
    };

    let elapsed = current_time - start_time;
    let current_iteration = elapsed / iteration_period_ms;
    let completed_iterations = if (current_iteration > iterations_total) {
        iterations_total
    } else {
        current_iteration
    };

    if (completed_iterations == 0) {
        return (0, 0, 0)
    };

    if (claim_window_ms_opt.is_none()) {
        return (completed_iterations, completed_iterations, 0)
    };

    let claim_window_ms = *claim_window_ms_opt.borrow();
    // Round up so a claim window smaller than one iteration still allows claiming the latest
    // completed iteration (prevents premature forfeiture due to integer truncation).
    let window_in_iterations = (((claim_window_ms as u128) + (iteration_period_ms as u128) - 1) /
        (iteration_period_ms as u128)) as u64;

    let forfeit_reference = start_time;
    let forfeit_elapsed = if (current_time > forfeit_reference) {
        current_time - forfeit_reference
    } else { 0 };
    let forfeit_ticks = forfeit_elapsed / iteration_period_ms;

    let oldest_claimable_uncapped = if (forfeit_ticks > window_in_iterations) {
        forfeit_ticks - window_in_iterations
    } else {
        0
    };

    let forfeited_iterations = if (oldest_claimable_uncapped > completed_iterations) {
        completed_iterations
    } else {
        oldest_claimable_uncapped
    };
    let claimable_iterations = completed_iterations - forfeited_iterations;

    (completed_iterations, claimable_iterations, forfeited_iterations)
}

// === Tracking-Based Claim Window Functions ===
// These functions use explicit per-iteration tracking state to precisely
// compute available amounts, avoiding the over-claiming bug in the derived
// `claimed_in_window = claimed_amount - forfeited_amount` formula.

/// Calculate available amount using precise iteration tracking.
/// Instead of deriving in-window claims from `claimed_amount - forfeited_amount`
/// (which saturates to 0 when old claims become forfeited, enabling over-claiming),
/// this uses `first_unclaimed_iteration` and `partial_claimed_in_iteration` to
/// precisely track which iterations have been consumed.
///
/// Returns: (available_amount, adjusted_first_unclaimed, adjusted_partial)
/// The adjusted values advance past any newly forfeited iterations.
/// After a successful claim of `amount`, caller must call `advance_claim_tracking`.
public fun calculate_available_with_tracking(
    amount_per_iteration: u64,
    first_unclaimed_iteration: u64,
    partial_claimed_in_iteration: u64,
    start_time: u64,
    iterations_total: u64,
    iteration_period_ms: u64,
    current_time: u64,
    claim_window_ms_opt: &Option<u64>,
): (u64, u64, u64) {
    let (completed, _, forfeited) = iteration_window_state(
        start_time,
        iterations_total,
        iteration_period_ms,
        current_time,
        claim_window_ms_opt,
    );

    // Advance past forfeited iterations
    let adj_first = if (first_unclaimed_iteration < forfeited) {
        forfeited
    } else {
        first_unclaimed_iteration
    };
    let adj_partial = if (first_unclaimed_iteration < forfeited) {
        0
    } else {
        partial_claimed_in_iteration
    };

    if (completed <= adj_first) {
        return (0, adj_first, adj_partial)
    };

    let available_iterations = completed - adj_first;
    let gross_available = iteration_amount(available_iterations, amount_per_iteration);
    let available = if (gross_available > adj_partial) {
        gross_available - adj_partial
    } else {
        0
    };

    (available, adj_first, adj_partial)
}

/// Update tracking state after a successful claim.
/// Returns: (new_first_unclaimed_iteration, new_partial_claimed_in_iteration)
public fun advance_claim_tracking(
    first_unclaimed_iteration: u64,
    partial_claimed_in_iteration: u64,
    amount_claimed: u64,
    amount_per_iteration: u64,
): (u64, u64) {
    let new_partial = partial_claimed_in_iteration + amount_claimed;
    let iterations_consumed = new_partial / amount_per_iteration;
    let remaining_partial = new_partial % amount_per_iteration;
    (first_unclaimed_iteration + iterations_consumed, remaining_partial)
}

/// Split vested and unvested amounts for cancellation using tracking state.
/// Returns: (to_pay_beneficiary, to_refund)
public fun split_vested_unvested_with_tracking(
    amount_per_iteration: u64,
    first_unclaimed_iteration: u64,
    partial_claimed_in_iteration: u64,
    balance_remaining: u64,
    start_time: u64,
    iterations_total: u64,
    iteration_period_ms: u64,
    current_time: u64,
    claim_window_ms_opt: &Option<u64>,
): (u64, u64) {
    let (available, _, _) = calculate_available_with_tracking(
        amount_per_iteration,
        first_unclaimed_iteration,
        partial_claimed_in_iteration,
        start_time,
        iterations_total,
        iteration_period_ms,
        current_time,
        claim_window_ms_opt,
    );

    let to_pay = if (available > balance_remaining) {
        balance_remaining
    } else {
        available
    };
    let to_refund = balance_remaining - to_pay;
    (to_pay, to_refund)
}

/// Validate iteration-based stream parameters
public fun validate_iteration_parameters(
    start_time: u64,
    iterations_total: u64,
    iteration_period_ms: u64,
    claim_window_ms_opt: &Option<u64>,
    _current_time: u64,
): bool {
    // Must have at least 1 iteration
    if (iterations_total == 0) return false;

    // Iteration period must be positive
    if (iteration_period_ms == 0) return false;

    // NOTE: start_time is NOT checked against current_time here. Streams/vestings
    // are staged via governance proposals whose voting period may push execution
    // past the original start_time. The underlying math in iteration_window_state
    // and calculate_available_with_tracking handles retroactive start dates correctly,
    // unlocking any missed iterations natively.

    // End time must fit in u64 for all streams (not just those with cliffs).
    // Compute with u128 intermediates to detect overflow.
    let duration_u128 = (iterations_total as u128) * (iteration_period_ms as u128);
    let end_time_u128 = (start_time as u128) + duration_u128;
    if (end_time_u128 > (18446744073709551615 as u128)) return false;

    // If claim window exists, must be at least one iteration period
    // Otherwise integer truncation causes immediate forfeiture
    if (claim_window_ms_opt.is_some()) {
        let claim_window_ms = *claim_window_ms_opt.borrow();
        if (claim_window_ms < iteration_period_ms) return false;
    };

    true
}
