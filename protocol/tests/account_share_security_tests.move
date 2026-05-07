#[test_only]
module account_protocol::account_share_security_tests;

use account_protocol::account::{Self as account, Account};
use sui::test_scenario as ts;

const OWNER: address = @0xCAFE;

#[test]
fun test_share_account_sets_initialized_true() {
    let mut scenario = ts::begin(OWNER);
    let ctx = ts::ctx(&mut scenario);

    let a = account::new_for_testing(ctx);
    account::share_account(a);

    ts::next_tx(&mut scenario, OWNER);
    let a = ts::take_shared<Account>(&scenario);
    assert!(account::is_initialized(&a), 0);
    ts::return_shared(a);

    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 21, location = account_protocol::account)]
fun test_share_account_disables_unshared_apis() {
    let mut scenario = ts::begin(OWNER);
    let ctx = ts::ctx(&mut scenario);

    let a = account::new_for_testing(ctx);
    account::share_account(a);

    ts::next_tx(&mut scenario, OWNER);
    let a = ts::take_shared<Account>(&scenario);

    // Must abort because share_account sets initialized=true.
    account::assert_not_initialized(&a);

    // Unreachable cleanup
    ts::return_shared(a);
    ts::end(scenario);
}

