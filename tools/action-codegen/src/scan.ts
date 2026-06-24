#!/usr/bin/env node
/**
 * Move Function Scanner CLI
 *
 * Scans Move functions and generates action schema JSON files.
 *
 * Usage:
 *   npx tsx src/scan.ts <file.move> <function_name> [--id <action_id>]
 *   npx tsx src/scan.ts <file.move> --list     (list all functions)
 *   npx tsx src/scan.ts <file.move> --all       (scan all public functions)
 */

import * as fs from 'node:fs';
import * as path from 'node:path';
import { scanAndGenerate, listFunctions, parseFunction } from './scan-move.js';

function main(): void {
  const args = process.argv.slice(2);

  if (args.length < 2) {
    console.error('Usage: npx tsx src/scan.ts <file.move> <function_name> [--id <action_id>]');
    console.error('       npx tsx src/scan.ts <file.move> --list');
    console.error('       npx tsx src/scan.ts <file.move> --all');
    process.exit(1);
  }

  const moveFile = path.resolve(args[0]);
  if (!fs.existsSync(moveFile)) {
    console.error(`File not found: ${moveFile}`);
    process.exit(1);
  }

  const source = fs.readFileSync(moveFile, 'utf-8');

  // --list mode
  if (args[1] === '--list') {
    const funcs = listFunctions(source);
    console.log(`Functions in ${path.basename(moveFile)}:`);
    for (const f of funcs) {
      const parsed = parseFunction(source, f);
      const vis = parsed?.visibility ?? '?';
      console.log(`  ${vis.padEnd(16)} ${f}`);
    }
    return;
  }

  // --all mode: scan every public/entry function
  if (args[1] === '--all') {
    const funcs = listFunctions(source);
    const CODEGEN_DIR = path.dirname(path.dirname(new URL(import.meta.url).pathname));
    let scanned = 0;

    for (const funcName of funcs) {
      const parsed = parseFunction(source, funcName);
      if (!parsed) {
        console.error(`Failed to parse function: ${funcName}`);
        process.exit(1);
      }

      // Skip non-public functions silently
      if (parsed.visibility === 'private' || parsed.visibility === 'public(package)') {
        continue;
      }

      const result = scanAndGenerate(moveFile, funcName);
      const outFile = path.join(CODEGEN_DIR, 'actions', `${result.schema.id}.json`);
      fs.writeFileSync(outFile, JSON.stringify(result.schema, null, 2) + '\n');
      console.log(`  ${funcName} → ${result.schema.id}.json`);
      scanned++;
    }

    console.log(`\nScanned ${scanned} public functions`);
    return;
  }

  // Single function mode
  const funcName = args[1];
  const idFlag = args.indexOf('--id');
  const actionId = idFlag >= 0 ? args[idFlag + 1] : undefined;

  try {
    const result = scanAndGenerate(moveFile, funcName, actionId);

    console.log(`Scanned: ${result.module.packageName}::${result.module.moduleName}::${result.func.name}`);
    console.log(`Package address: ${result.module.packageAddr}`);
    console.log(`Visibility: ${result.func.visibility}`);
    console.log(`Type params: ${result.func.typeParams.map((t) => t.name).join(', ') || '(none)'}`);
    console.log(`Params: ${result.func.params.length}`);
    console.log(`Return: ${result.func.returnType ?? '(none)'}`);
    console.log('');

    if (result.warnings.length > 0) {
      console.log('Warnings:');
      for (const w of result.warnings) {
        console.log(`  - ${w}`);
      }
      console.log('');
    }

    const CODEGEN_DIR = path.dirname(path.dirname(new URL(import.meta.url).pathname));
    const outFile = path.join(CODEGEN_DIR, 'actions', `${result.schema.id}.json`);
    fs.writeFileSync(outFile, JSON.stringify(result.schema, null, 2) + '\n');
    console.log(`Schema written: ${path.relative(process.cwd(), outFile)}`);
    console.log('');
    console.log('Next: generate the code:');
    console.log(`  ./scripts/codegen_action.sh ${result.schema.id}`);
  } catch (err) {
    console.error(`Error: ${(err as Error).message}`);
    process.exit(1);
  }
}

main();
