// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

// Portions of this file are derived from the account.tech Move Framework project.
// Those portions remain licensed under the Apache License, Version 2.0.

/// [Intent Interface] - Functions to create intents and add actions to them.

module account_protocol::intent_interface;

use account_protocol::account::{Self, Account};
use account_protocol::intents::{PendingIntent, Params};
use account_protocol::version_witness::VersionWitness;

// === Imports ===

// === Public functions ===

/// Example implementation:
///
/// ```move
///
/// public fun request_intent_name<Config: store, Outcome: store>(
///     auth: Auth,
///     account: &mut Account,
///     registry: &PackageRegistry,
///     params: Params,
///     outcome: Outcome,
///     action1: Action1,
///     action2: Action2,
///     ctx: &mut TxContext
/// ) {
///     account.verify(auth);
///     params.assert_single_execution(); // if not a recurring intent
///
///     account.build_intent!(
///         registry,
///         params,
///         outcome,
///         version::current(),
///         IntentWitness(),
///         ctx,
///         |intent, iw| {
///             intent.add_action(action1, iw);
///             intent.add_action(action2, iw);
///         }
///     );
/// }
///
/// ```

/// Creates an intent with actions and adds it to an unshared account.
/// For shared accounts, config modules should call account::insert_intent directly
/// with their config witness wrapper.
public macro fun build_intent<$Config: store, $Outcome, $IW: copy + drop>(
    $account: &mut Account,
    $registry: &account_protocol::package_registry::PackageRegistry,
    $params: Params,
    $outcome: $Outcome,
    $version_witness: VersionWitness,
    $intent_witness: $IW,
    $ctx: &mut TxContext,
    $new_actions: |&mut PendingIntent<$Outcome>, $IW|,
) {
    let mut intent = account::create_intent(
        $account,
        $registry,
        $params,
        $outcome,
        $version_witness,
        $intent_witness,
        $ctx,
    );

    $new_actions(&mut intent, $intent_witness);

    account::insert_intent_unshared($account, $registry, intent, $version_witness, $intent_witness);
}
