# CSS

How the front ends write styles: tokens and colour, units, layout, class naming, the cascade, themes and motion.

## What the shared Stylelint enforces

- Every front end's Stylelint config extends `lint/web`'s, which runs `stylelint-config-standard` and `stylelint-config-recommended-vue` on Stylelint 18 over CSS files and `.vue` style blocks: unknown or invalid properties, values and selectors, deprecated properties and keywords (`word-break: break-word` becomes `overflow-wrap: anywhere`), duplicate selectors, and a rule shadowed by one before it. [lint: stylelint stylelint-config-standard]
- Every front end also turns on `paletteRules(message)`, with a message that names its token file, and turns it off only for that file through an `overrides` entry. [review]
- Prettier formats CSS and style blocks, so Stylelint checks only what formatting can't. [CI]

## Tokens and colour

- Every colour is a token, defined once in the app's token file and used through `var()`. [lint: stylelint paletteRules]
- A colour the palette lacks becomes a new token in the right group, or maps to the nearest existing one; it is never a literal. [review]
- Outside the token file, the only literal colours are neutral black and white, for shadows, scrims and hairlines. [lint: stylelint paletteRules]
- Neutrals are written `rgb(0 0 0 / a)` and `rgb(255 255 255)`, never `black` or `white` by name. [lint: stylelint color-named]
- The `theme-color` meta and the web manifest can't read tokens, so they hold the literal values of the tokens they match. [review]
- A translucent tint of a token is `color-mix(in srgb, var(--x) N%, transparent)`, never a channel token such as `rgb(var(--x-rgb) / a)`. [review]
- Hover, pressed and tinted states are derived from their base token where they are used, not stored as one token per state or per alpha. [review]
- A token is named for what it does (`--surface`, `--text-muted`, `--danger`, `--hairline`, `--focus-ring`), never for how it looks (`--gold`, `--surface2`). [review]
- Custom properties are kebab-case. [lint: stylelint custom-property-pattern]
- Semantic colours (danger, success, warning, info) mean state and nothing else; a category, decoration or brand colour never reuses one. [review]
- Every `var(--x)` names a custom property that is defined. [review]
- Fonts, spacing, radii and shadows are tokens too. [review]
- A font stack is a token (`--font-body`), never a `font-family` list written inline. [review]
- Every heading reads one heading-font token. [review]
- A typeface's name inside a `--font-*` token is written as the foundry writes it. [lint: stylelint value-keyword-case]
- Fonts are self-hosted with `@font-face`. [review]
- Each app keeps its own look, and every visual choice has a reason in that project, never a framework's default. [review]

An app that adopts the component kit maps its palette onto the kit's tokens; see [components.md](components.md). Contrast is in [accessibility.md](accessibility.md).

## Units and type

- Font sizes are steps of one type scale, in `rem`, never `px`, `em` or `%`, so text follows the reader's own text size. [review]
- Prose (descriptions, notes, help) is at most 70 characters wide, with a line height of at least 1.5, small text included. [review]
- Prose is never justified. [review]
- An `img` rule that sets `aspect-ratio` also sets `height: auto`; otherwise the `height` attribute overrides the ratio. [review]

Touch-target sizes are in [accessibility.md](accessibility.md).

## Layout

- Each project lays out its pages with Tailwind utilities or with a stylesheet of object classes, and its `AGENTS.md` says which. [review]
- A CSS framework's layout helpers (Bulma's columns and spacing) are neither way; an app that adopts the kit replaces them with one of the two. [review]

### With Tailwind

- Layout is Tailwind utilities in the template, and each component's scoped styles do the rest. [review]
- The project's Stylelint config also extends `lint/web`'s Tailwind config, which knows Tailwind 4's at-rules and its `--color-*: initial` resets. [lint: stylelint stylelint/tailwind]
- A scoped style never sets `display` on an element that carries a responsive utility, since unlayered scoped CSS beats Tailwind's layered utilities. [review]

### With object classes

- Layout comes from one shared stylesheet of object and helper classes, with no utility-first framework. [review]
- A component's scoped CSS holds only what is one of a kind to it. [review]

### Either way

- Pages support the last two versions of Chrome, Edge, Firefox and Safari. [review]
- Everything works on a phone. [review]
- Before a UI change is done, it is tried in the browser at 390 px and 1280 px wide, and at any other width its users work at. [review]
- It is tried with its dialogs open, with the menu folded, and in every colour scheme the app has. [review]
- The page itself never scrolls sideways. [review]
- A table wider than its panel may scroll sideways inside the panel. [review]
- Grid tracks are `minmax(0, 1fr)`, so content can't push a track wider than its share. [review]
- A field, number inputs included, may shrink below its control's preferred width. [review]
- Long words, ids and tag names wrap (`overflow-wrap: anywhere`) rather than widen the page or squeeze a button. [review]
- The app shell sets the page width from a few named widths, chosen by the kind of content (a record, a list, full width for the densest pages), and centres it. [review]
- A view never sets its own width. [review]
- Layout inside a dialog uses CSS and percentages, never measurements of the dialog, which has no width while it opens. [review]
- A fixed overlay container, such as a toast stack, sets `pointer-events: none`, and each item in it sets `pointer-events: auto`, so its empty area doesn't swallow clicks and its items still work under a modal. [review]

## Class naming

- Class names are kebab-case. [lint: stylelint selector-class-pattern]
- BEM (`block__element--modifier`) is reserved for reusable components, with the component's name as the block (`.page-header__title`, `.page-header--compact`). [review]
- Every other class joins its parts with `-` (`.intro-text`, `.deck-summary`). [review]
- An app's own class never takes a name that a framework or the kit already styles. [review]

Other names are in [naming.md](naming.md).

## The cascade and inline styles

- Library CSS is beaten with a cascade layer or source order, never with a heavier selector. [review]
- The kit's CSS sits in `@layer kit`, so an app's own unlayered styles beat it. [review]
- An unlayered library is overridden with its own selector, placed later. [review]
- A Vue template never uses a static `style=""`. [lint: eslint vue/no-static-inline-styles]
- A bound `:style` carries only a value that differs per instance, best as a custom property (`:style="{ '--accent': colour }"`). [review]
- A common single property uses a helper class, not an inline style. [review]
- Styles for content a component teleports out of its tree (Reka's Combobox, DropdownMenu, Tooltip and Toast) go in the global stylesheet, because scoped styles can't reach it; Reka's Dialog parts are the exception. [review]

## Themes

- `:root` declares `color-scheme`, with a `scrollbar-color` taken from tokens, so native controls and scrollbars match the theme. [review]
- The active theme is one class or attribute on the `html` element (`scheme-dark`, `data-theme="dark"`), set by one module. [review]
- Styles change through the tokens the theme switches, never through their own `prefers-color-scheme` queries. [review]
- A theme overrides only tokens; class names are not a theme API. [review]
- Where an app has both schemes, they are equals, and every page is checked in both. [review]
- Such an app follows the device until the user picks a scheme, and keeps that choice on the device. [review]
- An app with a single scheme has made a product choice, and is checked in that one. [review]

## Motion

- Motion shows a change of state, never decoration. [review]
- Each animation and transition honours `prefers-reduced-motion` in its own rule; no global rule switches all motion off, since a global `!important` rule also overrides the kit's layered styles and any motion a component keeps on purpose. [review]
- Where code waits for an animation's or transition's end event, its reduced form shortens it rather than removing it, since a removed one never fires the event. [review]
