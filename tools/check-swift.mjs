#!/usr/bin/env node
/**
 * Swift 粗校验器：本机没有 swiftc，用它在推送 CI 编译前抓低级失误。
 * 检查：括号/花括号/方括号配对、字符串字面量边界（含原始字符串 #"…"#、多行 """、插值 \(...)）。
 * 不是真编译器 —— 它只兜底，真正的把关在 GitHub Actions 的云 Mac。
 * 用法：node tools/check-swift.mjs
 */
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';

const root = process.argv[2] || 'GrabBox';
let files = [];
(function walk(dir) {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) walk(p);
    else if (name.endsWith('.swift')) files.push(p);
  }
})(root);

let failed = false;

for (const file of files) {
  const src = readFileSync(file, 'utf8');
  let i = 0, line = 1;
  const stack = [];
  const errors = [];
  let state = 'code'; // code | line-comment | block-comment | string
  let rawHashes = 0;
  let blockDepth = 0;

  while (i < src.length) {
    const c = src[i];
    const n = src[i + 1];

    if (c === '\n') line++;

    if (state === 'line-comment') {
      if (c === '\n') state = 'code';
      i++; continue;
    }
    if (state === 'block-comment') {
      if (c === '/' && n === '*') { blockDepth++; i += 2; continue; }
      if (c === '*' && n === '/') { blockDepth--; i += 2; if (blockDepth === 0) state = 'code'; continue; }
      i++; continue;
    }
    if (state === 'string') {
      // 转义（仅非 raw；raw 里 \ 不转义，但我们的代码没有 \" 出现在 raw 中，可安全处理）
      if (rawHashes === 0 && c === '\\') { i += 2; continue; }
      // 插值 \( … )：剥到配对的右括号（内部同样要跳过字符串——简化：跳过引号段）
      if (c === '\\' && n === '(') {
        let depth = 1;
        i += 2;
        while (i < src.length && depth > 0) {
          if (src[i] === '(') depth++;
          else if (src[i] === ')') depth--;
          else if (src[i] === '"') { // 插值里的嵌套字符串
            i++;
            while (i < src.length && src[i] !== '"') { if (src[i] === '\\') i++; if (src[i] === '\n') line++; i++; }
          }
          if (src[i] === '\n') line++;
          i++;
        }
        continue;
      }
      const closer = '"' + '#'.repeat(rawHashes);
      if (src.startsWith(closer, i)) { i += closer.length; state = 'code'; continue; }
      i++; continue;
    }

    // ---- code 状态 ----
    if (c === '/' && n === '/') { state = 'line-comment'; i += 2; continue; }
    if (c === '/' && n === '*') { state = 'block-comment'; blockDepth = 1; i += 2; continue; }

    if (c === '"') {
      if (src.startsWith('"""', i)) {
        // 多行字符串：找到结束的 """
        const end = src.indexOf('"""', i + 3);
        if (end < 0) { errors.push(`L${line}: 未闭合的多行字符串`); break; }
        for (let k = i; k < end; k++) if (src[k] === '\n') line++;
        i = end + 3; continue;
      }
      let hashes = 0;
      let j = i - 1;
      while (j >= 0 && src[j] === '#') { hashes++; j--; }
      rawHashes = hashes;
      state = 'string';
      i++; continue;
    }

    if ('{(['.includes(c)) stack.push({ c, line });
    if ('})]'.includes(c)) {
      const open = stack.pop();
      const want = { ')': '(', ']': '[', '}': '{' }[c];
      if (!open) errors.push(`L${line}: 多余的 "${c}"`);
      else if (open.c !== want) errors.push(`L${line}: "${c}" 与 L${open.line} 的 "${open.c}" 不配对`);
      i++; continue;
    }
    i++;
  }

  if (state === 'string') errors.push(`文件结尾仍处于字符串状态`);
  for (const o of stack) errors.push(`L${o.line}: "${o.c}" 未闭合`);

  if (errors.length) {
    failed = true;
    console.log(`✗ ${file}`);
    for (const e of errors.slice(0, 10)) console.log(`    ${e}`);
  } else {
    console.log(`✓ ${file}`);
  }
}

console.log(failed ? '\n❌ 发现问题' : '\n✅ 语法粗检通过');
process.exit(failed ? 1 : 0);
