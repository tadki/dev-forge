import type { ServerResponse } from 'node:http';

export interface SseEvent {
  event: string;
  data: unknown;
}

export class SSEBus {
  private clients = new Set<ServerResponse>();

  subscribe(res: ServerResponse): void {
    res.writeHead(200, {
      'content-type': 'text/event-stream',
      'cache-control': 'no-cache, no-transform',
      connection: 'keep-alive',
      'x-accel-buffering': 'no',
    });
    res.write('retry: 5000\n\n');
    this.clients.add(res);
    const heartbeat = setInterval(() => {
      try {
        res.write(':hb\n\n');
      } catch {
        this.drop(res);
      }
    }, 15000);
    res.on('close', () => {
      clearInterval(heartbeat);
      this.drop(res);
    });
  }

  private drop(res: ServerResponse): void {
    this.clients.delete(res);
  }

  broadcast(event: string, data: unknown): void {
    const payload = `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`;
    for (const res of this.clients) {
      try {
        res.write(payload);
      } catch {
        this.drop(res);
      }
    }
  }

  get clientCount(): number {
    return this.clients.size;
  }
}
