#[test_only]
module account_protocol::owned_tests;

// NOTE: The merge_and_split, merge, and split functions have been removed.
// OwnedWithdrawObject is now the only way to withdraw owned objects including coins.
// Tests for OwnedWithdrawObject are covered by the action execution tests.
