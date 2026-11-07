# lint/web

`@jwill89/lint-web`: the shared ESLint, Prettier, Stylelint and tsconfig for the front ends. It replaces the `jwill89/eslint-config` submodule, with the same rules plus template accessibility (`eslint-plugin-vuejs-accessibility`), which every project used to add on its own.

## What's in it

| Import | What it is |
| --- | --- |
| `@jwill89/lint-web` | ESLint for Vue 3 + TypeScript: Vue's recommended rules, typescript-eslint's `strictTypeChecked`, vuejs-accessibility's recommended rules, the curated rules below, test-file relaxations, and Prettier's conflict list last. |
| `@jwill89/lint-web` named `vueConventions` | The Vue style-guide rules six front ends already state: `<script setup lang="ts">` only, typed refs, macros in order, buttons with a type, no inline styles, no unregistered components. |
| `@jwill89/lint-web` named `tsStylistic` | typescript-eslint's `stylisticTypeChecked` rules, with `prefer-nullish-coalescing` leaving strings and booleans to `\|\|`. |
| `@jwill89/lint-web` named `defineConfigWithVueTs`, `vueTsConfigs` | Re-exported from this package's install, for a project that needs more of them (see "One copy of each plugin"). |
| `@jwill89/lint-web/react` | ESLint for React + TypeScript (Family Card Game): the same curated rules on `strictTypeChecked`, React's hooks rules, and JSX accessibility from `eslint-plugin-jsx-a11y-x` (rules named `jsx-a11y-x/…`). |
| `@jwill89/lint-web/prettier` | `semi: false`, `singleQuote: true`, `printWidth: 100`, `trailingComma: 'all'`. |
| `@jwill89/lint-web/stylelint` | `stylelint-config-standard` and `stylelint-config-recommended-vue`, BEM-style kebab-case classes, kebab-case custom properties, grouped tokens. Named export `paletteRules(message)` adds the palette rule. |
| `@jwill89/lint-web/stylelint/tailwind` | Tailwind 4's at-rules and its `--color-*: initial` custom properties, layered on the above. |
| `@jwill89/lint-web/tsconfig.app.json` | `@vue/tsconfig`'s DOM base with unused locals and parameters and switch fallthrough checked. |
| `@jwill89/lint-web/tsconfig.node.json` | The Node-side files: Vite, Vitest and Playwright configs. |

