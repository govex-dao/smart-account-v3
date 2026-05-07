#[test_only]
module account_actions::init_action_pattern_tests;

use account_actions::access_control;
use account_actions::access_control_init_actions;
use account_actions::action_spec_builder;
use account_actions::config_init_actions;
use account_actions::currency;
use account_actions::currency_init_actions;
use account_actions::memo;
use account_actions::memo_init_actions;
use account_actions::owned_init_actions;
use account_actions::package_upgrade;
use account_actions::package_upgrade_init_actions;
use account_actions::stream_init_actions;
use account_actions::transfer;
use account_actions::transfer_init_actions;
use account_actions::vault;
use account_actions::vault_init_actions;
use account_actions::vesting;
use account_actions::vesting_init_actions;
use account_protocol::bcs_validation;
use account_protocol::intents;
use std::string::{Self, String};
use std::type_name;
use sui::bcs;
use sui::package;
use sui::sui::SUI;

public struct DummyCap has copy, drop, store {}

fun marker_name<T>(): String {
    type_name::with_original_ids<T>().into_string().to_string()
}

fun string_of_len(len: u64): String {
    let mut bytes = vector[];
    let mut i = 0;
    while (i < len) {
        bytes.push_back(0x61);
        i = i + 1;
    };
    string::utf8(bytes)
}

