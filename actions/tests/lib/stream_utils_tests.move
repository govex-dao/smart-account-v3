#[test_only]
module account_actions::stream_utils_tests;

use account_actions::stream_utils;

// ============================================================
// validate_iteration_parameters
// ============================================================

#[test]
fun test_validate_basic_valid_params() {
    let result = stream_utils::validate_iteration_parameters(
        1000,  // start_time
        10,    // iterations_total
        1000,  // iteration_period_ms
        &option::none(), // no claim window
        500,   // current_time (before start)
    );
    assert!(result);
}

#[test]
fun test_validate_start_in_past_allowed() {
    // Retroactive start times are valid — governance proposals may execute
    // after the staged start_time due to voting delays. The underlying math
    // handles this correctly by unlocking missed iterations.
    let result = stream_utils::validate_iteration_parameters(
        100,   // start_time (in the past)
        10,
        1000,
        &option::none(),
        500,   // current_time > start_time
    );
    assert!(result);
}

#[test]
fun test_validate_zero_iterations_fails() {
    let result = stream_utils::validate_iteration_parameters(
        1000,
        0,     // zero iterations
        1000,
        &option::none(),
        500,
    );
    assert!(!result);
}

#[test]
fun test_validate_zero_period_fails() {
    let result = stream_utils::validate_iteration_parameters(
        1000,
        10,
        0,     // zero period
        &option::none(),
        500,
    );
    assert!(!result);
}

#[test]
fun test_validate_claim_window_too_small_fails() {
    // claim_window_ms must be >= iteration_period_ms
    let result = stream_utils::validate_iteration_parameters(
        1000,
        10,
        1000,
        &option::some(500), // claim window < iteration period
        100,
    );
    assert!(!result);
}

#[test]
fun test_validate_claim_window_valid() {
    let result = stream_utils::validate_iteration_parameters(
        1000,
        10,
        1000,
        &option::some(2000), // claim window >= iteration period
        100,
    );
    assert!(result);
}

#[test]
fun test_validate_start_equals_current_time() {
    // start_time == current_time should be valid
    let result = stream_utils::validate_iteration_parameters(
        500,
        10,
        1000,
        &option::none(),
        500,
    );
    assert!(result);
}

// ============================================================
// calculate_available_with_tracking
// ============================================================

#[test]
fun test_available_nothing_before_start() {
    let (available, _, _) = stream_utils::calculate_available_with_tracking(
        100,  // amount_per_iteration
        0,    // first_unclaimed_iteration
        0,    // partial_claimed_in_iteration
        1000, // start_time
        10,   // iterations_total
        1000, // iteration_period_ms
        500,  // current_time (before start)
        &option::none(),
    );
    assert!(available == 0);
}

#[test]
fun test_available_at_start() {
    // At exact start time, 0 iterations have completed
    let (available, _, _) = stream_utils::calculate_available_with_tracking(
        100, 0, 0,
        1000, 10, 1000,
        1000, // current_time == start_time
        &option::none(),
    );
    assert!(available == 0);
}

#[test]
fun test_available_one_iteration() {
    let (available, _, _) = stream_utils::calculate_available_with_tracking(
        100, 0, 0,
        1000, 10, 1000,
        2000, // 1 iteration elapsed
        &option::none(),
    );
    assert!(available == 100);
}

#[test]
fun test_available_mid_iteration() {
    // 1.5 iterations elapsed — only 1 completed
    let (available, _, _) = stream_utils::calculate_available_with_tracking(
        100, 0, 0,
        1000, 10, 1000,
        2500,
        &option::none(),
    );
    assert!(available == 100);
}

#[test]
fun test_available_all_iterations() {
    let (available, _, _) = stream_utils::calculate_available_with_tracking(
        100, 0, 0,
        1000, 10, 1000,
        11000, // all 10 iterations completed
        &option::none(),
    );
    assert!(available == 1000);
}

#[test]
fun test_available_past_all_iterations() {
    // Way past end — should still cap at total
    let (available, _, _) = stream_utils::calculate_available_with_tracking(
        100, 0, 0,
        1000, 10, 1000,
        99999,
        &option::none(),
    );
    assert!(available == 1000);
}

#[test]
fun test_available_after_partial_claim() {
    // 3 iterations completed, already claimed 150 from first 2 iterations
    // first_unclaimed = 1 (partially claimed iteration 1), partial = 50
    let (available, _, _) = stream_utils::calculate_available_with_tracking(
        100, 1, 50,
        1000, 10, 1000,
        4000, // 3 iterations completed
        &option::none(),
    );
    // available_iterations = 3 - 1 = 2, gross = 200, minus partial 50 = 150
    assert!(available == 150);
}

#[test]
fun test_available_with_claim_window_no_forfeiture() {
    // Claim window of 3000ms (3 iterations), 2 iterations completed, none forfeited
    let (available, _, _) = stream_utils::calculate_available_with_tracking(
        100, 0, 0,
        1000, 10, 1000,
        3000,
        &option::some(3000),
    );
    assert!(available == 200);
}

