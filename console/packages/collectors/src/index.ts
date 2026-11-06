import type { Collector } from './types.js';
import { claudeGlobalCollector } from './collectors/claude-global.js';
import { claudeProjectsCollector } from './collectors/claude-projects.js';
import { devforgeHooksCollector } from './collectors/devforge-hooks.js';
import { devforgeFirelogCollector } from './collectors/devforge-firelog.js';
import { devforgeAutopilotsCollector } from './collectors/devforge-autopilots.js';
import { devforgeLaunchCollector } from './collectors/devforge-launch.js';
import { devforgeAdaptersCollector } from './collectors/devforge-adapters.js';
import { devforgePatchesCollector } from './collectors/devforge-patches.js';
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
  devforgePatchesCollector,
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
export { fixtureCollector } from './collectors/fixture.js';
export { servicesCollector } from './collectors/services.js';
export { devforgeLaunchCollector } from './collectors/devforge-launch.js';
export { parseFirelogLine } from './collectors/devforge-firelog.js';
export { loadExternalCollectors } from './external.js';

export { loadRegistryEntries, applyRegistryOverlay, matchesRegistryEntry, editRegistryPlatforms } from './overlay.js';
export type { RegistryEntry, RegistryMatch, LoadedRegistry } from './overlay.js';
export { syncFirstPartyStore, loadFirstPartyStore, writeStoreRecord, storeFileName } from './first-party-store.js';
export type { StoreSyncResult, StoreRecord, LoadedStore } from './first-party-store.js';
export { contentFingerprint, isTruthKind, TRUTH_KINDS } from './store-content.js';
export { splitDiff } from './split-diff.js';
export type { SplitRow } from './split-diff.js';
export { loadPlatforms, resolvePlatform, resolveWriteChannel, buildPlatformsView, DEFAULT_PLATFORMS } from './platforms.js';
export type {
  PlatformDef,
  PlatformWrite,
  PlatformRead,
  PlatformKindDef,
  ResolvedWrite,
  LoadedPlatforms,
  PlatformAssetLite,
  PlatformKindView,
  PlatformView,
  PlatformsUnadapted,
  PlatformsView,
} from './platforms.js';
export { MULTICA_PREFIX_MARK, extractAgentInstructions, spliceAgentInstructions } from './collectors/multica.js';
export { buildReconcileReport, reconcileDiagnostics } from './reconcile.js';
export type {
  ReconcileAction,
  ReconcileCopy,
  ReconcileDirection,
  ReconcileItem,
  ReconcileItemType,
  ReconcileReport,
  WriteStep,
  ContentRef,
} from './reconcile.js';
