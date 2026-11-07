import pluginVue from 'eslint-plugin-vue'
import pluginVueA11y from 'eslint-plugin-vuejs-accessibility'
import { defineConfigWithVueTs, vueTsConfigs } from '@vue/eslint-config-typescript'
import configPrettier from '@vue/eslint-config-prettier'
import tseslint from 'typescript-eslint'

/**
 * Shared ESLint flat config for jwill89 Vue 3 + TypeScript front ends.
 *
 * Spread it into the project's eslint.config.ts and add the project's own ignores
 * and rules after it:
 *
 *   import shared, { vueConventions, tsStylistic } from '@jwill89/lint-web'
 *   export default [{ ignores: ['dist/**'] }, ...shared, vueConventions, tsStylistic]
 *
 * Every plugin is registered here, from this package's own install. A project that
 * needs one of them directly (defineConfigWithVueTs, vueTsConfigs) imports it from
 * this package too: a second copy from the project's node_modules can't be
 * registered under the same name.
 *
 * Type-aware rules (strictTypeChecked) use typescript-eslint's project service,
 * which finds each project's tsconfig on its own.
 */
export default defineConfigWithVueTs(
  { name: 'jwill/files', files: ['**/*.{ts,mts,tsx,vue}'] },

  pluginVue.configs['flat/recommended'],
  vueTsConfigs.strictTypeChecked,

  // Template accessibility: labels, alt text, interactive roles (WCAG 2.2 AA).
  ...pluginVueA11y.configs['flat/recommended'],

  // Scoped to TypeScript and Vue: a plain .js file (a service worker in public/, a
  // config) is in no tsconfig, and the project service would refuse it.
  {
    name: 'jwill/language-options',
    files: ['**/*.{ts,mts,tsx,vue}'],
    languageOptions: {
      parserOptions: { projectService: true },
    },
  },

  {
    name: 'jwill/rules',
    files: ['**/*.{ts,mts,tsx,vue}'],
    rules: {
      // Correctness and consistency
      'prefer-const': 'error',
      'no-param-reassign': ['error', { props: false }],
      eqeqeq: ['error', 'smart'],
      curly: ['error', 'all'],
      'object-shorthand': 'error',
      'no-console': ['warn', { allow: ['warn', 'error'] }],

      // TypeScript
      '@typescript-eslint/consistent-type-imports': 'error',
      '@typescript-eslint/no-unused-vars': [
        'error',
        {
          argsIgnorePattern: '^_',
          varsIgnorePattern: '^_',
          caughtErrorsIgnorePattern: '^_',
        },
      ],
      // Types, interfaces and enums are PascalCase. Not applied to variables or
      // object properties: API fields are camelCase by the standards
      // (standards/naming.md), but the generated API types mirror each API's JSON, and
      // older APIs keep snake_case fields until they move, so constraining those would
      // fail them.
      '@typescript-eslint/naming-convention': [
        'error',
        { selector: 'typeLike', format: ['PascalCase'] },
        { selector: 'enumMember', format: ['PascalCase'] },
      ],
      // Template literals with numbers and booleans are fine (`${count} items`).
      '@typescript-eslint/restrict-template-expressions': [
        'error',
        { allowNumber: true, allowBoolean: true },
      ],
      // Arrow-shorthand handlers that return void are idiomatic in Vue
      // (`@click="() => doThing()"`, `focus: () => el?.focus()`).
      '@typescript-eslint/no-confusing-void-expression': ['error', { ignoreArrowShorthand: true }],
      // no-unnecessary-condition stays on (strictTypeChecked's default). Type a
      // genuinely optional fetch result as `T | undefined`, so the rule sees a
      // defensive `?.` or `??` as necessary rather than flagging it.

      // A label names its control by holding it or by `for`/`id`; the plugin's
      // default demands both.
      'vuejs-accessibility/label-has-for': ['error', { required: { some: ['nesting', 'id'] } }],
    },
  },

  {
    name: 'jwill/test-overrides',
    files: ['**/*.{test,spec}.{ts,tsx}', '**/__tests__/**'],
    rules: {
      // Test mocks and assertions legitimately use these patterns.
      '@typescript-eslint/no-non-null-assertion': 'off',
      '@typescript-eslint/require-await': 'off',
      '@typescript-eslint/no-floating-promises': 'off',
      '@typescript-eslint/unbound-method': 'off',
    },
  },

  // Turns off the rules that would fight Prettier.
  configPrettier,

  // After it: eslint-config-prettier turns `curly` off, though `all` is safe beside
  // Prettier (only its multi-line options conflict). Until this override the rule
  // above never ran.
  { name: 'jwill/after-prettier', rules: { curly: ['error', 'all'] } },
)

/**
 * The parts of the Vue style guide the base leaves off, as six of the front ends
 * already state them: `<script setup lang="ts">` only, typed refs, macros in order,
 * buttons with a type, and no inline styles. Spread after the base.
 *
 * `vue/no-undef-components` knows the components most apps register globally (the
 * router's and Font Awesome's); a project with others overrides the rule.
 */
export const vueConventions = {
  name: 'jwill/vue-conventions',
  files: ['**/*.{ts,mts,tsx,vue}'],
  rules: {
    'vue/block-lang': ['error', { script: { lang: 'ts' } }],
    'vue/component-api-style': ['error', ['script-setup']],
    'vue/no-static-inline-styles': 'error',
    'vue/define-macros-order': 'error',
    'vue/require-typed-ref': 'error',
    'vue/prefer-use-template-ref': 'error',
    'vue/no-required-prop-with-default': 'error',
    'vue/no-undef-components': [
      'error',
      {
        ignorePatterns: [
          '^(Router|router-)(Link|View|link|view)$',
          '^(FontAwesomeIcon|font-awesome-icon)$',
        ],
      },
    ],
    'vue/no-unused-refs': 'error',
    'vue/no-useless-v-bind': 'error',
    'vue/no-useless-mustaches': 'error',
    'vue/prefer-true-attribute-shorthand': 'error',
    'vue/html-button-has-type': 'error',
  },
}

const stylisticTypeChecked = tseslint.configs.stylisticTypeChecked.at(-1)

/**
 * typescript-eslint's stylistic-type-checked rules, on top of the base's
 * strictTypeChecked. Taken from this package's typescript-eslint, so the plugin the
 * base registered is the one the rules run under.
 */
export const tsStylistic = {
  name: 'jwill/ts-stylistic',
  files: ['**/*.{ts,mts,tsx,vue}'],
  rules: {
    ...stylisticTypeChecked?.rules,
    // An empty string or false falls back as nothing would, so || stays where it is
    // meant.
    '@typescript-eslint/prefer-nullish-coalescing': [
      'error',
      { ignorePrimitives: { string: true, boolean: true } },
    ],
  },
}

export { defineConfigWithVueTs, vueTsConfigs }
