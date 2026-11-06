import type { Page } from '@playwright/test'

export declare const WCAG_22_AA: string[]

export declare function axeViolations(
  page: Page,
  options?: { tags?: string[]; exclude?: string[] },
): Promise<string[]>
