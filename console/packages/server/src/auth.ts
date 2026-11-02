import { timingSafeEqual } from 'node:crypto';
import type { IncomingMessage } from 'node:http';

export const PUBLIC_PATHS = new Set(['/healthz']);

/** 公开 = healthz + 非 /api 静态资源（App 外壳可加载，数据一律要 token） */
export function isPublicPath(path: string): boolean {
  const clean = path.split('?')[0];
  return clean === '/healthz' || !clean.startsWith('/api/');
}

function extractToken(req: IncomingMessage): string | null {
  const auth = req.headers.authorization;
  if (auth?.startsWith('Bearer ')) return auth.slice(7);
  const cookie = req.headers.cookie;
  if (cookie) {
    const m = cookie.match(/(?:^|;\s*)forge_token=([^;]+)/);
    if (m) return decodeURIComponent(m[1]);
  }
  const url = req.url ?? '';
  const q = url.match(/[?&]token=([^&]+)/);
  if (q) return decodeURIComponent(q[1]);
  return null;
}

export function checkAuth(req: IncomingMessage, expectedToken: string | null): boolean {
  if (!expectedToken) return true; // 未配置 token = 本机模式全放行（仍绑 127.0.0.1）
  if (isPublicPath(req.url ?? '/')) return true;
  const provided = extractToken(req);
  if (!provided) return false;
  const a = Buffer.from(provided);
  const b = Buffer.from(expectedToken);
  if (a.length !== b.length) {
    // 恒定时间比较仍执行一次以防时序泄漏长度信息
    timingSafeEqual(b, b);
    return false;
  }
  return timingSafeEqual(a, b);
}