#[test]
fun test_all_init_spec_builders_use_marker_and_version_pattern() {
    let mut builder = action_spec_builder::new_for_testing();
    let mut expected_types = vector::empty<String>();

    // Config specs
    config_init_actions::add_set_authorization_level_spec(&mut builder, 2);
    expected_types.push_back(marker_name<account_protocol::config::ConfigSetAuthorizationLevel>());
    config_init_actions::add_add_dep_spec(&mut builder, @0x101, b"dep_pkg".to_string(), 7);
    expected_types.push_back(marker_name<account_protocol::config::ConfigAddDep>());
    config_init_actions::add_remove_dep_spec(&mut builder, @0x101);
    expected_types.push_back(marker_name<account_protocol::config::ConfigRemoveDep>());

    // Access control specs
    access_control_init_actions::add_lock_spec<DummyCap>(&mut builder, object::id_from_address(@0xCAFE), b"cap".to_string());
    expected_types.push_back(marker_name<access_control::AccessControlLock<DummyCap>>());
    access_control_init_actions::add_unlock_to_resources_spec<DummyCap>(
        &mut builder,
        object::id_from_address(@0xCAFE),
        b"cap_out".to_string(),
    );
    expected_types.push_back(marker_name<access_control::AccessControlUnlockToResources<DummyCap>>());

    // Memo specs
    memo_init_actions::add_emit_memo_spec(&mut builder, b"hello".to_string());
    expected_types.push_back(marker_name<memo::Memo>());

    // Provide object to resources (PTB-level deposit)
    owned_init_actions::add_provide_object_spec<package::UpgradeCap>(
        &mut builder,
        object::id_from_address(@0xBEEF),
        b"ptb_resource".to_string(),
    );
    expected_types.push_back(marker_name<account_protocol::owned::ProvideObjectToResources<package::UpgradeCap>>());

    // Producer needed before transfer object specs (resource reference check)
    owned_init_actions::add_withdraw_object_spec<package::UpgradeCap>(
        &mut builder,
        object::id_from_address(@0xAAA),
        b"obj_resource".to_string(),
    );
    expected_types.push_back(marker_name<account_protocol::owned::OwnedWithdrawObject<package::UpgradeCap>>());
    transfer_init_actions::add_transfer_object_spec<package::UpgradeCap>(
        &mut builder,
        @0xC0DE,
        b"obj_resource".to_string(),
    );
    expected_types.push_back(marker_name<transfer::TransferObject<package::UpgradeCap>>());
    transfer_init_actions::add_transfer_to_sender_spec<package::UpgradeCap>(
        &mut builder,
        b"obj_resource".to_string(),
    );
    expected_types.push_back(marker_name<transfer::TransferToSender<package::UpgradeCap>>());

    // Vault specs
    vault_init_actions::add_deposit_spec<SUI>(
        &mut builder,
        b"treasury".to_string(),
        10,
        b"seed_coin".to_string(),
    );
    expected_types.push_back(marker_name<vault::VaultDeposit<SUI>>());
    vault_init_actions::add_spend_spec<SUI>(
        &mut builder,
        b"treasury".to_string(),
        25,
        false,
        b"coin_resource".to_string(),
    );
    expected_types.push_back(marker_name<vault::VaultSpend<SUI>>());
    vault_init_actions::add_cancel_stream_spec<SUI>(
        &mut builder,
        b"treasury".to_string(),
        object::id_from_address(@0x777),
    );
    expected_types.push_back(marker_name<vault::CancelStream<SUI>>());
    vault_init_actions::add_deposit_external_spec<SUI>(&mut builder, b"treasury".to_string(), 33);
    expected_types.push_back(marker_name<vault::VaultDepositExternal<SUI>>());
    vault_init_actions::add_deposit_from_resources_spec<SUI>(
        &mut builder,
        b"treasury".to_string(),
        b"coin_resource".to_string(),
    );
    expected_types.push_back(marker_name<vault::VaultDepositFromResources<SUI>>());
    vault_init_actions::add_deposit_object_from_resources_spec<SUI>(
        &mut builder,
        b"treasury".to_string(),
        b"coin_object".to_string(),
    );
    expected_types.push_back(marker_name<vault::VaultDepositObjectFromResources<SUI>>());
    vault_init_actions::add_open_vault_spec(&mut builder, b"ops".to_string());
    expected_types.push_back(marker_name<vault::VaultOpen>());
    vault_init_actions::add_approve_coin_type_spec<SUI>(&mut builder, b"ops".to_string());
    expected_types.push_back(marker_name<vault::VaultApproveCoinType<SUI>>());
    vault_init_actions::add_remove_approved_coin_type_spec<SUI>(&mut builder, b"ops".to_string());
    expected_types.push_back(marker_name<vault::VaultRemoveApprovedCoinType<SUI>>());
    vault_init_actions::add_close_vault_spec(&mut builder, b"ops".to_string());
    expected_types.push_back(marker_name<vault::VaultClose>());
    vault_init_actions::add_mint_vault_admin_cap_spec(
        &mut builder,
        b"ops".to_string(),
        b"vault_cap".to_string(),
    );
    expected_types.push_back(marker_name<vault::MintVaultAdminCap>());

    // Transfer coin specs (resource reference provided by prior VaultSpend)
    transfer_init_actions::add_transfer_coin_spec<SUI>(
        &mut builder,
        @0xFACE,
        b"coin_resource".to_string(),
    );
    expected_types.push_back(marker_name<transfer::TransferCoin<SUI>>());
    transfer_init_actions::add_transfer_coin_to_sender_spec<SUI>(
        &mut builder,
        b"coin_resource".to_string(),
    );
    expected_types.push_back(marker_name<transfer::TransferCoinToSender<SUI>>());

    // Stream and vesting specs
    stream_init_actions::add_create_stream_spec<SUI>(
        &mut builder,
        b"treasury".to_string(),
        @0xD00D,
        5,
        option::some(1_000),
        3,
        10_000,
        option::none(),
        option::none(),
        vector::empty(),
    );
    expected_types.push_back(marker_name<vault::CreateStream<SUI>>());
    vesting_init_actions::add_create_vesting_spec<SUI>(
        &mut builder,
        @0xABCD,
        4,
        option::some(1_000),
        3,
        10_000,
        true,
        b"vesting_resource".to_string(),
    );
    expected_types.push_back(marker_name<vesting::CreateVesting<SUI>>());
    vesting_init_actions::add_cancel_vesting_spec<SUI>(
        &mut builder,
        @0xABCD,
        b"vesting_refund".to_string(),
    );
    expected_types.push_back(marker_name<vesting::CancelVesting<SUI>>());

    // Currency specs
    currency_init_actions::add_remove_treasury_cap_to_resources_spec<SUI>(
        &mut builder,
        object::id_from_address(@0xAAA1),
        b"treasury_cap".to_string(),
    );
    expected_types.push_back(marker_name<currency::RemoveTreasuryCapToResources<SUI>>());
    currency_init_actions::add_remove_metadata_cap_to_resources_spec<SUI>(
        &mut builder,
        object::id_from_address(@0xAAA2),
        b"metadata_cap".to_string(),
    );
    expected_types.push_back(marker_name<currency::RemoveMetadataCapToResources<SUI>>());
    currency_init_actions::add_mint_spec<SUI>(&mut builder, 123, b"minted".to_string());
    expected_types.push_back(marker_name<currency::CurrencyMint<SUI>>());
    currency_init_actions::add_mint_currency_admin_cap_spec<SUI>(&mut builder, b"mint_cap".to_string());
    expected_types.push_back(marker_name<currency::MintCurrencyAdminCap<SUI>>());
    currency_init_actions::add_burn_spec<SUI>(&mut builder, 7, b"minted".to_string());
    expected_types.push_back(marker_name<currency::CurrencyBurn<SUI>>());
    currency_init_actions::add_update_spec<SUI>(
        &mut builder,
        option::none(),
        option::some(b"Govex"),
        option::some(b"Govex test token"),
        option::some(b"https://example.com/icon.png"),
    );
    expected_types.push_back(marker_name<currency::CurrencyUpdate<SUI>>());
    currency_init_actions::add_lock_treasury_cap_spec<SUI>(&mut builder, option::some(1_000_000), true, true, true, true, true, b"treasury_cap".to_string());
    expected_types.push_back(marker_name<currency::LockTreasuryCap<SUI>>());
    currency_init_actions::add_lock_metadata_cap_spec<SUI>(&mut builder, true, true, true, b"metadata_cap".to_string());
    expected_types.push_back(marker_name<currency::LockMetadataCap<SUI>>());

    // Package upgrade specs
    package_upgrade_init_actions::add_upgrade_spec(
        &mut builder,
        b"govex_pkg".to_string(),
        vector[1, 2, 3, 4],
        object::id_from_address(@0xCAFE),
    );
    expected_types.push_back(marker_name<package_upgrade::PackageUpgrade>());
    package_upgrade_init_actions::add_commit_spec(
        &mut builder,
        b"govex_pkg".to_string(),
        object::id_from_address(@0xCAFE),
    );
    expected_types.push_back(marker_name<package_upgrade::PackageCommit>());
    package_upgrade_init_actions::add_restrict_spec(
        &mut builder,
        b"govex_pkg".to_string(),
        package::dep_only_policy(),
        object::id_from_address(@0xCAFE),
    );
    expected_types.push_back(marker_name<package_upgrade::PackageRestrict>());
    package_upgrade_init_actions::add_unlock_upgrade_cap_spec(
        &mut builder,
        b"govex_pkg".to_string(),
        b"upgrade_cap".to_string(),
        object::id_from_address(@0xCAFE),
    );
    expected_types.push_back(marker_name<package_upgrade::UnlockUpgradeCap>());
    package_upgrade_init_actions::add_upgrade_and_commit_specs(
        &mut builder,
        b"govex_pkg_2".to_string(),
        vector[9, 8, 7],
        object::id_from_address(@0xD00D),
    );
    expected_types.push_back(marker_name<package_upgrade::PackageUpgrade>());
    expected_types.push_back(marker_name<package_upgrade::PackageCommit>());

    let specs = action_spec_builder::into_vector(builder);
    assert!(vector::length(&specs) == vector::length(&expected_types), 0);

    let mut i = 0;
    while (i < vector::length(&specs)) {
        let spec = vector::borrow(&specs, i);
        assert!(intents::action_spec_version(spec) == 1, 1000 + i);
        let actual = intents::action_spec_type(spec).into_string().to_string();
        assert!(actual == *vector::borrow(&expected_types, i), 2000 + i);
        i = i + 1;
    };
}

