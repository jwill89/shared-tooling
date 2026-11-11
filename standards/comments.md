# Comments

What a comment is for, and how each language writes its doc comments. A comment is read by the next person to change the code, so it says what they can't see in the code itself.

Each rule ends with how it is checked. The rest of the style for each language is in [code-style.md](code-style.md); [README.md](README.md) indexes the guide.

## What a comment says

- A comment describes the code beside it, as it is now: what it does where the code doesn't make that plain, and why it is written this way where that isn't obvious. The why is the valuable part: a constraint, an invariant, a unit, an edge case, a security or performance reason, or the bug a workaround avoids. [review]
- It gives the reason itself, never where the reason is written down. No comment points at a plan, a standards document, an audit, another project, a ticket, a person, or the date something was decided: `// A token can't make or revoke tokens, so a stolen one can't keep itself alive.`, not `// see security.md` or `// as myapp does`. [review]
- The one reference allowed is a project's own rules document (domain rules, a grammar), cited by its rule number, because the rule's text lives there and a copy would drift from it ([docs-and-agents.md](docs-and-agents.md)). [review]
- It describes the present. History (`now`, `used to`, `no longer`, `the old handler`, `was changed to`) belongs in the commit message and the CHANGELOG, whose entries are held to the same agnosticism ([docs-and-agents.md](docs-and-agents.md#what-a-changelog-entry-says)). [review]
- It doesn't restate the code or narrate the obvious, and says it in one line where one will do. [review]
- It is kept true: a change to the code updates its comments in the same commit. A comment that has gone wrong is a bug. [review]
- No commented-out code, and no `TODO` or `FIXME` in a commit: do the work, or write it in the project's plan. [review]
- A doc comment is written in full sentences. A comment inside a body may be a phrase. [review]
- Match the comment density of the surrounding code. [review]

## Where the same rules reach

- Text that becomes documentation follows them too: an OpenAPI description (huma's `doc:` tags, an operation's summary and description), a CLI's help, a setting's explanation in `.env.example`. Whoever reads it has only the text. [review]
- Generated code is never commented by hand: its comments come from its source, so the source's comments follow these rules. A sqlc query's comment becomes the generated method's doc comment; an OpenAPI description becomes the generated client's type comments. [review]
- Comments in config files (YAML, the Taskfile, workflows, `.editorconfig`, the lint configs) follow them as well. [review]

## Go

- Doc comments follow [Go Doc Comments](https://go.dev/doc/comment): the `//` comment directly above a declaration, with no blank line between, beginning with the name it documents (`// Hash returns the argon2id hash of password.`). [review]
- A package's doc comment, in one of its files, begins `// Package name`. [review]
- Other declarations are linked as `[Name]` or `[pkg.Name]`; lists, headings and code blocks use the doc-comment syntax, so `go doc` and pkg.go.dev render them. [review]
- A deprecated name has a paragraph beginning `Deprecated:`, saying what to use instead. [review]
- An exported name gets a doc comment only when the name doesn't already say it. [review]
- A directive (`//nolint:linter // why`, `//go:embed`) is not a doc comment; a `//nolint` always carries its reason. [review]

## TypeScript and Vue

- Doc comments follow [TSDoc](https://tsdoc.org): a `/** */` block above an exported function, type, interface, composable, store or store action, beginning with a one-sentence summary. [review]
- Tags carry no types, which TypeScript already has: `@param name - what it is`, `@returns`, `@throws`, `@example`, `@deprecated` (saying what to use instead), and `{@link Name}` for another declaration. [review]
- A component documents each prop and emitted event with a `/** */` comment on its member in the `defineProps` and `defineEmits` types, and says what the component is for in a comment at the top of `<script setup>`. [review]
- A template comment (`<!-- -->`) follows the same rules; Vue drops it from production builds, so it costs nothing to keep. [review]
- A comment that silences a check (`// eslint-disable-next-line rule -- why`, `// @ts-expect-error why`) always carries its reason. [review]

## PHP

- Doc comments are PHPDoc docblocks (`/** */`) with the tags of PSR-19. [review]
- Native types come first. A docblock adds only what a native type can't say: array shapes and generics (`@param list<int> $ids`, `@return array{id: int, name: string}`), `@throws`, `@template`. It never repeats a type the signature already has. [review]
- PHPStan reads docblock types, so a wrong one is a bug it reports. [lint: PHPStan]

## C\#

- Doc comments are XML documentation comments (`///`): `<summary>`, then `<param>`, `<returns>` and `<exception>` where they add something, and `<see cref="..."/>` for another member. An override or interface implementation uses `<inheritdoc/>`. [review]
- A member gets a doc comment only when its name doesn't already say it. The shared `.globalconfig` doesn't ask for one on every public member. [review]

## PowerShell

- A script, and each function a script or module exports, has comment-based help: `.SYNOPSIS`, `.DESCRIPTION`, a `.PARAMETER` for each parameter, and an `.EXAMPLE`, so `Get-Help` shows it. A deploy script's help documents its whole run ([docs-and-agents.md](docs-and-agents.md)). [review]
- Other comments are `#` lines, or a `<# #>` block for a long one. [review]

## SQL

- A query's comment sits between its `-- name:` line and the SQL, and says what the query returns or changes and why where that isn't plain; sqlc copies it into the generated method's doc comment. [review]
- A migration begins with a comment saying what it changes and why, since the file outlives the commit that brought it. [review]
