# Standards

The rules every project follows, for the owner and for every coding agent working in any of the repos. They were gathered from what the projects' own docs already said, and where those disagreed, the owner decided. A project's own docs keep only what is specific to it.

## Follow the published standard

Where a current, accepted RFC covers what you are building, follow it, since it is guidance the whole web already knows, and clients, proxies and libraries already expect it. This holds in every area of the guide, and for anything the guide doesn't cover yet.

- Current and accepted means a standards-track RFC (Proposed Standard or Internet Standard) or a Best Current Practice that no later RFC obsoletes: check the RFC Editor's entry for "Obsoleted by". An Informational or Experimental RFC, or an Internet-Draft, is guidance to weigh, not a rule. [review]
- Where a rule in this guide and an RFC seem to disagree, raise it with the owner, so the guide is corrected or the reason for the difference written down. [review]
- A project that departs from an RFC says so in its `AGENTS.md`, with the reason, as with any rule here. [review]
- Some that apply across the projects: RFC 9110 (HTTP methods, statuses and conditional requests), RFC 9111 (HTTP caching), RFC 9457 (problem details for API errors), RFC 6585 (429 Too Many Requests), RFC 8259 (JSON), RFC 3339 (timestamps), RFC 9562 (UUIDs), RFC 6265 (cookies), RFC 6749 and RFC 7636 (OAuth 2.0 and PKCE), RFC 9700 (OAuth 2.0 security practice), and RFC 8291 and RFC 8292 (Web Push). [review]
- For the web platform itself, the WHATWG and W3C standards play the same part, WCAG 2.2 among them ([accessibility.md](accessibility.md)). [review]

## How a repo uses this guide

- Each repo holds shared-tooling as a submodule at `shared/`, so this folder is `shared/standards/` there.
- A repo's `CLAUDE.md` imports two files, so Claude Code reads them at the start of every session, under a heading so markdownlint's first-line rule passes:

  ```markdown
  # CLAUDE.md

  Keep this project's rules in AGENTS.md, not here.

  @AGENTS.md
  @shared/standards/README.md
  ```

- A repo's `AGENTS.md` is its one deep guide, for agents and developers alike (see docs-and-agents.md). It links [`shared/standards/README.md`](README.md) near the top for agents that don't read `CLAUDE.md`, and it holds only what is specific to that project, its departures and its list of what isn't meeting the standards yet among them.
- Only this index is loaded every session. Before working in an area, read its file below; each is short, and the linters carry the detail.

## Where a project may differ

- Some rules leave the choice to each project and name the options, such as layout with Tailwind or with a stylesheet of object classes, or a cache header beyond the baseline. The project's `AGENTS.md` says which it takes.
- A project that must break a rule says so in its `AGENTS.md`, with the reason: that is a departure. A departure counts only when it states its reason; without one, the rule here wins over anything older in the project's own docs.
- Anything a project hasn't brought up to a rule yet goes in its `AGENTS.md` under a separate heading, "Not yet meeting the standards": one item per gap, saying what falls short of which rule and since when (`- Since 2026-11-13: no tsconfig.vitest.json for the specs (testing.md, Vitest).`). An item leaves the list in the change that closes it.
- A project meets the standards when nothing it falls short in is missing from that list, and the list is empty. A departure that states its reason doesn't stop it meeting them.
- A project that hasn't been rolled out onto shared-tooling yet still has old patterns. Its rollout brings it to these rules; until then, new code follows them.

## How each rule is checked

Every rule ends with how it is checked:

| Mark | Meaning |
| --- | --- |
| [lint: tool rule] | A shared linter config fails the build: ESLint, Stylelint, golangci-lint, PHPStan, PHP CS Fixer, the .NET analyzers, PSScriptAnalyzer or markdownlint |
| [axe] | Each site's end-to-end suite runs axe (`test/a11y`), which enforces WCAG 2.2 AA, the floor under the AAA target |
| [test] | A project's own tests hold it |
| [CI] | A shared workflow checks it on every push |
| [module] | The shared deploy module (`deploy/pwsh`) does it for every deploy |
| [review] | Nothing checks it automatically: the author and the reviewer do |

A rule a tool can check belongs in the tool's config as well, which keeps this guide short. When a rule marked [review] keeps being missed, move it into a linter.

## The guide

| File | Read it before working on |
| --- | --- |
| [code-style.md](code-style.md) | Code in any stack: Go, Vue and TypeScript, PHP, C#, PowerShell |
| [comments.md](comments.md) | Writing a comment or doc comment in any language, or text that becomes documentation (an OpenAPI description, a CLI's help) |
| [naming.md](naming.md) | Naming files, components, packages, tables and columns, API fields and paths, CSS classes |
| [api-and-realtime.md](api-and-realtime.md) | An API endpoint, its errors and OpenAPI spec, or a live feed (SSE or WebSockets) |
| [security.md](security.md) | Headers and CSP, sign-in and sessions, rate limits, client addresses behind Cloudflare, secrets |
| [performance.md](performance.md) | Anything a page or request has to do quickly: bundles, images, queries, caching |
| [database.md](database.md) | SQLite settings, migrations and schema |
| [deploy-and-ops.md](deploy-and-ops.md) | A deploy, a systemd service, backups and restores, the database pull, and what `docs/ops.md` holds |
| [testing.md](testing.md) | Tests of any kind: unit, HTTP, end-to-end, coverage floors |
| [packages.md](packages.md) | Adding or replacing a dependency |
| [css.md](css.md) | Styles: tokens and colour, units, class naming, layout, motion, themes |
| [components.md](components.md) | Building UI: reaching for the component kit, dialogs, lists, states |
| [accessibility.md](accessibility.md) | Anything a person sees or operates: WCAG 2.2 AAA as the target, AA as the floor |
| [docs-and-agents.md](docs-and-agents.md) | README, CHANGELOG, PLAN and decision logs, versions and releases, commits, and the rules for coding agents |

## Changing a rule

Edit the file here, note the change under `## [Unreleased]` in shared-tooling's `CHANGELOG.md`, and release as usual; a project takes the new rules with `task shared:update`. A new rule that a tool can check goes into that tool's shared config in the same change.