#[test]
fun test_package_upgrade_init_specs_encode_expected_payloads() {
    let mut builder = action_spec_builder::new_for_testing();
    package_upgrade_init_actions::add_upgrade_spec(
        &mut builder,
        b"govex_pkg".to_string(),
        vector[1, 2, 3, 4],
        object::id_from_address(@0xCAFE),
    );
    package_upgrade_init_actions::add_commit_spec(
        &mut builder,
        b"govex_pkg".to_string(),
        object::id_from_address(@0xCAFE),
    );
    package_upgrade_init_actions::add_restrict_spec(
        &mut builder,
        b"govex_pkg".to_string(),
        package::additive_policy(),
        object::id_from_address(@0xCAFE),
    );
    package_upgrade_init_actions::add_unlock_upgrade_cap_spec(
        &mut builder,
        b"govex_pkg".to_string(),
        b"upgrade_cap".to_string(),
        object::id_from_address(@0xCAFE),
    );

    let specs = action_spec_builder::into_vector(builder);
    assert!(vector::length(&specs) == 4, 0);

    // Upgrade payload: (name, digest, expected_cap_id)
    let upgrade_spec = vector::borrow(&specs, 0);
    assert!(intents::action_spec_type(upgrade_spec) == type_name::with_original_ids<package_upgrade::PackageUpgrade>(), 1);
    let mut reader = bcs::new(*intents::action_spec_data(upgrade_spec));
    let name = string::utf8(bcs::peel_vec_u8(&mut reader));
    let digest = bcs::peel_vec_u8(&mut reader);
    let expected_cap_id = bcs::peel_address(&mut reader);
    bcs_validation::validate_all_bytes_consumed(reader);
    assert!(name == b"govex_pkg".to_string(), 2);
    assert!(digest == vector[1, 2, 3, 4], 3);
    assert!(expected_cap_id == @0xCAFE, 4);

    // Commit payload: (name, expected_cap_id)
    let commit_spec = vector::borrow(&specs, 1);
    assert!(intents::action_spec_type(commit_spec) == type_name::with_original_ids<package_upgrade::PackageCommit>(), 5);
    let mut reader = bcs::new(*intents::action_spec_data(commit_spec));
    let name = string::utf8(bcs::peel_vec_u8(&mut reader));
    let expected_cap_id = bcs::peel_address(&mut reader);
    bcs_validation::validate_all_bytes_consumed(reader);
    assert!(name == b"govex_pkg".to_string(), 6);
    assert!(expected_cap_id == @0xCAFE, 7);

    // Restrict payload: (name, policy, expected_cap_id)
    let restrict_spec = vector::borrow(&specs, 2);
    assert!(intents::action_spec_type(restrict_spec) == type_name::with_original_ids<package_upgrade::PackageRestrict>(), 8);
    let mut reader = bcs::new(*intents::action_spec_data(restrict_spec));
    let name = string::utf8(bcs::peel_vec_u8(&mut reader));
    let policy = bcs::peel_u8(&mut reader);
    let expected_cap_id = bcs::peel_address(&mut reader);
    bcs_validation::validate_all_bytes_consumed(reader);
    assert!(name == b"govex_pkg".to_string(), 9);
    assert!(policy == package::additive_policy(), 10);
    assert!(expected_cap_id == @0xCAFE, 11);

    // Unlock payload: (name, resource_name, expected_cap_id)
    let unlock_spec = vector::borrow(&specs, 3);
    assert!(intents::action_spec_type(unlock_spec) == type_name::with_original_ids<package_upgrade::UnlockUpgradeCap>(), 12);
    let mut reader = bcs::new(*intents::action_spec_data(unlock_spec));
    let name = string::utf8(bcs::peel_vec_u8(&mut reader));
    let resource_name = string::utf8(bcs::peel_vec_u8(&mut reader));
    let expected_cap_id = bcs::peel_address(&mut reader);
    bcs_validation::validate_all_bytes_consumed(reader);
    assert!(name == b"govex_pkg".to_string(), 13);
    assert!(resource_name == b"upgrade_cap".to_string(), 14);
    assert!(expected_cap_id == @0xCAFE, 15);
}

