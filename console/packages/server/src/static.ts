import { createReadStream, stat } from 'node:fs';
import { join, normalize, extname } from 'node:path';
import type { ServerResponse } from 'node:http';

const MIME: Record<string, string> = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.woff2': 'font/woff2',
  '.ttf': 'font/ttf',
  '.ico': 'image/x-icon',
  '.map': 'application/json',
};

export function serveStatic(root: string, urlPath: string, res: ServerResponse): void {
  const clean = decodeURIComponent(urlPath.split('?')[0]);
  let rel = normalize(clean).replace(/^(\.\.[/\\])+/, '');
  if (rel.startsWith('/')) rel = rel.slice(1);
  if (rel === '' || rel === 'index.html' || !rel.includes('.')) rel = 'index.html'; // SPA fallback
  const file = join(root, rel);
  if (!file.startsWith(root)) {
    res.writeHead(403).end();
    return;
  }
  stat(file, (err, st) => {
    if (err || !st.isFile()) {
      res.writeHead(404, { 'content-type': 'text/plain; charset=utf-8' }).end('not found');
      return;
    }
    res.writeHead(200, {
      'content-type': MIME[extname(file)] ?? 'application/octet-stream',
      'content-length': st.size,
      'cache-control': rel.startsWith('assets/') ? 'public, max-age=86400' : 'no-cache',
    });
    const stream = createReadStream(file);
    stream.on('error', () => res.destroy());
    stream.pipe(res);
  });
}
