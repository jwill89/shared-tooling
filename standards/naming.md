# Naming

What things are called in every project: files and folders, components, Go modules and packages, code identifiers, tables and columns, API fields and paths, CSS classes and custom properties, and the rest.

Each rule ends with how it is checked. Where a name isn't covered here, match the surrounding code ([code-style.md](code-style.md)).

## Files and folders

- A Go package has one file per feature, named for it in lowercase (`raffles.go`, or `raffle_commands.go` when a big feature splits). A new feature gets a new file. [review]
- A Vue front end keeps reusable UI in `components/`, route pages in `views/` and the `useX` functions in `composables/`, beside `stores/`, `router/`, `types/` and `constants/`. [review]
- A new front-end feature adds a composable, a view or component, and a route. [review]
- Server units and files are named `<app>-<purpose>` (`myapp-queue.service`, `myapp-backup.timer`). [review]
- shared-tooling's folders are named `<purpose>/<target>` (`lint/go`, `test/a11y`). [review]
- A repo shared across projects has "shared" in its name (shared-tooling, shared-components-vue). [review]

Units, timers and the rest of the server side are in [deploy-and-ops.md](deploy-and-ops.md).

## Components

- A component's name is PascalCase and more than one word (`MediaGrid`), and its file takes the same name (`MediaGrid.vue`). [lint: ESLint vue/multi-word-component-names]
- A composable is named `useX` for what it gives (`useMedia`). [review]
- In a view, a control's id takes the view's name as a prefix (`login-email`). [review]
- In a component, a control's id comes from `useId()`, plus the row index inside a `v-for`. [review]

Which components to reach for is in [components.md](components.md).

## Go modules and packages

- An application module that nothing imports is named without a dot (`myapp`). [review]
- goimports' local prefix is the module's name, so the module's own imports form a group of their own. [lint: golangci-lint goimports]
- Packages are split by domain and named for it, in one short lowercase word (`media`, `tags`). [review]
- A sentinel error is `ErrX` and an error type is `XError`. [lint: golangci-lint errname]
- Enforced by revive's default rules in the shared golangci config: initialisms in one case (`userID`, `URL`), short and consistent receiver names, and error strings in lower case with no final full stop. [lint: golangci-lint revive]

## Code identifiers

- TypeScript types, interfaces, enums and enum members are PascalCase. [lint: ESLint @typescript-eslint/naming-convention]
- An unused variable, parameter or caught error starts with `_`. [lint: ESLint @typescript-eslint/no-unused-vars]
- A C# private field is camelCase, and a constant or static readonly field is PascalCase. [lint: .NET IDE1006]
- A PowerShell function is an approved verb and a singular noun (`Publish-Bundle`). [lint: PSScriptAnalyzer PSUseApprovedVerbs, PSUseSingularNouns]
- Environment variables start with the project's prefix (`MYAPP_`). [review]
- Browser storage keys share one app namespace (`<app>.theme`), and sit in the constants module. [review]

## Tables and columns

- Tables and columns are snake_case. [review]
- A named foreign key is `fk_<child_table>_<parent_table>`. [review]

The rest of the schema rules are in [database.md](database.md).

## API fields and paths

- URL path segments are lowercase kebab-case (`/tag-categories`, `/special-cards`). [review]
- JSON fields and query parameters are camelCase (`buildDate`, `?pageSize=50`), as JSON:API recommends. [review]
- A field maps to its snake_case column in the definitions, such as a Go struct's `json` and `db` tags or a PHP model's serializer. [review]
- In Go the `json` tag sets the field's name, and huma carries it into the spec and so into the generated front-end types. [review]
- Every API operation sets an explicit, readable verb-noun operationId. [review]
- An API error carries no code field of its own: it is an RFC 9457 problem body, named by its status, `type` and `title` ([api-and-realtime.md](api-and-realtime.md)). [review]

How the API is built is in [api-and-realtime.md](api-and-realtime.md).

## CSS classes and custom properties

- Enforced by the shared Stylelint config: class names and custom properties are kebab-case. [lint: Stylelint selector-class-pattern, custom-property-pattern]
- A reusable component's classes are BEM, `block__element--modifier`, with the component's name as the block (`.media-card__title`). [review]
- Every other class joins its parts with `-` (`.list-row-title`) and never uses `__`. [review]
- A modifier takes `--` in either form (`.badge--accent`). [lint: Stylelint selector-class-pattern]
- A state class takes `is-` (`.is-active`, `.is-open`), never a bare word such as `active` or `disabled`, which are also data values and HTML attributes. [review]
- A component's classes start with its full name in kebab-case, never an abbreviation (`.announcement-badge`). [review]
- Classes and custom properties are named for their role, never their look (`--panel-bg`, not `--gold`). [review]

The full CSS rules, tokens included, are in [css.md](css.md).

## Tasks and releases

- Taskfile tasks are lowercase, with `:` between a group and its task (`shared:update`, `package:windows`). [review]
- Every project that deploys runs it as `task deploy`, which deploys everything; a part that deploys alone is `deploy:backend`, `deploy:frontend` or `deploy:plugin` (see [deploy-and-ops.md](deploy-and-ops.md)). [review]
- A release is tagged `v` and its exact version (`v2.0.0`). No tag moves, so there is never a `v2`. [review]

Versions, releases and the changelog are in [docs-and-agents.md](docs-and-agents.md).
