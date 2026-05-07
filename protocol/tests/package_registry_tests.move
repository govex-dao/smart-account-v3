#[test_only]
module account_protocol::package_registry_tests;

use account_protocol::package_registry::{Self, PackageRegistry, PackageAdminCap};
use sui::test_scenario as ts;
use sui::test_utils::destroy;

const ADMIN: address = @0xA;

// === Helpers ===

fun setup(): (ts::Scenario, PackageRegistry, PackageAdminCap) {
    let mut scenario = ts::begin(ADMIN);
    let ctx = ts::ctx(&mut scenario);
    let registry = package_registry::new_for_testing(ctx);
    let cap = package_registry::new_admin_cap_for_testing(&registry, ctx);
    (scenario, registry, cap)
}

fun teardown(scenario: ts::Scenario, registry: PackageRegistry, cap: PackageAdminCap) {
    destroy(cap);
    destroy(registry);
    ts::end(scenario);
}

// ============================================================
// === Basic Add / Query ===
// ============================================================

#[test]
fun test_add_package_basic() {
    let (scenario, mut registry, cap) = setup();

    package_registry::add_package(
        &mut registry, &cap,
        b"PkgA".to_string(), @0x1, 1,
        vector[b"ActionX".to_string()],
        b"core".to_string(), b"desc".to_string(),
    );

    assert!(package_registry::has_package(&registry, b"PkgA".to_string()));
    assert!(package_registry::contains_package_addr(&registry, @0x1));
    assert!(package_registry::is_valid_package(&registry, b"PkgA".to_string(), @0x1, 1));
    assert!(package_registry::has_action_type(&registry, b"ActionX".to_string()));
    assert!(
        package_registry::get_package_for_action(&registry, b"ActionX".to_string())
            == b"PkgA".to_string(),
    );

    teardown(scenario, registry, cap);
}

#[test]
fun test_add_two_packages() {
    let (scenario, mut registry, cap) = setup();

    package_registry::add_package(
        &mut registry, &cap,
        b"PkgA".to_string(), @0x1, 1,
        vector[b"ActionA".to_string()],
        b"core".to_string(), b"".to_string(),
    );
    package_registry::add_package(
        &mut registry, &cap,
        b"PkgB".to_string(), @0x2, 1,
        vector[b"ActionB".to_string()],
        b"defi".to_string(), b"".to_string(),
    );

    assert!(package_registry::is_valid_package(&registry, b"PkgA".to_string(), @0x1, 1));
    assert!(package_registry::is_valid_package(&registry, b"PkgB".to_string(), @0x2, 1));
    // Cross-check: wrong name+addr should fail
    assert!(!package_registry::is_valid_package(&registry, b"PkgA".to_string(), @0x2, 1));
    assert!(!package_registry::is_valid_package(&registry, b"PkgB".to_string(), @0x1, 1));

    teardown(scenario, registry, cap);
}

// ============================================================
// === Registered Version ===
// ============================================================

#[test]
fun test_registered_version_basic() {
    let (scenario, mut registry, cap) = setup();

    package_registry::add_package(
        &mut registry, &cap,
        b"PkgA".to_string(), @0x1, 1,
        vector[], b"core".to_string(), b"".to_string(),
    );

    assert!(package_registry::contains_package_addr(&registry, @0x1));
    assert!(package_registry::is_valid_package(&registry, b"PkgA".to_string(), @0x1, 1));
    let (addr, ver) = package_registry::get_latest_version(&registry, b"PkgA".to_string());
    assert!(addr == @0x1 && ver == 1);

    teardown(scenario, registry, cap);
}

// ============================================================
// === Bug 5: remove_for_testing Leaks Action Types ===
// ============================================================

#[test]
fun test_bug5_remove_for_testing_cleans_action_types() {
    let (scenario, mut registry, cap) = setup();

    package_registry::add_full_for_testing(
        &mut registry,
        b"PkgA".to_string(), @0x1, 1,
        vector[b"ActionX".to_string(), b"ActionY".to_string()],
        b"core".to_string(), b"desc".to_string(),
    );

    assert!(package_registry::has_action_type(&registry, b"ActionX".to_string()));

    package_registry::remove_for_testing(&mut registry, b"PkgA".to_string());

    // Action types must be freed
    assert!(!package_registry::has_action_type(&registry, b"ActionX".to_string()));
    assert!(!package_registry::has_action_type(&registry, b"ActionY".to_string()));

    // Re-registering the same action types should succeed (not crash)
    package_registry::add_full_for_testing(
        &mut registry,
        b"PkgB".to_string(), @0x2, 1,
        vector[b"ActionX".to_string(), b"ActionY".to_string()],
        b"defi".to_string(), b"desc".to_string(),
    );
    assert!(package_registry::has_action_type(&registry, b"ActionX".to_string()));
    assert!(
        package_registry::get_package_for_action(&registry, b"ActionX".to_string())
            == b"PkgB".to_string(),
    );

    destroy(cap);
    destroy(registry);
    ts::end(scenario);
}

