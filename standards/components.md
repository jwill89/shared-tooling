# Components

How a Vue front end builds its UI: the component kit first, bespoke components only when justified, and how dialogs, lists, feedback and state behave.

## What the shared ESLint enforces

- `lint/web`'s base config and its `vueConventions` hold the Vue style guide: `<script setup lang="ts">` only, typed refs and template refs, macros in order, no required prop with a default, a `type` on every button, no static inline styles, no unregistered components, and no unused refs or needless binds and mustaches. [lint: eslint vueConventions]
- Props, emits and `v-model` are typed, and a generic control emits the option's own value, never a plain string. [CI]

Template accessibility rules are in [accessibility.md](accessibility.md), and the rest of the code style in [code-style.md](code-style.md).

## The kit first

- The component kit, shared-components-vue, replaces the split between Bulma, PrimeVue and hand-written components, so an app reaches for the kit first. [review]
- Once an app has adopted the kit, it uses the kit's component for every job one covers and drops its own copy. [review]
- Until then, the app's own one component for each job fills that role. [review]
- An app adopts the kit only after its shared-tooling rollout, and never in the same pass as a backend change, so its end-to-end suite checks one side at a time. [review]
- Once an app has moved, its ESLint config refuses the old library's imports (`bulma`, `primevue`) with `no-restricted-imports`; see [packages.md](packages.md). [lint: eslint no-restricted-imports]
- The app maps its palette onto the kit's semantic tokens in one file, so it keeps its own look. [review]
- Icons reach kit components through slots, and the app keeps its own icon setup. [review]

The kit covers dialog and confirm, toast, button and icon button, text, number and tag fields, form field, page header and panel, lightbox, select and combobox, switch and segmented control, tooltip, spinner and loading overlay, alert and empty state, and the Turnstile widget. Its second wave adds a data table, drawers, menus, a date picker, pagination and popovers. The kit's own design is in its repo's `PLAN.md`.

## When bespoke code is justified

- A component that belongs to one app, such as a game board, a card-spread editor or a book cover, is written in that app. [review]
- A component that a second app needs goes into the kit instead of being copied. [review]
- A widget the kit doesn't have yet is built on a Reka UI primitive, which supplies its roles, keyboard handling and focus management; those are never hand-rolled. [review]
- Reka's `TooltipProvider` is mounted once, at the app root; without it, a tooltip breaks its whole subtree. [review]
- A third-party widget's script, such as Turnstile's, loads once, and every instance shares it. [test]

## One component per job

- Within an app, each job has one component, and every page uses it. [review]
- A second way of doing a job is a refactor of the first, never a copy. [review]
- A form control's look is never re-declared on a page. [review]
- Markup that is about to be written a second time becomes a shared component with props and slots then, not at the third time. [review]
- A slot's wrapper renders only when the slot is filled. [review]
- Every page opens with the app's one page header (title, breadcrumb, actions) and puts its content in the one panel component. [review]
- Header, card and panel markup is never written by hand on a page. [review]
- A component is short enough to read without scrolling. [review]
- API calls live in the composable for their domain, and a new call extends it; a component never calls `fetch` itself (see [api-and-realtime.md](api-and-realtime.md)). [review]
- Route `meta` decides access and page framing, and guards read its flags to send the user to the first page they may see. [review]
- The menu hides what the account can't reach, and views load only data it may see; the server still checks every request (see [security.md](security.md)). [review]

## Lists and routes

- A record's identity goes in path segments (`/decks/12`, `/decks/12/cards/3`), never in the query string (`?id=12`). [review]
- A list's search, filters, order and page live in the URL, so a reload, Back or a shared link returns to the same view. [review]
- The query string holds only that list state: search, filter, order and page. [review]
- A new search or filter starts at page one. [review]
- Every list of records uses the app's one table component, which sorts and searches, until the kit's data table replaces it. [review]
- The table gets the whole list and does the filtering, sorting and paging itself; given only one page, a header click would reorder only the rows on screen. [review]
- A table wider than its panel scrolls inside the panel, never the page (see [css.md](css.md)). [review]
- A row's actions are buttons at its right end, never hidden behind a menu. [review]
- A choice among a few candidates, such as search results or covers, is a set of buttons, not a table. [review]
- A list's manual order is changed in one dialog, opened from the list's header. [review]
- That dialog works with a drag handle (pointer events, so a finger or a mouse), Up and Down buttons, the arrow keys, or A to Z, never with an order number on each record. [review]

