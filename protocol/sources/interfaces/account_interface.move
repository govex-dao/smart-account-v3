// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

// Portions of this file are derived from the account.tech Move Framework project.
// Those portions remain licensed under the Apache License, Version 2.0.

/// [Account Interface] - High level functions to create required "methods" for the account.
///
/// 1. Define a new Account type with a specific config and default dependencies.
/// 2. Define a mechanism to authenticate an address to grant permission to call certain functions.

module account_protocol::account_interface;

use account_protocol::account::{Self, Account, Auth};
use account_protocol::deps::Deps;
use account_protocol::metadata::Metadata;

// === Imports ===

// === Public functions ===

/// Example implementation:
///
/// ```move
///
/// public struct Witness() has drop;
///
/// public fun new_account(
///     registry: &PackageRegistry,
///     ctx: &mut TxContext,
/// ): Account {
///     let config = Config {
///        .. <FIELDS>
///     };
///
///     create_account!(
///        config,
///        metadata::empty(),
///        Witness(),
///        ctx,
///        || deps::new(registry, false) // false = unverified_allowed
///     )
/// }
///
/// ```

/// Returns a new Account object with a specific config and initialize dependencies.
public macro fun create_account<$Config: store, $CW: drop>(
    $config: $Config,
    $metadata: Metadata,
    $config_witness: $CW,
    $ctx: &mut TxContext,
    $init_deps: || -> Deps,
): Account {
    let deps = $init_deps();
    account::new<$Config, $CW>($config, $metadata, deps, $config_witness, $ctx)
}

/// Example implementation:
///
/// ```move
///
/// public fun authenticate(
///     account: &Account,
///     ctx: &TxContext
/// ): Auth {
///     authenticate!(
///        account,
///        Witness(),
///        || account.config::<Config>().assert_is_member(ctx)
///     )
/// }
///
/// ```

/// Returns an Auth if the conditions passed are met (used to create intents and more).
public macro fun create_auth<$Config: store, $CW: drop>(
    $account: &Account,
    $config_witness: $CW,
    $grant_permission: ||, // condition to grant permission, must throw if not met
): Auth {
    let account = $account;

    $grant_permission();

    account.new_auth<$Config, $CW>($config_witness)
}
