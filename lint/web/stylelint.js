/**
 * Shared Stylelint config for jwill89 front ends: the standard CSS rules, in the
 * .vue files' style blocks as well. Prettier formats; this catches what formatting
 * cannot (an unknown property or value, a rule shadowed by one before it, an
 * @import that browsers would ignore).
 *
 *   // stylelint.config.js
 *   export default { extends: ['@jwill89/lint-web/stylelint'] }
 *
 * A project that keeps its colours as tokens adds the palette rule:
 *
 *   import { paletteRules } from '@jwill89/lint-web/stylelint'
 *   export default {
 *     extends: ['@jwill89/lint-web/stylelint'],
 *     rules: paletteRules('Use a token from tokens.css: var(--x)'),
 *   }
 */
export default {
  extends: ['stylelint-config-standard', 'stylelint-config-recommended-vue'],
  rules: {
    // Class names are kebab-case, with BEM's __element and --modifier where a part
    // has them.
    'selector-class-pattern': [
      '^[a-z][a-z0-9]*(-[a-z0-9]+)*(__[a-z0-9]+(-[a-z0-9]+)*)?(--[a-z0-9]+(-[a-z0-9]+)*)?$',
      { message: 'Name classes in kebab-case, block__element--modifier' },
    ],
    'custom-property-pattern': [
      '^[a-z][a-z0-9]*(-[a-z0-9]+)*$',
      { message: 'Name custom properties in kebab-case' },
    ],
    // Tokens sit in groups, a blank line between one group and the next.
    'custom-property-empty-line-before': null,
    // A typeface's name is written as the foundry writes it.
    'value-keyword-case': ['lower', { ignoreProperties: ['/^--font-/'] }],
  },
}

/**
 * The palette rule: a colour is defined once, as a token, and used through var().
 * Neutral black and white at any alpha (shadows, scrims, hairlines) are not palette
 * colours and may be written inline, as rgb(0 0 0 / a) and rgb(255 255 255). A tint is
 * color-mix(in srgb, var(--x) N%, transparent); the rule still lets the older channel
 * form, rgb(var(--x-rgb) / a), through for a project that hasn't moved off it yet.
 *
 * Turn it off for the file that defines the tokens with an `overrides` entry.
 *
 * @param {string} message What to write instead, naming the project's token file.
 */
export function paletteRules(message) {
  return {
    'color-no-hex': [true, { message }],
    'color-named': ['never', { message }],
    'declaration-property-value-disallowed-list': [
      {
        // rgb()/rgba()/hsl()/hsla() with literal channels, unless they are a token
        // or pure black or white.
        '/.*/': [
          '/\\b(?:rgba?|hsla?)\\((?!\\s*(?:var\\(|(?:255[\\s,]+255[\\s,]+255|0[\\s,]+0[\\s,]+0)[\\s,/)]))/',
        ],
      },
      { message },
    ],
  }
}
