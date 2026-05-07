#[test_only]
module account_protocol::package_registry_cap_binding_tests;

use account_protocol::package_registry::{Self as package_registry, PackageAdminCap, PackageRegistry};
use sui::test_scenario as ts;
use sui::test_utils::destroy;

const OWNER: address = @0xA;

#[test]
fun test_admin_cap_bound_to_registry_succeeds() {
    let mut scenario = ts::begin(OWNER);
    let ctx = ts::ctx(&mut scenario);

    let mut registry: PackageRegistry = package_registry::new_for_testing(ctx);
    let cap: PackageAdminCap = package_registry::new_admin_cap_for_testing(&registry, ctx);

    package_registry::add_package(
        &mut registry,
        &cap,
        b"PkgA".to_string(),
        @0x101,
        1,
        vector[b"ActionA".to_string()],
        b"core".to_string(),
        b"test package".to_string(),
    );
    assert!(package_registry::has_package(&registry, b"PkgA".to_string()), 0);

    destroy(cap);
    destroy(registry);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = package_registry::ERegistryCapMismatch)]
fun test_admin_cap_registry_mismatch_fails() {
    let mut scenario = ts::begin(OWNER);
    let ctx = ts::ctx(&mut scenario);

    let mut registry_a: PackageRegistry = package_registry::new_for_testing(ctx);
    let registry_b: PackageRegistry = package_registry::new_for_testing(ctx);
    let cap_b: PackageAdminCap = package_registry::new_admin_cap_for_testing(&registry_b, ctx);

    package_registry::add_package(
        &mut registry_a,
        &cap_b,
        b"PkgA".to_string(),
        @0x101,
        1,
        vector[b"ActionA".to_string()],
        b"core".to_string(),
        b"test package".to_string(),
    );

    destroy(cap_b);
    destroy(registry_b);
    destroy(registry_a);
    ts::end(scenario);
}
