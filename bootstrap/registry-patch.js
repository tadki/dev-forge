'use strict';
// registry-patch.js - declarative settings.json patcher (SEE-1330 P0, SPEC-009)
// Renders the v2 unified-hook registration from hooks-registration.json into a
// user-level settings.json: idempotent merge, atomic write (tmp + rename),
// per-phase v1 disable. Never touches anything outside --settings path.
//
// Usage:
//   node registry-patch.js merge    --settings S --manifest M --global-hooks D [--phase P0]
//   node registry-patch.js verify   --settings S --manifest M --global-hooks D
//   node registry-patch.js rollback --settings S --backup B
// merge prints "changed" / "unchanged" and exits 0.

const fs = require('fs');
const path = require('path');

function parseArgs(argv) {
  const args = {};
  for (let i = 0; i < argv.length; i++) {
    if (argv[i].startsWith('--')) args[argv[i].slice(2)] = argv[i + 1];
  }
  return args;
}

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

function atomicWrite(file, content) {
  const tmp = file + '.tmp.' + process.pid;
  fs.writeFileSync(tmp, content);
  fs.renameSync(tmp, file); // 同文件系统 rename = 原子替换
}

function v2Command(globalHooks, wrapper, point, alias) {
  return `${globalHooks}/${wrapper} ${point} ${alias}`;
}

function commandOf(entry) {
  const hooks = entry && Array.isArray(entry.hooks) ? entry.hooks : [];
  return hooks.map(h => h.command || '').join('|');
}

function merge(settings, manifest, globalHooks, phaseName) {
  const wrapper = manifest.wrapper;
  const alias = manifest.alias;
  const matcher = manifest.matcher;
  const phase = manifest.phases[phaseName || 'P0'];
  if (!phase) throw new Error(`未知 phase: ${phaseName}（manifest phases: ${Object.keys(manifest.phases).join('/')}）`);

  settings.hooks = settings.hooks && typeof settings.hooks === 'object' ? settings.hooks : {};
  let changed = false;

  for (const point of manifest.hook_points) {
    const want = v2Command(globalHooks, wrapper, point, alias);
    const groups = Array.isArray(settings.hooks[point]) ? settings.hooks[point] : [];
    // 幂等：已存在完全一致的 v2 条目则不重复添加
    const existingIdx = groups.findIndex(g => (g.command || commandOf(g)) === want
      || (Array.isArray(g.hooks) && g.hooks.some(h => h.command === want)));
    if (existingIdx >= 0) {
      const g = groups[existingIdx];
      // 收敛：matcher 必须为全匹配声明值
      if (g.matcher !== matcher || !Array.isArray(g.hooks) || g.hooks.length !== 1 || g.hooks[0].command !== want) {
        groups[existingIdx] = { matcher, hooks: [{ type: 'command', command: want }] };
        changed = true;
      }
      continue;
    }
    groups.push({ matcher, hooks: [{ type: 'command', command: want }] });
    settings.hooks[point] = groups;
    changed = true;
  }

  // per-phase v1 禁用：移除命令以 "hook-wrapper.sh <AnyPoint> <alias>" 结尾的条目
  for (const v1alias of (phase.disable_v1 || [])) {
    const re = new RegExp(`hook-wrapper\\.sh \\S+ ${v1alias.replace(/[-]/g, '\\-')}$`);
    for (const point of Object.keys(settings.hooks)) {
      const groups = settings.hooks[point];
      if (!Array.isArray(groups)) continue;
      const filtered = [];
      for (const g of groups) {
        if (!Array.isArray(g.hooks)) { filtered.push(g); continue; }
        const hooks = g.hooks.filter(h => !(h && typeof h.command === 'string' && re.test(h.command)));
        if (hooks.length === 0) { changed = true; continue; } // 整组移除
        if (hooks.length !== g.hooks.length) {
          g.hooks = hooks;
          changed = true;
        }
        filtered.push(g);
      }
      settings.hooks[point] = filtered;
    }
  }
  return changed;
}

function verify(settings, manifest, globalHooks) {
  for (const point of manifest.hook_points) {
    const want = v2Command(globalHooks, manifest.wrapper, point, manifest.alias);
    const groups = Array.isArray(settings.hooks && settings.hooks[point]) ? settings.hooks[point] : [];
    const found = groups.some(g => Array.isArray(g.hooks) && g.hooks.some(h => h.command === want));
    if (!found) return { ok: false, missing: point };
  }
  return { ok: true };
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const action = process.argv[2];
  if (action === 'merge' || action === 'verify') {
    const settingsPath = path.resolve(args.settings);
    const manifest = readJson(path.resolve(args.manifest));
    const globalHooks = path.resolve(args['global-hooks']);
    const settings = fs.existsSync(settingsPath) ? readJson(settingsPath) : {};

    if (action === 'verify') {
      const r = verify(settings, manifest, globalHooks);
      if (!r.ok) {
        process.stderr.write(`[registry-patch] VERIFY FAIL: missing ${r.missing}\n`);
        process.exit(1);
      }
      process.stdout.write('verified\n');
      return;
    }

    const changed = merge(settings, manifest, globalHooks, args.phase);
    if (!changed) {
      process.stdout.write('unchanged\n');
      return; // 幂等：内容无变化不写盘、不产生新备份
    }
    atomicWrite(settingsPath, JSON.stringify(settings, null, 2) + '\n');
    process.stdout.write('changed\n');
    return;
  }
  if (action === 'rollback') {
    const settingsPath = path.resolve(args.settings);
    const backupPath = path.resolve(args.backup);
    if (!fs.existsSync(backupPath)) {
      process.stderr.write(`[registry-patch] rollback FAIL: backup 不存在 ${backupPath}\n`);
      process.exit(1);
    }
    atomicWrite(settingsPath, fs.readFileSync(backupPath));
    process.stdout.write('rolled-back\n');
    return;
  }
  process.stderr.write('用法: registry-patch.js <merge|verify|rollback> --settings S --manifest M --global-hooks D [--phase P0] [--backup B]\n');
  process.exit(2);
}

main();
