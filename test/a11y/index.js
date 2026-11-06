import { AxeBuilder } from '@axe-core/playwright'

/**
 * WCAG 2.2 A and AA, and axe's best practices (landmarks, one h1, heading order): the
 * bar every site with a UI holds. A site that aims higher passes its own tags, as the
 * résumé site does with the AAA ones (`[...WCAG_22_AA, 'wcag2aaa']`).
 */
export const WCAG_22_AA = [
  'wcag2a',
  'wcag2aa',
  'wcag21a',
  'wcag21aa',
  'wcag22a',
  'wcag22aa',
  'best-practice',
]

/**
 * axe's findings on the page as it stands, one line per failing element, so a failed
 * `expect(await axeViolations(page)).toEqual([])` says what to fix and where. Seeded
 * from the résumé site's helper.
 *
 * The page must belong to a browser context, as Playwright Test's `page` fixture does
 * (axe opens a second page beside it to finish the run); a bare `browser.newPage()`
 * is refused.
 *
 * @param {import('@playwright/test').Page} page
 * @param {{ tags?: string[], exclude?: string[] }} [options]
 *   `exclude` takes selectors axe should skip, each with its reason at the call (the
 *   résumé site's aria-hidden gutter, say).
 * @returns {Promise<string[]>}
 */
export async function axeViolations(page, { tags = WCAG_22_AA, exclude = [] } = {}) {
  let builder = new AxeBuilder({ page }).withTags(tags)
  for (const selector of exclude) {
    builder = builder.exclude(selector)
  }
  const results = await builder.analyze()
  return results.violations.flatMap((violation) =>
    violation.nodes.map(
      (node) =>
        `${violation.id}: ${node.target.join(' ')} — ${node.failureSummary?.split('\n')[1]?.trim() ?? violation.help}`,
    ),
  )
}
