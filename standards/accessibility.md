# Accessibility

The accessibility rules every site with a UI meets, and how each is checked.

## Target and checks

- The target is WCAG 2.2 AAA on every site with a UI, in every colour scheme it has. [review]
- Where a AAA criterion can't be met (a brand colour that can't reach it, a third-party widget, a criterion that doesn't fit the content), AA is the floor, and nothing falls below it. [axe]
- Each place that meets only AA is a dated line in the project's decision log with its reason, never left silent (see [docs-and-agents.md](docs-and-agents.md)). [review]
- AA is enforced: every rolled-out project's end-to-end suite runs axe on its main pages through shared `test/a11y` (`axeViolations` with `WCAG_22_AA`, which adds axe's best practices) and expects no findings. [axe]
- The suite checks the app's own theme, in every colour scheme it has. [axe]
- AAA is checked where it can be: a project's own test computes every colour pair's contrast and level (see Colour and contrast), and the rest is review, since axe can't check every AAA criterion. [test]
- A project whose pages meet AAA throughout adds axe's AAA rules to its run (`[...WCAG_22_AA, 'wcag2aaa']`), so a regression fails CI. [axe]
- An element left out of an axe run (`exclude`) carries its reason at the call. [review]
- `lint/web` runs the recommended rules of `eslint-plugin-vuejs-accessibility` on Vue templates and of `eslint-plugin-jsx-a11y-x` on JSX, plus `vue/html-button-has-type`: alt text, labels, interactive roles, key events beside mouse events, an action as a `<button>` and never an `<a>` without `href`, a `type` on every button, and no `autofocus` without an exception. [lint: eslint vuejs-accessibility, jsx-a11y-x]
- In React, an `<input>` with no label is caught by axe, since the `jsx-a11y-x` recommended set doesn't report it. [axe]
- A fix is also checked in the browser (every rendered control has a name, no `for` points at nothing, clicking a label focuses its field), because the linter can't see a bug that spans components. [axe]
- End-to-end tests find elements by role and label (`getByRole`, `getByLabel`), never by a library's class, so they test what assistive technology sees and still pass when an app swaps in the kit (see [testing.md](testing.md)). [test]

## Structure and headings

- Each page has one `h1`, headings in order, and landmarks for the top bar, the navigation and the main content. [axe]
- Every page inside the app's frame starts with a skip link, which is its first focusable element and stays hidden until it has focus. [test]
- The skip link moves focus to the page's one `<main id="main-content" tabindex="-1">` without adding a hash to the URL. [test]
- A page before sign-in is a `main` alone, with no skip link. [review]
- After every in-app navigation, focus moves to `main`. [review]
- Each route sets the document title in a router `afterEach` guard, from `meta.title`: the view's or item's name first, then the site's. [review]
- A folding section's heading holds a button with `aria-expanded` and `aria-controls`. [review]
- A breadcrumb names only the pages above the current one. [review]
- A breadcrumb hides its separators from screen readers, and moves within the app without a reload. [review]

## Names and labels

- Every form control has a label, which names it through `for` and `id` or by holding it. [lint: eslint vuejs-accessibility/form-control-has-label, label-has-for]
- A custom form control takes an `id` prop and puts it on its focusable element, so a `<label for>` reaches it; a PrimeVue wrapper takes `input-id`. [axe]
- A control that isn't a form element (a custom select, a `role="textbox"` editor, a group of controls) is named by `aria-labelledby`, pointing at its caption. [review]
- A caption that labels no control is a `span`, not a `label`. [review]
- An icon-only control is named by an accessible label and a `title`, never by a styled tooltip alone. [axe]
- An icon shown beside its own name is hidden from screen readers (`aria-hidden="true"`). [review]
- A change that arrives without the user acting (a turn, a play) is announced in a live region, driven by the same event as its animation, sound and vibration. [review]

## Keyboard and focus

- Whatever the mouse can do, the keyboard can do too. [review]
- A click handler on an element that isn't a control has a key handler beside it, and focus-out mirrors mouse-out. [lint: eslint vuejs-accessibility/click-events-have-key-events, mouse-events-have-key-events]
- A sortable column's header holds a button, and the header carries `aria-sort`. [review]
- Space activates a menu item. [review]
- A gesture surface (drag, swipe) has key and button alternatives. [review]
- A listbox option holds no focusable control. [review]
- Focus is always visible, as a ring drawn from the `--focus-ring` token, and that ring is never removed. [review]
- A modal traps focus, closes on Escape, gives focus back when it closes, and sets `role="dialog"` and `aria-modal`. [review]
- Modals, menus and listboxes come from a tested primitive (the kit, or Reka UI) and are never hand-rolled (see [components.md](components.md)). [review]
- A global keyboard shortcut ignores keystrokes aimed at a text field. [review]
- `autofocus` is used only on a single-purpose form (sign-in, forgot or reset password, unlock), on the input itself, with an inline lint exception that gives the reason. [lint: eslint vuejs-accessibility/no-autofocus]

## Touch targets

- The minimum touch target is 44 by 44 CSS px, WCAG 2.2's AAA criterion (2.5.5); the 24 by 24 that AA asks for, and axe checks, is the floor. [review]

## Colour and contrast

- Text reaches AAA contrast against every surface it sits on, hover states and every colour scheme included: 7:1 for body text, 4.5:1 for large text (24 px, or 18.66 px bold). [test]
- Where the palette can't reach AAA, text never falls below AA, 4.5:1 for body text and 3:1 for large text, and the pair is a recorded exception. [axe]
- Where a framework's default falls short, a token overrides it. [axe]
- Control boundaries, focus rings and meaningful icons reach 3:1 against what is next to them; WCAG sets no AAA level for these, and a project may hold them higher. [review]
- A colour that reaches only 3:1 is for borders and accents, never for text. [review]
- A test computes the contrast and level of every token pair from the live theme, and fails a pair below AAA unless it is a recorded exception; each new pair is added to it. A project with several themes checks each one, and a style guide page that shows every pair lets a person see what the test measures. [test]
- Colour is never the only cue: wherever colour marks a difference, a name or a symbol marks it too. [review]
- The current page in the navigation is underlined as well as lit. [review]
- Severity is shown by the background wash and the icon; an alert's text stays in the body text colour. [review]

How colours and tints are written is in [css.md](css.md).

## Text, motion and sound

- Text follows the OS text size, since sizes are in `rem` (see [css.md](css.md)). [review]
- Every animation and transition honours `prefers-reduced-motion` itself, not through one global rule (WCAG 2.2's AAA criterion 2.3.3); how is in [css.md](css.md). [review]
- Sound is an extra: audio has a mute toggle, and starts only after a first tap or key press. [review]
- Nothing depends on vibration, which iOS Safari lacks. [review]

## Forms

- A field the form can't be sent without is marked `required` on its one field wrapper, which draws the asterisk and tells screen readers "(required)". [review]
- A field that always holds a value, such as a select with a default, isn't marked. [review]
- A field needed only sometimes is marked only while it is needed. [review]
- The field wrapper ties its help and error text to the control (`aria-describedby`), and the error sits beside the field. [review]
- A submit button stays enabled on an incomplete form, and pressing it says what is missing (see [components.md](components.md)). [review]
