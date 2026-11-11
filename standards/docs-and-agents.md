# Docs and agents

What each repo doc holds, how docs and copy are written, how a change goes from commit to release, and the rules every coding agent follows.

## What each doc holds

- **README.md** is the overview for a first orientation; where a product has users, it is also the manual of every feature, command and setting. [review]
- **AGENTS.md** is the repo's one deep guide, for agents and developers alike, and is read before any change. [review]
- AGENTS.md gives the conventions with their reasons, a "known traps" list naming the failure each trap prevents, and a recipe or checklist for each common change (an endpoint, a field, a setting, a feature) that new work is run against. [review]
- AGENTS.md links to `shared/standards/README.md`, for agents that don't read CLAUDE.md. [review]
- **CLAUDE.md** imports `@AGENTS.md` and `@shared/standards/README.md`, and the repo's own rules live in AGENTS.md. [review]
- **CONTRIBUTING.md** only says how to propose and submit a change: how to report a bug (steps, expected, actual, environment), and to open an issue before anything beyond a small, obvious fix. [review]
- **CHANGELOG.md** is the only changelog. It lists what a user could notice, and any deploy that changes behaviour; for shared-tooling, a user is a project that takes the release. What an entry says is under [What a changelog entry says](#what-a-changelog-entry-says). [review]
- Git history, subjects and bodies, is the record of every change, so there is no second changelog file. [review]
- CHANGELOG.md follows Keep a Changelog: an `## [Unreleased]` section at the top collects bullets under Added, Changed, Deprecated, Removed, Fixed or Security, and a release turns it into `## [x.y.z] - YYYY-MM-DD` with a compare link. [review]
- An app that shows its changelog reads CHANGELOG.md at build time: there is no changelog table, hand-written page or API. [review]
- **PLAN.md** holds the product decisions, the data model and the phase order, and is read before anything structural changes. [review]
- A feature that doesn't fit the plan changes PLAN.md first, in the same change. [review]
- A repo's own plan covers only what is specific to it, and links to shared-tooling's `standards/` rather than repeating them. [review]
- **docs/decisions.md** gets a dated one-line entry (`- YYYY-MM-DD — ...`) for each decision worth remembering; the reasoning behind a larger one goes in PLAN.md. [review]
- **API.md** holds only the conventions; the endpoint list is the OpenAPI spec generated from code, served with an interactive reference (see [api-and-realtime.md](api-and-realtime.md)). [test]
- Each OpenAPI operation's description states its guard: public, auth, admin or `permission:<key>`. [test]
- Where a project has a rules document (domain rules, a grammar), it is authoritative, and code comments and tests cite its numbered rules. [review]
- A rule changes in the rules document first, then in the code and tests, in the same commit. [review]
- `.env.example` lists every setting with an explanation. [review]
- A deploy script documents its whole run in comment-based help, read with `Get-Help .\scripts\deploy.ps1 -Full`. [review]
- An audit or work list orders its sections by risk and tags each item with impact and effort, plus a Where, a Fix and a Verify step. [review]
- An audit records each measurement with the command that produced it, and lists the claims that failed verification so nobody chases them again. [review]

## What a changelog entry says

- A CHANGELOG is a list of changes, not a document: one bullet per change a user could notice, in a sentence or two, saying what changed as the user meets it. How it was built, the design behind it and the options weighed belong in the commit and the plan. [review]
- It is project-agnostic, as a comment is ([comments.md](comments.md)): no entry names another project, a plan, a standards document, an audit, a ticket, a person, or the date something was decided. A change made to follow the shared standards says so in shorthand: `Adopted the shared comment standard.`, not `Comments follow shared-tooling's standards/comments.md, as myapp's do.` [review]
- It gives no instructions: no deploy steps, commands, checklists or how-tos. A release that needs a step at deploy says so in one line and points to the steps, which are in the project's `docs/ops.md` ([deploy-and-ops.md](deploy-and-ops.md)): `Needs a one-time step at deploy (docs/ops.md, Upgrading to 5.2.0).` [review]
- It leaves out what no user could notice: refactors, renamed internals, tests, coverage, lint and CI. A change of that kind is listed only for what a user sees or does differently (a new required setting, a renamed flag, a removed endpoint). [review]
- It names what the user knows (a page, a setting, a command, a flag, an endpoint, a message), not file paths, packages, functions or tables, unless that is what the user touches. For shared-tooling, whose users are projects, a workflow input, a task or a module function is exactly that. [review]
- A fix says what was wrong as the user saw it, not its cause in the code. [review]
- Released entries follow the same rules: one that doesn't is cut to fit, keeping its version and date. [review]

## Keeping docs true

- Each rule lives in one document and the others link to it, because two copies drift. [review]
- Docs change in the same change as the code. [review]
- Docs name no removed feature, missing file or wrong file name, and describe shipped features as shipped. [review]
- A deliberate trade-off, or a change to recorded behaviour, is written down with its reason in the plan or the doc it concerns, so nobody "fixes" it back later. [review]
- A code rule's reasoning also sits in a docblock where the rule applies. [review]
- Every lint suppression or tool skip states its reason where it is written (see [code-style.md](code-style.md)). [review]
- A measurement or version check in a doc says when it was made. [review]

## Markdown and copy

- Markdown is linted by markdownlint-cli2 with the shared `lint/markdown` config, over every `.md` file in CI (`docs.yml`) and locally with `task shared:lint:md`. [lint: markdownlint]
- A repo's `.markdownlint-cli2.jsonc` extends the shared config and adds only its own globs and ignores. [review]
- A paragraph is one line, with no hard wrap, since Markdown sets no line length. [review]
- An error message says what happened and what to do next. [review]
- User-facing copy is plain and specific, in the owners' voice, with no jargon and no marketing clichés. [review]
- Console copy is short and imperative. [review]
- A destructive action asks first and says what it will remove. [review]
- Menu labels and page titles are in title case; all other text is in sentence case. [review]

## Working in a repo

- Before a change is done, `task check` passes locally: it runs what CI runs, in CI's order. [CI]
- `task lint` runs every lint and static check, the shared-file checks included, and `task check` adds the audits and every test. [review]
- Every repo has a root Taskfile with `task lint`, `task test`, `task check`, `task deploy` where it deploys, and shared-tooling's `shared:*` tasks; `task` alone lists the rest. [review]
- A check every project should run goes into shared-tooling and arrives by a release. [review]
- A project-only check is wired into both `task check` and the repo's own CI job, so a green CI means the local checks passed. [review]
- CI runs on every push to `main` and every pull request, calling shared-tooling's workflows by name at the tag `shared/` holds, then the repo's own jobs. [CI]
- A fresh clone runs `git submodule update --init`, or clones with `--recurse-submodules`, before anything builds. [review]
- `shared/` moves to another release only with `task shared:update -- vX.Y.Z`, which moves the submodule and every workflow ref together, re-syncs `.editorconfig` and `.gitattributes`, and reinstalls the packages. [CI]
- That update is reviewed and committed as one change, `package-lock.json` included. [review]
- `.editorconfig` and `.gitattributes` come from `shared/repo`, with the repo's own lines only below the project marker. [CI]
- Files are LF, and a CRLF complaint is never "fixed" by changing `core.autocrlf`. [CI]
- Build output, dependencies, caches, `.env`, `deploy.config.ps1`, local database copies and C#'s `bin/` and `obj/` stay out of git. [review]
- Nothing secret is committed, and host details live in the ignored `deploy.config.ps1` (see [security.md](security.md)). [review]
- Regenerated files the repo tracks (the OpenAPI spec, the front end's API types) are committed with the change that caused them. [test]
- Commits are small and focused, one logical change each; an unrelated cleanup goes in its own commit. [review]
- A commit message is a subject line, plus a body when the diff doesn't show why. [review]
- The subject is short, imperative and specific: `Add a rate limit to the sign-in form`. [review]
- An app adopts the component kit only after its shared-tooling rollout, never in the same pass as a backend change, so its end-to-end suite checks one side at a time (see [components.md](components.md)). [review]
- A phase or milestone isn't done until a cleanup pass over what it added has run, for reuse, simplification, efficiency and altitude, removing dead and doubled code so each thing is done one way. [review]
- Whatever the cleanup keeps on purpose is recorded with its reason. [review]
- A large change gets an independent second reader before handover. [review]
- Every review or audit finding is checked against the code before anything changes, and is dated or marked unverified. [review]

## Versions and releases

- A repo carries one app version, read from one place, and everything that shows the version reads it from there. [review]
- A Dalamud plugin keeps its own version, in its csproj `<Version>` and its manifest, as Dalamud needs, and bumps it on every release so Dalamud offers the update. [module]
- The version bump and its CHANGELOG section go in the same commit. [review]

### Choosing the bump

These apply alike to an app, a service and a plugin's own version.

- Major: something outside the app that relies on it must change, such as its public API or plugin contract, a data format others read, or a removed feature. [review]
- Minor: a new feature, or any change a user notices. [review]
- Patch: a fix that changes no behaviour anyone relies on. [review]
- When a change fits more than one, the highest applies. [review]
- shared-tooling uses the same test, with the projects as what relies on it: major when a project must change its own files to take the release, minor for new rules, tasks or features (a new lint rule may raise findings), and patch for fixes that change nothing a project relies on. [review]
- A coding agent proposes the bump with its reason, and the owner confirms it before it lands. [review]

### Tags and releases

- CI makes the release tag and the GitHub Release on a green push to `main` that bumps the version; an app is never tagged by hand. [review]
- The release job runs only after every gate job passes, skips a version already released, and publishes that version's CHANGELOG section as the release notes. [review]
- The release job gets `contents: write` at job level, while the workflow default stays `contents: read`. [review]
- Where a tag is made by hand (shared-tooling's `task release`, or a project with no CI release yet), a lightweight tag is fine. [review]
- A hand-made tag is pushed by name (`git push origin vX.Y.Z`), since `--follow-tags` skips lightweight tags. [review]

## Rules for coding agents

- An agent never runs `git commit`, `git tag` or `git push`, or creates a repository, without the owner's explicit permission for that action, each time: it prepares the change and waits. [review]
- Pruning branches, worktrees and stashes is the owner's job. [review]
- Work happens on `main`, with no branches. [review]
- CI on GitHub is the gate, and no local pre-push or other git hook runs the checks. [review]
- A small change rides along to the next real version rather than getting a release of its own. [review]
- An agent never reads a project's deploy config, `.env` files, development databases or other secrets. [review]
- An agent deploys or connects to production only when the owner asks; even then it asks before connecting, even to read logs, and changes nothing there unasked. [review]
- Each pass starts from a clean tree, with the last pass committed or stashed by the owner, so each diff stays reviewable. [review]
- A large change runs one phase per session. [review]
- Each phase or work item ends in a "Done when" or Verify check, ticked only when that check passes. [review]
- Product decisions go to the owner; the agent doesn't make them. [review]
- A finding that is really a product decision is asked about, not suppressed or skipped. [review]
- Rules that conflict go to the owner as a list to decide; the agent doesn't pick. [review]
- Anything built on an unconfirmed assumption is listed in PLAN.md's open questions with how it was built, and told to the owner on delivery. [review]
- A question about where something lives in the UI is asked with the screen in view: a screenshot or a drawing. [review]
- A removal is confirmed in plain words, never inferred from an answer about something else. [review]
- A removal the owner must confirm is left for them to do in the app, never done by a migration. [review]
- A paid service is named with its price and put to the owner as a cost before it goes into a plan. [review]
- Other projects are references for tooling and host mechanics only: nothing is copied from one for being there, and departing from them is expected wherever it is cleaner. [review]
