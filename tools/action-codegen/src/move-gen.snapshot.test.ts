import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import { generateExecution, generateInitActions } from './move-gen.js';
import { validateSchema, type ActionSchema } from './parse-schema.js';
import { scanAndGenerate } from './scan-move.js';

const actionsDir = path.join(path.dirname(path.dirname(new URL(import.meta.url).pathname)), 'actions');
const expectedMoveOutputHash = '188a4d1783fb7b647b1db7a834cedcb5db981ac603636418fef087325ac19d02';

function loadSchemas(): Array<{ file: string; schema: ActionSchema }> {
  return fs
    .readdirSync(actionsDir)
    .filter((file) => file.endsWith('.json'))
    .sort()
    .map((file) => ({
      file,
      schema: validateSchema(JSON.parse(fs.readFileSync(path.join(actionsDir, file), 'utf8'))),
    }));
}

const snapshots = loadSchemas().flatMap(({ file, schema }) => [
  `### ${file} init\n${generateInitActions(schema)}`,
  `### ${file} exec\n${generateExecution(schema)}`,
]);

assert.ok(snapshots.length > 0, 'expected action schemas to snapshot');
assert.equal(
  crypto.createHash('sha256').update(snapshots.join('\n\n')).digest('hex'),
  expectedMoveOutputHash,
);

const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'govex-codegen-'));
fs.writeFileSync(
  path.join(tmpDir, 'Move.toml'),
  [
    '[package]',
    'name = "ThirdParty"',
    'version = "0.0.1"',
    '',
    '[addresses]',
    'test_pkg = "0x0"',
    'other_pkg = "0x0"',
    '',
  ].join('\n'),
);
const sourcesDir = path.join(tmpDir, 'sources');
fs.mkdirSync(sourcesDir);
const moveFile = path.join(sourcesDir, 'router.move');
fs.writeFileSync(
  moveFile,
  [
    'module test_pkg::router;',
    'use other_pkg::caps::{',
    '    Cap as AdminCap,',
    '};',
    'use other_pkg::coin::MY_COIN as LocalCoin;',
    'use other_pkg::pool;',
    '',
    'public fun deposit_approved<Config: store, CoinType>(',
    '    account: &mut Account,',
    '    registry: &PackageRegistry,',
    '    coin: Coin<LocalCoin>,',
    '    pool_obj: &pool::Pool<CoinType>,',
    '    cap: &mut AdminCap,',
    '    amount: u64,',
    '    ctx: &mut TxContext,',
    '): Coin<LocalCoin> {',
    '    coin',
    '}',
    '',
    'public fun reserved<Outcome>(amount: u64) {',
    '    let _ = amount;',
    '}',
    '',
  ].join('\n'),
);

const scan = scanAndGenerate(moveFile, 'deposit_approved', 'deposit_approved');
assert.deepEqual(scan.warnings, []);
assert.equal(scan.schema.execution.needsAccount, true);
assert.equal(scan.schema.execution.needsRegistry, true);
assert.equal(scan.schema.execution.needsCtx, true);
assert.deepEqual(scan.schema.marker.phantomTypes, ['CoinType']);
assert.deepEqual(scan.schema.wrappedCall?.typeParams, ['Config', 'CoinType']);
assert.deepEqual(
  scan.schema.wrappedCall?.args.map((arg) => arg.source),
  ['account', 'registry', 'resource_in_coin', 'external_object', 'external_object', 'bcs_field', 'ctx'],
);
assert.deepEqual(
  scan.schema.execution.externalObjects?.map((obj) => [obj.name, obj.type]),
  [
    ['pool_obj', 'other_pkg::pool::Pool<CoinType>'],
    ['cap', 'other_pkg::caps::Cap'],
  ],
);
assert.equal(
  scan.schema.fields.find((field) => field.name === 'coin_resource')?.moveType,
  'Coin<other_pkg::coin::MY_COIN>',
);
assert.equal(
  scan.schema.fields.find((field) => field.name === 'resource_out')?.moveType,
  'Coin<other_pkg::coin::MY_COIN>',
);

const scannedExecution = generateExecution(validateSchema(scan.schema));
assert.match(
  scannedExecution,
  /public fun do_init_deposit_approved<Config: store, Outcome: store, CoinType, IW: drop>/,
);
assert.doesNotMatch(scannedExecution, /Config: store, Outcome: store, Config/);
assert.match(scannedExecution, /use sui::tx_context::TxContext;/);
assert.match(
  scannedExecution,
  /let coin: sui::coin::Coin<other_pkg::coin::MY_COIN> = executable_resources::take_coin/,
);
assert.match(scannedExecution, /let call_result = test_pkg::router::deposit_approved<Config, CoinType>\(/);
assert.match(scannedExecution, /        account,\n        registry,\n        coin,\n        pool_obj,\n        cap,\n        amount,\n        ctx,/);
assert.throws(
  () => scanAndGenerate(moveFile, 'reserved', 'reserved'),
  /reserved wrapper type parameter\(s\): Outcome/,
);
