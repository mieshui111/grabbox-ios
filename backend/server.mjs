#!/usr/bin/env node
/**
 * GrabBox iOS 版可选后端 —— 只有 YouTube / Instagram 需要它。
 *
 * 为什么必须有：iOS 禁止 App 内下载并执行外部代码（Android 版打包 libpython + yt-dlp 那条路
 * 在 iOS 是死路），所以 yt-dlp 只能跑到你自己的服务器上。服务端负责「解析 + 下载 + 合并」，
 * 给手机回一个合并好的 mp4 直链，手机零解析逻辑。
 *
 * 依赖：Node 18+，PATH 里有 yt-dlp 和 ffmpeg
 *   pip install -U yt-dlp          （或 docker，见项目 README）
 * 用法：
 *   node server.mjs                # 默认 :8421
 *   PORT=9000 node server.mjs
 * 局域网访问：手机和服务器必须同一网段，iOS App 里填 http://<服务器IP>:8421
 *
 * 接口：
 *   GET  /health                    → {"ok":true}
 *   POST /resolve  {"url":"..."}   → {"title":"…","media":[{"url":"…/dl/x.mp4","kind":"video","ext":"mp4"}]}
 *   GET  /dl/<file>                 → 合并好的文件（保留 1 小时后自动清理）
 */

import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { createReadStream, createWriteStream, existsSync, mkdirSync, readdirSync, statSync, unlinkSync } from 'node:fs';
import { basename, join } from 'node:path';
import crypto from 'node:crypto';

const PORT = Number(process.env.PORT || 8421);
const DL = process.env.DOWNLOADS || join(process.cwd(), 'dl');
const TTL = Number(process.env.TTL_MS || 60 * 60 * 1000); // 产物保留 1 小时
const YTDLP = process.env.YTDLP || 'yt-dlp';
const FORMAT =
  process.env.FORMAT || 'bv*[ext=mp4][height<=1080]+ba[ext=m4a]/b[ext=mp4]/bv*+ba/b';

mkdirSync(DL, { recursive: true });

const MIME = {
  '.mp4': 'video/mp4',
  '.m4a': 'audio/mp4',
  '.mp3': 'audio/mpeg',
  '.jpg': 'image/jpeg',
  '.png': 'image/png',
  '.webp': 'image/webp',
};

const json = (res, code, body) => {
  const data = JSON.stringify(body);
  res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8' });
  res.end(data);
};

function run(cmd, args) {
  return new Promise((resolve, reject) => {
    const child = spawn(cmd, args, { stdio: ['ignore', 'pipe', 'pipe'] });
    let out = '';
    child.stdout.on('data', (d) => (out += d));
    child.stderr.on('data', (d) => (out += d));
    child.on('error', reject);
    child.on('close', (code) =>
      code === 0 ? resolve(out) : reject(new Error(out.trim().split('\n').slice(-6).join(' | ').slice(-500)))
    );
  });
}

const server = createServer(async (req, res) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
  if (req.method === 'OPTIONS') {
    res.writeHead(204);
    res.end();
    return;
  }

  const url = new URL(req.url, 'http://local');

  // 健康检查
  if (req.method === 'GET' && url.pathname === '/health') {
    return json(res, 200, { ok: true });
  }

  // 产物下载
  if (req.method === 'GET' && url.pathname.startsWith('/dl/')) {
    const file = join(DL, basename(url.pathname));
    if (!existsSync(file)) {
      return json(res, 404, { error: '文件不存在（可能已被清理，重新解析一次）' });
    }
    res.writeHead(200, {
      'Content-Type': MIME[file.slice(file.lastIndexOf('.')).toLowerCase()] ?? 'application/octet-stream',
      'Content-Length': statSync(file).size,
      'Content-Disposition': `attachment; filename="${basename(file)}"`,
    });
    createReadStream(file).pipe(res);
    return;
  }

  // 解析
  if (req.method === 'POST' && url.pathname === '/resolve') {
    let body = '';
    req.on('data', (d) => (body += d));
    req.on('end', async () => {
      let target = '';
      try {
        target = String(JSON.parse(body || '{}').url || '');
        if (!/^https?:\/\//.test(target)) return json(res, 400, { error: 'body 需要 {"url":"https://…"}' });

        // 1) 元数据（标题）
        let title = null;
        try {
          title = JSON.parse(await run(YTDLP, ['-j', '--no-playlist', target])).title ?? null;
        } catch { /* 标题拿不到不影响下载 */ }

        // 2) 下载 + 合并成 mp4（服务端有 ffmpeg）
        const id = crypto.randomBytes(6).toString('hex');
        const outNoExt = join(DL, id);
        await run(YTDLP, [
          '-f', FORMAT,
          '--merge-output-format', 'mp4',
          '--no-playlist',
          '--no-part',
          '-o', outNoExt,
          target,
        ]);
        const produced = readdirSync(DL).find((f) => f.startsWith(id) && !f.endsWith('.part'));
        if (!produced) throw new Error('yt-dlp 没有产出文件');
        const ext = produced.slice(produced.lastIndexOf('.') + 1);

        return json(res, 200, {
          title,
          media: [{ url: `http://${req.headers.host}/dl/${produced}`, kind: 'video', ext }],
        });
      } catch (e) {
        return json(res, 502, { error: `解析失败：${e.message}` });
      }
    });
    return;
  }

  json(res, 404, { error: 'not found' });
});

// 定时清理过期产物
setInterval(() => {
  for (const f of readdirSync(DL)) {
    const p = join(DL, f);
    try {
      if (Date.now() - statSync(p).mtimeMs > TTL) unlinkSync(p);
    } catch { /* 竞态忽略 */ }
  }
}, 10 * 60 * 1000).unref();

server.listen(PORT, '0.0.0.0', () => {
  console.log(`[grabbox-backend] http://0.0.0.0:${PORT}  downloads → ${DL}`);
});
