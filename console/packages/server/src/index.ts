import { createServer } from 'node:http';
import { join } from 'node:path';
import { existsSync } from 'node:fs';
import { loadConfig } from './engine.js';
import { Engine } from './engine.js';
import { createHandler } from './app.js';
import { SSEBus } from './sse.js';

const consoleRoot = join(import.meta.dirname, '..', '..', '..');
const configPath = process.env.FORGE_CONSOLE_CONFIG ?? join(consoleRoot, 'console.config.yaml');
const config = await loadConfig(configPath);

const token = process.env.FORGE_CONSOLE_TOKEN ?? null;
const port = Number(process.env.FORGE_CONSOLE_PORT ?? 7310);
const bind = process.env.FORGE_CONSOLE_BIND ?? '0.0.0.0';
const staticDir = join(consoleRoot, 'apps', 'web', 'dist');
const hasStatic = existsSync(join(staticDir, 'index.html'));

const sse = new SSEBus();
const engine = new Engine({ config, sse, watchEnabled: process.env.FORGE_CONSOLE_WATCH !== 'off' });
const handler = createHandler({
  getState: () => engine.state,
  token,
  sse,
  staticDir: hasStatic ? staticDir : undefined,
  pushAssets: (assets, collector) => engine.pushAssets(assets, collector),
});

await engine.start();
const server = createServer((req, res) => void handler(req, res));
server.listen(port, bind, () => {
  console.error(`forge-console listening on http://${bind}:${port} (static: ${hasStatic ? 'on' : 'off'}, token: ${token ? 'required' : 'OFF — local mode'})`);
});

const shutdown = () => {
  engine.stop();
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 3000).unref();
};
process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);
