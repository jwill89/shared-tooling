export interface SoonOptions {
  /** How long to keep trying, in milliseconds; the preset's waitTimeout (5 s) by default. */
  timeout?: number
  /** How long between tries, in milliseconds; 50 by default. */
  interval?: number
}

/**
 * Calls `check` until it returns, or resolves, without throwing, and gives back what it
 * returned; throws its last error once the timeout passes.
 */
export declare function soon<T>(check: () => T | Promise<T>, options?: SoonOptions): Promise<T>