The curated rules: `prefer-const`, `no-param-reassign`, `eqeqeq` (smart), `curly` (all), `object-shorthand`, `no-console` (warn and error allowed), `consistent-type-imports`, `no-unused-vars` (a leading `_` opts out), `naming-convention` (PascalCase for types and enum members only, so API types stay as each API's JSON has them: camelCase by the standards, snake_case in older APIs until they move), `restrict-template-expressions` (numbers and booleans allowed), `no-confusing-void-expression` (arrow shorthand allowed), and `label-has-for` satisfied by nesting or by `for`/`id`.

`curly` comes back on after Prettier's conflict list. In the old eslint-config, Prettier's list was last and switched it off, so it never ran; expect new findings when a project moves over (`eslint --fix` adds the braces).

## Use it in a project

The project holds shared-tooling as a submodule at `shared/`, so from a front end in `frontend/` or `web/` the package is at `../shared/lint/web`.

1. Tell npm to install local packages as copies, not links. Add to the front end's tracked `.npmrc`:

   ```ini
   install-links=true
   ```

   Without it npm makes a symlink and installs none of the package's dependencies, and ESLint can't find its plugins.

2. Install it with its peers:

   ```bash
   npm install -D ../shared/lint/web eslint prettier typescript stylelint
   ```

   Once step 4 has removed the project's own copies of the plugins, run `npm dedupe`. A lockfile from before can keep an older copy nested under another package (Kindred Nights kept `eslint-plugin-vue` 10.11.1 under `@vue/eslint-config-typescript`), and ESLint warns that it is replacing one copy with the other.

3. Point the configs at it:

   ```ts
   // eslint.config.ts
   import shared, { vueConventions, tsStylistic } from '@jwill89/lint-web'

   export default [
     { ignores: ['dist/**', 'coverage/**', 'src/types/api.generated.ts'] },
     ...shared,
     vueConventions,
     tsStylistic,
     // the project's own rules
   ]
   ```

   ```js
   // prettier.config.js
   export { default } from '@jwill89/lint-web/prettier'
   ```

   ```js
   // stylelint.config.js
   import { paletteRules } from '@jwill89/lint-web/stylelint'

   export default {
     extends: ['@jwill89/lint-web/stylelint'],
     rules: paletteRules('Use a tokens.css colour: var(--x), or color-mix(in srgb, var(--x) N%, transparent) for a tint'),
     overrides: [{ files: ['src/assets/tokens.css'], rules: { 'color-no-hex': null } }],
   }
   ```

   ```jsonc
   // tsconfig.app.json
   { "extends": "@jwill89/lint-web/tsconfig.app.json", "include": ["src"] }
   ```

4. Remove what the package now supplies from the project's own `devDependencies`: `eslint-plugin-vue`, `eslint-plugin-vuejs-accessibility`, `@vue/eslint-config-typescript`, `@vue/eslint-config-prettier`, `stylelint-config-standard`, `stylelint-config-recommended-vue`, `postcss-html`, `@vue/tsconfig`, and the old `@jwill89/eslint-config`.

## One copy of each plugin

ESLint refuses two different copies of a plugin under one name. This package registers every plugin it uses, so a project imports them from here rather than installing its own: `defineConfigWithVueTs` and `vueTsConfigs` are re-exported for that. A project-specific plugin the package doesn't use is fine to install directly.

## Updating

npm only refreshes its copy of the package when its `version` moves. shared-tooling's release task sets it to the release's number, so every release moves it. A project takes a release with:

```bash
task shared:update -- v1.2.0
```

That moves the submodule and the workflow refs, and re-runs `npm install -D ../shared/lint/web` here (see the root README's "Versions"). When the release raises a peer's range, the same install raises the project's own ESLint, Prettier, Stylelint or TypeScript into it. A fresh clone or CI needs nothing extra: `npm ci` installs the copy the lockfile records.

## Stylelint 18

From v2.0.0 the Stylelint configs are on Stylelint 18 (`stylelint-config-standard` 41, `stylelint-config-recommended` 19), so a project needs Stylelint 18 itself, and Node ^24.15.0 or >=26. `task shared:update` raises the project's own `stylelint` (see "Updating"). What else [Stylelint's migration guide](https://stylelint.io/migration-guide/to-18) means for a project:

- Five rules join the recommended set: `value-no-invalid` (a value that doesn't parse, or math such as `10px + 2`), `selector-no-invalid`, `selector-no-unmatchable`, `selector-no-deprecated` and `at-charset-rule-no-invalid`. `declaration-property-value-no-unknown` now reads a `var()` as the custom property's declared value, so it finds what a token used to hide.
- `declaration-block-single-line-max-declarations` is gone, from Stylelint and from the standard config; a project that sets it removes it.
- A local `extends` or `plugins` path names its file: `./stylelint.local.js`, not `./stylelint.local`. Package names and this package's exports (`@jwill89/lint-web/stylelint`) resolve as before.
- CLI flags take their full names (`--max-warnings`, not `--mw`) in kebab-case (`--ignore-path`), and `--fix=lax` takes its value after `=`. A bare `--fix` is unchanged.
- A Stylelint plugin or config of the project's own that is still on Stylelint 17 can't install beside it. `stylelint-config-recommended-scss` and `stylelint-scss` have no Stylelint 18 release yet, so a `.scss` file is read with `postcss-scss` (a dev dependency of the project) and checked by the shared rules, with the Sass at-rules known:

  ```js
  overrides: [
    {
      files: ['**/*.scss'],
      customSyntax: 'postcss-scss',
      rules: { 'at-rule-no-unknown': [true, { ignoreAtRules: ['use', 'forward', 'include', 'mixin'] }] },
    },
  ],
  ```

## JSX accessibility

The React variant uses `eslint-plugin-jsx-a11y-x`, the eslint-community fork of `eslint-plugin-jsx-a11y` (decided 2026-11-05). The original was last released in October 2024 and supports ESLint up to 9. The fork has all of the original's rules but three it had deprecated (`accessible-emoji`, `label-has-for`, `no-onchange`), under the `jsx-a11y-x/` prefix, with settings under a `jsx-a11y-x` key. It is still pre-1.0, so read its release notes when its version moves.

Its recommended set doesn't report a bare `<input>` with no label (the original's didn't either); the Vue plugin's `form-control-has-label` does.

## Not here yet

- **Knip.** Only the Gallery and TarotGen.io run it, and their configs are all project entries; nothing to share yet.
