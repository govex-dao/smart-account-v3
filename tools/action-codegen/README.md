# Smart Account Action Codegen

This tool helps add a typed action to Govex smart accounts from a callable Move function.

It scans a `public fun` or `entry fun`, creates a JSON action schema, and generates:

- Move code for staging the action spec.
- Move code for executing the wrapped function from an approved intent.
- TypeScript SDK snippets for action definitions, transaction composition, and execution.

Generated output is a starting point, not a substitute for review. Before publishing an action, check object and capability sources, package addresses, validation rules, and output handling.

## Quick Start

Run from the `smart-account-v3` repo root:

```bash
npm --prefix tools/action-codegen install

./scripts/generate-action-wrapper.sh --list ./path/to/module.move
./scripts/generate-action-wrapper.sh ./path/to/module.move function_name --id action_id --dry-run
./scripts/generate-action-wrapper.sh ./path/to/module.move function_name --id action_id
```

The script writes schemas to `tools/action-codegen/actions/` and generated code to `tools/action-codegen/output/`.

## Existing Schema

If you already have or edited a schema:

```bash
./scripts/generate-action-wrapper.sh --from-schema action_id --dry-run
./scripts/generate-action-wrapper.sh --from-schema action_id
```

## What The Scanner Infers

| Move signature shape | Generated role |
| --- | --- |
| `u8`, `u64`, `u128`, `bool`, `String`, `address`, `ID` | BCS field stored in the staged `ActionSpec` |
| `Coin<T>` by value | Coin taken from `executable_resources` |
| Non-coin object by value | Object taken from `executable_resources` |
| `&T` or `&mut T` object reference | External object ID stored in the `ActionSpec`, object supplied by the execution PTB |
| `&Clock` | Clock argument |
| `&Account` / `&mut Account` | Smart-account object argument |
| `&PackageRegistry` | Registry argument |
| `&mut TxContext` | Transaction context argument |
| Returned `Coin<T>` | Coin provided back to `executable_resources` |
| Returned object | Object provided back to `executable_resources` |

The scanner rejects `private` and `public(package)` functions because the execution PTB cannot call them.

## Manual Review Checklist

After generation, review:

- Whether every object or capability should come from the account, the execution PTB, or `executable_resources`.
- Whether external objects validate the exact staged object ID.
- Whether amounts, recipients, deadlines, whitelists, and package IDs need additional checks.
- Whether returned coins or objects are stored in `executable_resources` under the expected names.
- Whether generated TypeScript snippets should be exposed in the public frontend.

## Output

| Output | Purpose |
| --- | --- |
| `output/move/init/*_init_actions.move` | Action struct and `add_*_spec` builder |
| `output/move/lib/*.move` | Marker type, execution wrapper, and delete helper |
| `output/ts/*_def.ts` | SDK action definition |
| `output/ts/*_composer.ts` | Transaction-composer staging case |
| `output/ts/*_executor.ts` | Execution PTB case |
| `output/ts/_all_*.ts` | Combined TypeScript snippets |

## Schema Notes

Most generated schemas can be edited before running `--from-schema`.

Useful fields include:

- `marker.phantomTypes`: type parameters carried by the action marker.
- `fields[].role`: resource or external-object role for a staged field.
- `fields[].moveType`: full Move value type for resource fields.
- `execution.typeParamConstraints`: ability constraints for generated wrapper type parameters.
- `wrappedCall`: the Move call target and argument mapping used by generated execution code.

When in doubt, use `--dry-run` and review the full generated Move and TypeScript output before writing files.
