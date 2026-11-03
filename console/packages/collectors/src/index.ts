import type { Collector } from './types.js';
import { claudeGlobalCollector } from './collectors/claude-global.js';
import { claudeProjectsCollector } from './collectors/claude-projects.js';
import { devforgeHooksCollector } from './collectors/devforge-hooks.js';
import { devforgeFirelogCollector } from './collectors/devforge-firelog.js';
import { devforgeAutopilotsCollector } from './collectors/devforge-autopilots.js';
import { devforgeLaunchCollector } from './collectors/devforge-launch.js';
import { devforgeAdaptersCollector } from './collectors/devforge-adapters.js';
import { multicaCollector } from './collectors/multica.js';
import { servicesCollector } from './collectors/services.js';
import { healthCollector } from './collectors/health.js';
import { hindsightCollector } from './collectors/hindsight.js';
import { sessionsCollector } from './collectors/sessions.js';

export const builtinCollectors: Collector[] = [
  claudeGlobalCollector,
  claudeProjectsCollector,
  devforgeHooksCollector,
  devforgeFirelogCollector,
  devforgeAutopilotsCollector,
  devforgeLaunchCollector,
  devforgeAdaptersCollector,
  multicaCollector,
  servicesCollector,
  healthCollector,
  hindsightCollector,
  sessionsCollector,
];

export * from './types.js';
export * from './config.js';
export * from './redact.js';
export * from './util.js';
export * from './registry.js';
export * from './effective.js';
export * from './migration.js';
export { fixtureCollector } from './collectors/fixture.js';
export { servicesCollector } from './collectors/services.js';
export { devforgeLaunchCollector } from './collectors/devforge-launch.js';
export { parseFirelogLine } from './collectors/devforge-firelog.js';
export { loadExternalCollectors } from './external.js';