## Making and editing records

- A new record is made in a dialog that asks only for what the record can't exist without, then lands on the record's page. [review]
- No app has a `/new` route. [review]
- A record is never created or edited in a panel opened inside a list page. [review]
- An editor holding unsaved work warns before the user leaves it. [review]
- A save or a cancel replaces the edit step in history, so Back doesn't return to it. [review]
- Removing a record sends the user back to the page before it. [review]

## Dialogs and confirmation

- Every modal uses the app's one dialog component, which locks scroll (counting nested dialogs), traps focus, closes on Escape and returns focus when it closes. [review]
- An irreversible action uses the dialog's alert-dialog form. [review]
- Only an irreversible or money-affecting action asks for confirmation. [review]
- It asks through the app's one themed confirm dialog (`await confirm(...)`), never `window.confirm`, and says how much it will remove. [review]
- Everything else takes one tap and can be undone. [review]

## Feedback

- A toast reports how a finished action went, globally, and then goes away. [review]
- A condition the person must act on is an alert, placed where it applies, which stays until it is resolved. [review]
- A field's error sits beside its field. [review]
- When the wording would suit either a toast or an alert, it is a toast, said once. [review]
- Toasts float above the page and alerts sit flat in it, so the two never look alike. [review]
- Uncaught errors reach the user as a toast, through one global handler (`app.config.errorHandler`). [review]
- The UI shows the server's error message as it arrives, with a fixed fallback only when there is none, and never re-words an HTTP status. [review]
- When a live feed drops, the page shows a banner and writes fail loudly; nothing is queued offline. Reconnecting is in [api-and-realtime.md](api-and-realtime.md). [review]

## Loading, empty and failed

- Loading, empty and failed are three different states. [test]
- A failed load says "Couldn't load …" with a Try again button, never the empty state. [test]
- A list that is still loading never says it is empty. [test]
- A failed request never shows a success notice. [test]
- A failed data load after sign-in is never reported as a rejected sign-in. [test]
- Each async action has its own loading flag, which shows its spinner and disables its button while it runs. [review]
- A button is never greyed out because the form is incomplete; pressing it says what is missing. [review]
- UI that depends on settings or on sign-in waits for them before it renders, so a default never flashes (`v-cloak` on `#app` until the app mounts). [review]
- An optimistic change, such as a reorder, shows at once, saves in the background, and reverts if the save fails. [review]

## Sign-in in the UI

- A 401 on any request sends the user to sign-in with a "session expired" notice. [review]
- The sign-in calls opt out of that, so a wrong password reads as a wrong password. [review]
- A closed or cancelled passkey prompt is not an error, and leaving the page cancels a pending one. [review]
- The username field offers saved passkeys (`autocomplete="username webauthn"`). [review]

The rest of sign-in is in [security.md](security.md).

## State, storage and offline

- A preference about a screen or device (a folded menu, units, the colour scheme, infinite scroll) is kept in the browser through one helper, not on the server. [review]
- The site still works when browser storage is blocked. [test]
- A form's Reset returns every field to its default, so nothing typed earlier, such as a password, carries over. [test]
- A service worker never caches an API answer or anything that differs per viewer; what it may cache (content-hashed files, thumbnails, and an installable app's shell) is in [performance.md](performance.md). [review]
- Nothing is queued offline to send to the server later. [review]

## Acting for the user

- Nothing is chosen for the user: a lookup's or a search's suggestion applies only when the user picks it, even when the first match looks right. [review]
- A page that may play sound unlocks audio on the first tap or key press, since browsers play nothing before a gesture. [review]

## Words in the UI

- A page is named for what it manages ("Locations", not "Rooms & Booths"). [review]
- Each kind of value (money, times, lengths) is written by one formatter, never formatted in place. [review]
- A code people read aloud is short and leaves out look-alike characters (`0`, `O`, `1`, `I`). [review]