#[test]
#[expected_failure]
fun test_lock_treasury_cap_spec_rejects_invalid_utf8_resource_name() {
    let mut builder = action_spec_builder::new_for_testing();
    let invalid_resource_name = string::utf8(vector[0xff]);
    currency_init_actions::add_lock_treasury_cap_spec<SUI>(
        &mut builder,
        option::some(1_000_000),
        true,
        true,
        true,
        true,
        true,
        invalid_resource_name,
    );
}

#[test]
#[expected_failure]
fun test_lock_metadata_cap_spec_rejects_invalid_utf8_resource_name() {
    let mut builder = action_spec_builder::new_for_testing();
    let invalid_resource_name = string::utf8(vector[0xff]);
    currency_init_actions::add_lock_metadata_cap_spec<SUI>(
        &mut builder,
        true,
        true,
        true,
        invalid_resource_name,
    );
}

#[test]
fun test_lock_cap_spec_accepts_256_byte_resource_name() {
    let mut builder = action_spec_builder::new_for_testing();
    let resource_name = string_of_len(256);
    currency_init_actions::add_lock_metadata_cap_spec<SUI>(
        &mut builder,
        true,
        true,
        true,
        resource_name,
    );
}

#[test, expected_failure(abort_code = currency_init_actions::EEmptyResourceName, location = account_actions::currency_init_actions)]
fun test_lock_treasury_cap_spec_rejects_empty_resource_name() {
    let mut builder = action_spec_builder::new_for_testing();
    currency_init_actions::add_lock_treasury_cap_spec<SUI>(
        &mut builder,
        option::some(1_000_000),
        true,
        true,
        true,
        true,
        true,
        b"".to_string(),
    );
}

