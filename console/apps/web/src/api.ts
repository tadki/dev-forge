import { useEffect, useRef } from 'react';
import { useQueryClient } from '@tanstack/react-query';

const TOKEN_KEY = 'forge_token';

export function getToken(): string {
  return localStorage.getItem(TOKEN_KEY) ?? '';
}

export function setToken(token: string): void {
  if (token) localStorage.setItem(TOKEN_KEY, token);
  else localStorage.removeItem(TOKEN_KEY);
}

export async function apiFetch<T>(path: string, init?: RequestInit): Promise<T> {
  const res = await fetch(path, {
    ...init,
    headers: { ...(init?.headers ?? {}), authorization: `Bearer ${getToken()}` },
  });
  if (res.status === 401) {
    const err = new Error('unauthorized') as Error & { status: number };
    err.status = 401;
    throw err;
  }
  if (!res.ok) {
    const body = await res.text();
    const err = new Error(`${res.status}: ${body.slice(0, 200)}`) as Error & { status: number };
    err.status = res.status;
    throw err;
  }
  return (await res.json()) as T;
}

export function apiGet<T>(path: string): Promise<T> {
  return apiFetch<T>(path);
}

export function apiPost<T>(path: string, body: unknown): Promise<T> {
  return apiFetch<T>(path, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });
}

/** SSE：fetch 流式读取（EventSource 不能带 Authorization 头，token 走 query）
 *  enabled=false 时不连接；鉴权成功（token 就位）后由调用方翻 true 触发连接。 */
export function useSSE(onRegistry: (data: unknown) => void, enabled: boolean): { connected: boolean } {
  const client = useRef(useQueryClient());
  const connected = useRef(false);
  useEffect(() => {
    if (!enabled) {
      connected.current = false;
      return;
    }
    let cancelled = false;
    const ctrl = new AbortController();
    async function run(): Promise<void> {
      try {
        const res = await fetch(`/api/events?token=${encodeURIComponent(getToken())}`, { signal: ctrl.signal });
        if (!res.ok || !res.body) return;
        connected.current = true;
        const reader = res.body.getReader();
        const decoder = new TextDecoder();
        let buffer = '';
        while (!cancelled) {
          const { done, value } = await reader.read();
          if (done) break;
          buffer += decoder.decode(value, { stream: true });
          const parts = buffer.split('\n\n');
          buffer = parts.pop() ?? '';
          for (const part of parts) {
            const ev = part.match(/^event: (.+)$/m)?.[1];
            if (ev !== 'registry') continue;
            const data = part.match(/^data: (.+)$/m)?.[1];
            if (data) {
              try {
                onRegistry(JSON.parse(data));
              } catch {
                /* ignore */
              }
            }
            void client.current.invalidateQueries({ queryKey: ['overview'] });
            void client.current.invalidateQueries({ queryKey: ['assets'] });
            void client.current.invalidateQueries({ queryKey: ['activity'] });
            void client.current.invalidateQueries({ queryKey: ['reconcile'] });
            void client.current.invalidateQueries({ queryKey: ['platforms'] });
          }
        }
      } catch {
        /* aborted or network error */
      } finally {
        connected.current = false;
      }
    }
    void run();
    return () => {
      cancelled = true;
      ctrl.abort();
    };
  }, [onRegistry, enabled]);
  return { connected: connected.current };
}
