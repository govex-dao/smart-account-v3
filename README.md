# Smart Account

A smart account implementation with a two-step intent/action pattern.

Accounts expose a generic interface for orchestration packages. [Multisig](https://github.com/govex-dao/multisig-v3) and [Decision Markets](https://github.com/govex-dao/decision-markets-v3) are two such implementations.

Internal account actions run as a self contained kernel. To call third-party packages, generate and deploy new typed action packages.

Accounts can run in one of three authorization modes: `GLOBAL_ONLY`, where they may only use built-in account actions and the append-only admin-controlled global registry of actions; `WHITELIST`, where they may also use actions from their own per-account registry; and `PERMISSIVE`, where they may stage and execute any action.

## Actions

- Transfer: `transfer_object`, `transfer_to_sender`, `transfer_coin`, `transfer_coin_to_sender`, `withdraw_object`, `provide_object`
- Vault: `open_vault`, `close_vault`, `deposit`, `spend`, `deposit_external`, `deposit_from_resources`, `deposit_object_from_resources`, `approve_coin_type`, `remove_approved_coin_type`, `mint_vault_admin_cap`
- Streams and vesting: `create_stream`, `collect_stream`, `cancel_stream`, `create_vesting`, `cancel_vesting`
- Currency: `mint`, `burn`, `mint_currency_admin_cap`, `remove_treasury_cap_to_resources`, `remove_metadata_cap_to_resources`, `update_currency`, `lock_treasury_cap`, `lock_metadata_cap`
- Access and config: `lock_access`, `unlock_access`, `set_authorization_level`, `add_dep`, `remove_dep`
- Package upgrades: `lock_upgrade_cap`, `unlock_upgrade_cap`, `upgrade_package`, `commit_upgrade`, `restrict_upgrade`
- Memo: `memo`

| Package name | Mainnet package ID |
|---|---|
| `AccountProtocol` | `0x0f6ef484a0867ccffe219fa1f4648e58f8c3fd04a4ddcfb318a27f9cc6d2f3d9` |
| `AccountActions` | `0xaa682664f419d51af5071ed0449dffbcf3a417fd12961d916b1a433542e9478d` |