#[test, expected_failure(abort_code = currency_init_actions::EEmptyResourceName, location = account_actions::currency_init_actions)]
fun test_lock_metadata_cap_spec_rejects_empty_resource_name() {
    let mut builder = action_spec_builder::new_for_testing();
    currency_init_actions::add_lock_metadata_cap_spec<SUI>(
        &mut builder,
        true,
        true,
        true,
        b"".to_string(),
    );
}

#[test, expected_failure(abort_code = currency_init_actions::EResourceNameTooLong, location = account_actions::currency_init_actions)]
fun test_lock_treasury_cap_spec_rejects_over_256_byte_resource_name() {
    let mut builder = action_spec_builder::new_for_testing();
    let resource_name = string_of_len(257);
    currency_init_actions::add_lock_treasury_cap_spec<SUI>(
        &mut builder,
        option::some(1_000_000),
        true,
        true,
        true,
        true,
        true,
        resource_name,
    );
}

#[test, expected_failure(abort_code = currency_init_actions::EResourceNameTooLong, location = account_actions::currency_init_actions)]
fun test_lock_metadata_cap_spec_rejects_over_256_byte_resource_name() {
    let mut builder = action_spec_builder::new_for_testing();
    let resource_name = string_of_len(257);
    currency_init_actions::add_lock_metadata_cap_spec<SUI>(
        &mut builder,
        true,
        true,
        true,
        resource_name,
    );
}

#[test, expected_failure(abort_code = package_upgrade_init_actions::EEmptyPackageName)]
fun test_package_upgrade_init_rejects_empty_name() {
    let mut builder = action_spec_builder::new_for_testing();
    package_upgrade_init_actions::add_upgrade_spec(
        &mut builder,
        b"".to_string(),
        vector[1],
        object::id_from_address(@0x1),
    );
}

#[test, expected_failure(abort_code = package_upgrade_init_actions::EInvalidPolicy)]
fun test_package_upgrade_init_rejects_invalid_policy() {
    let mut builder = action_spec_builder::new_for_testing();
    package_upgrade_init_actions::add_restrict_spec(
        &mut builder,
        b"govex_pkg".to_string(),
        17,
        object::id_from_address(@0x1),
    );
}