#[test]
fun test_update_package_metadata_replaces_action_type_mappings() {
    let (scenario, mut registry, cap) = setup();

    package_registry::add_package(
        &mut registry, &cap,
        b"PkgA".to_string(), @0x1, 1,
        vector[b"OldAction".to_string()],
        b"core".to_string(), b"old desc".to_string(),
    );

    package_registry::update_package_metadata(
        &mut registry,
        &cap,
        b"PkgA".to_string(),
        vector[b"NewAction".to_string()],
        b"updated".to_string(),
        b"new desc".to_string(),
    );

    assert!(!package_registry::has_action_type(&registry, b"OldAction".to_string()));
    assert!(package_registry::has_action_type(&registry, b"NewAction".to_string()));
    assert!(
        package_registry::get_package_for_action(&registry, b"NewAction".to_string())
            == b"PkgA".to_string(),
    );

    teardown(scenario, registry, cap);
}

#[test]
#[expected_failure(abort_code = package_registry::EActionTypeAlreadyRegistered)]
fun test_update_package_metadata_rejects_action_type_owned_by_other_package() {
    let (scenario, mut registry, cap) = setup();

    package_registry::add_package(
        &mut registry, &cap,
        b"PkgA".to_string(), @0x1, 1,
        vector[b"ActionA".to_string()],
        b"core".to_string(), b"".to_string(),
    );
    package_registry::add_package(
        &mut registry, &cap,
        b"PkgB".to_string(), @0x2, 1,
        vector[b"ActionB".to_string()],
        b"core".to_string(), b"".to_string(),
    );

    package_registry::update_package_metadata(
        &mut registry,
        &cap,
        b"PkgA".to_string(),
        vector[b"ActionB".to_string()],
        b"updated".to_string(),
        b"collision".to_string(),
    );

    teardown(scenario, registry, cap);
}

// ============================================================
// === Error Cases ===
// ============================================================

#[test]
#[expected_failure(abort_code = package_registry::EPackageAlreadyExists)]
fun test_error_add_duplicate_package_name() {
    let (scenario, mut registry, cap) = setup();

    package_registry::add_package(
        &mut registry, &cap,
        b"PkgA".to_string(), @0x1, 1,
        vector[], b"core".to_string(), b"".to_string(),
    );
    package_registry::add_package(
        &mut registry, &cap,
        b"PkgA".to_string(), @0x2, 1,
        vector[], b"core".to_string(), b"".to_string(),
    );

    teardown(scenario, registry, cap);
}

#[test]
#[expected_failure(abort_code = package_registry::EPackageAlreadyExists)]
fun test_error_add_duplicate_addr() {
    let (scenario, mut registry, cap) = setup();

    package_registry::add_package(
        &mut registry, &cap,
        b"PkgA".to_string(), @0x1, 1,
        vector[], b"core".to_string(), b"".to_string(),
    );
    package_registry::add_package(
        &mut registry, &cap,
        b"PkgB".to_string(), @0x1, 1,
        vector[], b"core".to_string(), b"".to_string(),
    );

    teardown(scenario, registry, cap);
}

#[test]
#[expected_failure(abort_code = package_registry::EActionTypeAlreadyRegistered)]
fun test_error_add_duplicate_action_type() {
    let (scenario, mut registry, cap) = setup();

    package_registry::add_package(
        &mut registry, &cap,
        b"PkgA".to_string(), @0x1, 1,
        vector[b"ActionX".to_string()],
        b"core".to_string(), b"".to_string(),
    );
    package_registry::add_package(
        &mut registry, &cap,
        b"PkgB".to_string(), @0x2, 1,
        vector[b"ActionX".to_string()],
        b"core".to_string(), b"".to_string(),
    );

    teardown(scenario, registry, cap);
}

#[test]
#[expected_failure(abort_code = package_registry::EDuplicateActionTypeInInput)]
fun test_error_add_package_duplicate_action_in_input() {
    let (scenario, mut registry, cap) = setup();

    package_registry::add_package(
        &mut registry, &cap,
        b"PkgA".to_string(), @0x1, 1,
        vector[b"Same".to_string(), b"Same".to_string()],
        b"core".to_string(), b"".to_string(),
    );

    teardown(scenario, registry, cap);
}

// ============================================================
// === is_valid_package Edge Cases ===
// ============================================================

#[test]
fun test_is_valid_package_wrong_version() {
    let (scenario, mut registry, cap) = setup();

    package_registry::add_package(
        &mut registry, &cap,
        b"PkgA".to_string(), @0x1, 1,
        vector[], b"core".to_string(), b"".to_string(),
    );

    assert!(!package_registry::is_valid_package(&registry, b"PkgA".to_string(), @0x1, 99));

    teardown(scenario, registry, cap);
}

#[test]
fun test_is_valid_package_nonexistent_name() {
    let (scenario, registry, cap) = setup();

    assert!(!package_registry::is_valid_package(&registry, b"Nope".to_string(), @0x1, 1));

    teardown(scenario, registry, cap);
}