#[test]
fun test_available_with_claim_window_forfeiture() {
    // Claim window = 2000ms (2 iteration periods), 6 iterations completed
    // forfeit_ticks = 5 (from start), window_in_iterations = 2
    // oldest_claimable_uncapped = 5 - 2 = 3, forfeited = 3
    // completed = 5, claimable = 5 - 3 = 2
    // available = 2 iterations * 100 = 200
    let (available, adj_first, _) = stream_utils::calculate_available_with_tracking(
        100, 0, 0,
        1000, 10, 1000,
        6000,
        &option::some(2000),
    );
    assert!(available == 200);
    // first_unclaimed should be advanced past forfeited iterations
    assert!(adj_first == 3);
}

// ============================================================
// advance_claim_tracking
// ============================================================

#[test]
fun test_advance_exact_iteration() {
    // Claim exactly one iteration worth
    let (new_first, new_partial) = stream_utils::advance_claim_tracking(
        0,   // first_unclaimed_iteration
        0,   // partial_claimed_in_iteration
        100, // amount_claimed
        100, // amount_per_iteration
    );
    assert!(new_first == 1);
    assert!(new_partial == 0);
}

#[test]
fun test_advance_partial_iteration() {
    // Claim half an iteration
    let (new_first, new_partial) = stream_utils::advance_claim_tracking(
        0, 0,
        50,  // half of 100
        100,
    );
    assert!(new_first == 0);
    assert!(new_partial == 50);
}

#[test]
fun test_advance_multiple_iterations() {
    // Claim 2.5 iterations worth
    let (new_first, new_partial) = stream_utils::advance_claim_tracking(
        0, 0,
        250, // 2.5 * 100
        100,
    );
    assert!(new_first == 2);
    assert!(new_partial == 50);
}

#[test]
fun test_advance_from_existing_partial() {
    // Already 30 into iteration 2, claim 120 more
    let (new_first, new_partial) = stream_utils::advance_claim_tracking(
        2,   // first_unclaimed_iteration
        30,  // partial
        120, // amount
        100,
    );
    // new_partial = 30 + 120 = 150, consumed = 150/100 = 1, remaining = 50
    assert!(new_first == 3);
    assert!(new_partial == 50);
}

#[test]
fun test_advance_zero_claim() {
    let (new_first, new_partial) = stream_utils::advance_claim_tracking(
        5, 25,
        0, // no claim
        100,
    );
    assert!(new_first == 5);
    assert!(new_partial == 25);
}

// ============================================================
// split_vested_unvested_with_tracking
// ============================================================

#[test]
fun test_split_nothing_vested() {
    // Before start — nothing vested, all refunded
    let (to_pay, to_refund) = stream_utils::split_vested_unvested_with_tracking(
        100, 0, 0,
        1000, // balance_remaining
        5000, // start_time
        10, 1000,
        1000, // current_time < start_time
        &option::none(),
    );
    assert!(to_pay == 0);
    assert!(to_refund == 1000);
}

#[test]
fun test_split_partially_vested() {
    // 3 of 10 iterations completed, 300 vested, 700 unvested
    let (to_pay, to_refund) = stream_utils::split_vested_unvested_with_tracking(
        100, 0, 0,
        1000,
        1000, // start_time
        10, 1000,
        4000, // 3 iterations elapsed
        &option::none(),
    );
    assert!(to_pay == 300);
    assert!(to_refund == 700);
}

#[test]
fun test_split_fully_vested() {
    // All iterations completed
    let (to_pay, to_refund) = stream_utils::split_vested_unvested_with_tracking(
        100, 0, 0,
        1000,
        1000,
        10, 1000,
        99999, // way past end
        &option::none(),
    );
    assert!(to_pay == 1000);
    assert!(to_refund == 0);
}

#[test]
fun test_split_after_partial_claim() {
    // 5 iterations completed, already claimed 200 (2 iterations)
    // remaining balance = 800, available = 300 (iterations 2-4)
    let (to_pay, to_refund) = stream_utils::split_vested_unvested_with_tracking(
        100, 2, 0,
        800,  // balance after 200 claimed
        1000,
        10, 1000,
        6000, // 5 iterations elapsed
        &option::none(),
    );
    // available = 3 iterations (2,3,4) * 100 = 300
    assert!(to_pay == 300);
    assert!(to_refund == 500);
}

#[test]
fun test_split_available_exceeds_balance() {
    // More vested than balance remaining (edge case: someone already claimed most)
    // 10 iterations all completed, first_unclaimed=0, but balance only 50
    let (to_pay, to_refund) = stream_utils::split_vested_unvested_with_tracking(
        100, 0, 0,
        50,   // only 50 left
        1000,
        10, 1000,
        99999,
        &option::none(),
    );
    // available = 1000 but balance = 50, so to_pay = min(1000, 50) = 50
    assert!(to_pay == 50);
    assert!(to_refund == 0);
}

// ============================================================
// max_beneficiaries
// ============================================================

#[test]
fun test_max_beneficiaries() {
    assert!(stream_utils::max_beneficiaries() == 100);
}
