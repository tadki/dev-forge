import type { UseQueryResult } from '@tanstack/react-query';
import type { Overview } from '../types';

export interface PageCtx {
  workspace: string;
  query: string;
  overview: UseQueryResult<Overview, Error>;
}
