# Security

What every project does to protect its accounts, its data and the droplet: headers, sign-in, access, input, rate limits, secrets and dependencies.

API statuses and the cache baseline are in [api-and-realtime.md](api-and-realtime.md); the droplet's own setup is in [deploy-and-ops.md](deploy-and-ops.md).

## Headers and CSP

- Every page is served with an enforced Content-Security-Policy built on `default-src 'self'`. [test]
- `script-src` never allows `'unsafe-inline'`. A script that isn't one of the app's own files, such as one Cloudflare injects, is admitted by a fresh 128-bit nonce per response. [test]
- `style-src` never allows `'unsafe-inline'`. Runtime styles come in through the same per-response nonce; Vue `:style` bindings need none, since they go through the CSSOM. [test]
- Every HTML route, `/index.html` included, goes through the code that sets the policy, so no copy of the shell is served without it. [test]
- The built app runs under the policy: no inline scripts (JSON-LD data excepted) and no `style=` attributes. [lint: eslint vue/no-static-inline-styles] [test]
- The policy is tested on the built app served the way production serves it, never on the Vite dev server, which sends none (see [testing.md](testing.md)). [test]
- The CSP names only the hosts the app uses. A new host is added on purpose, and a host no longer used is removed. [review]
- A third-party script is allowed when the CSP names its host, the script is pinned with Subresource Integrity or admitted by the nonce, and the privacy page names it. [review]
- A spec fails when a page loads a third party that the privacy page doesn't name. [test]
- A script pinned with SRI names one exact version, and its sha384 hash is recomputed on each upgrade. [review]
- Fonts and icons are self-hosted as woff2, never loaded from a font service. [review]
- No page loosens its CSP for one library. Code that needs `eval` or `new Function` (OpenCV.js) runs in a Web Worker served with its own policy and loaded only when needed. [review]
- A setting in `.env` turns the CSP to report-only without a deploy. When production blocks something, flip it first, then fix. [review]
- Every response, the SPA shell included, sends `X-Content-Type-Options: nosniff` and `Referrer-Policy: same-origin`. [test]
- Every page's CSP sets `frame-ancestors 'none'`. [test]
- HSTS is set at the reverse proxy. [review]
- A shared or unlisted page sends `X-Robots-Tag: noindex`. [review]

## Sign-in and sessions

- A browser signs in with a server-side session in a cookie that is HttpOnly, SameSite=Lax, Secure in production, and `__Host-` prefixed where the host allows. [test]
- A browser never holds a bearer token, nor anything secret in `localStorage`, and the first-party app uses no API keys. [review]
- Sessions live in the app's SQLite database. [review]
- Signing in moves the session to a new id. [test]
- A password change ends the account's other sessions, and this browser carries on under a new id. [test]
- A password change revokes the account's API tokens. [test]
- A password reset, or deleting the account, ends all of its sessions and revokes its tokens. [test]
- Every request loads the account behind its session, and the passkey it names where it names one, so deactivating an account, removing a passkey or changing a permission takes effect at once. [test]
- A deleted account's leftover session acts as a guest. [test]
- The server keeps only a SHA-256 hash of each session id, access token, share link and key it issues, so the database, its backups and its dev copies hold nothing that signs anyone in. [test]
- A token's plaintext is shown once, when it is made. [review]
- Sign-in, sign-up and password reset never reveal whether an account exists: a taken email answers like a new sign-up (and the owner is emailed), an unknown user gets the same answer after a dummy hash check, and passkey options carry stand-in credential ids. [test]
- Only a display name, which is public anyway, may be reported as taken. [test]
- Passwords are hashed with argon2id at 64 MiB, t=1, p=4 or stronger, stored as PHC strings, checked in constant time, and rehashed at sign-in when the parameters rise. [test]
- A password is at least 8 characters. [test]
- A password hash or key is selected only by the queries that need it, into a type that keeps it private behind `verify()` and `needsRehash()` and can't be serialized, so it never reaches an API model. [review]
- Admin is a role on a real account, never a shared admin password or a separate admin sign-in. [test]
- Sign-up never grants a role: a self-registered account starts with no rights. [test]
- The first admin comes from a command run on the host, which is also the break-glass. [review]
- An admin can't drop their own admin role or delete themselves. [test]
- The owner accounts named in config can't be demoted or deleted by anyone (403). [test]
- Removing an account's last way to sign in (its last passkey, its last linked provider, its password) is refused with 409 and a message saying what to set up first. [test]
- A passkey challenge waits in the server session for ten minutes at most, answers once, and belongs to the account or sign-in it was made for. [test]
- A passkey assertion's origin is checked against the allowed origins. [test]
- Adding a passkey to an account that has a password asks for the password. [test]
- OAuth asks for the narrowest scope (Discord's `identify`). [review]
- A provider's claims are read strictly: a boolean claim must be a boolean, so the string `"false"` is not verified. [lint: phpstan strict-rules] [test]
- Dev-only tooling sits behind `import.meta.env.DEV` and a dev-only dynamic import, so the production build strips it. [review]
- A dev sign-in works only when every configured origin is a local one. [test]

## Tokens for other clients

- A non-browser client uses a personal bearer token in `Authorization: Bearer` over HTTPS: shown once, stored hashed, revocable one by one, and rate-limited per token. [review]
- A token carries no more than its account's own roles and can't create or revoke tokens. [review]
- Cookie and token resolve through one middleware. [review]
- A native client gets its token through a browser loopback flow with PKCE: single use, expiring, a loopback-only redirect, and nothing to copy and paste. [review]
- A native client keeps its token encrypted (DPAPI for the current user on Windows, the OS credential store elsewhere), never in plaintext in a settings file, and forgets it on a 401. [review]
- A token never travels in a query string, except on a WebSocket upgrade, which can't send the header. [review]
- A secret link's token moves out of the address bar into a session by a redirect when the link is first opened. [review]
- Apache leaves secret-link paths out of its log, and the app's own logs redact them to a short hash. [review]
- A WebSocket or SSE connection is authorized when it opens, with the same check as its REST endpoint. [review]
- A WebSocket or SSE connection writes its own access line, refusals included, since it skips the request-log middleware. [review]

## Access control

- The server is the only security boundary. Every handler checks sign-in and role itself, through one helper or route group: 401 signed out, 403 without the role, and a mutating admin handler checks first of all. [test]
- Router guards, hidden UI and client-side gates are a convenience, never the check. [review]
- Another account's private resource, a private or expired item, or an unapproved submission answers exactly like an unknown id (404), never 403. [test]
- Role checks run before the record is looked up, so a refused request learns nothing about what exists. [test]
- A public response has its own type holding only public fields, so a column added to storage can't leak through it. [test]
- What a viewer may not see (staff-only fields, secret settings such as webhook URLs, figures that would reveal a private arrangement) is left out where the body is built, never hidden by the page or filtered route by route. [review]
- CSRF is stopped by an origin check, not tokens: a state-changing request is refused unless `Sec-Fetch-Site` and `Origin` (or, failing those, `Referer`) name an allowed origin. SameSite=Lax cookies back it up. [test]
- Go uses `http.CrossOriginProtection` for that check. [review]
- PHP runs the origin check outermost, before routing, the rate limiter and auth, so a refused request is neither counted nor told whether it is signed in. [test]
- CORS stays off unless a site needs it, and then echoes only origins from an explicit allowlist setting, never `*`. [test]

## Input and output

- Enforced by gosec in the shared golangci config, for Go: queries built from strings, file paths taken from input, weak random numbers and servers without header timeouts. [lint: gosec]
- PHP binds every SQL value through prepared statements or the query builder, and never pastes input into a query. [review]
- Anything random that users rely on (ids, tokens, shuffles) comes from a CSPRNG in every language. [review]
- The server validates input at every layer: the API schema (with a pattern on required text), the handler's invariants and the database constraints. [test]
- Numbers are capped so arithmetic on them can't overflow. [review]
- An upload's body is capped before it is read (`http.MaxBytesReader` in Go). [review]
- An upload's type is judged from its bytes, never from the browser's type or the extension alone. [review]
- The server decodes and re-encodes an uploaded image, which drops its EXIF data and bounds its pixel count. [review]
- An upload is stored under a random name and served with nosniff and its real type. [review]
- A private file lives outside the public folder and is served only by a handler that checks the reader. [review]
- A client-supplied folder, path or filename is validated, and its resolved absolute path must stay inside its base folder. [review]
- In Go, a path from a request is split and checked with `path` and plain string checks, never `path/filepath`, whose separators change with the server's OS: a backslash is refused everywhere, so the answer on a Windows dev machine is the one Linux gives. `filepath` joins the checked value to the base folder only after that. [review]
- An endpoint that writes files writes only allowlisted paths. [review]
- User-supplied HTML or SVG is sanitized on the server before it is stored or served, and again in the browser before `v-html`. [review]
- Otherwise `v-html` renders only the app's own static or generated markup, and each use carries `eslint-disable-next-line vue/no-v-html -- <where the HTML comes from>`. [lint: eslint vue/no-v-html]
- A redirect target the client supplies (a sign-in `next`, a native client's callback) is checked on the server: a same-site path with no control characters, or an exact loopback address. [test]
- An outbound request to a URL that users or admins set is checked at every hop: an allowlist of scheme and host when it is saved and when it is used, only public addresses (checked as each connection is dialled, DNS and redirects included), no redirect from https to http, and a file fetched only from a link the source gave. [review]
- An outbound call is never retried inline in a request; a scheduled job retries it. [review]
- Work that outlives its request runs after the commit, on a fresh context. [review]
- A failed call's error is kept without its URL's query string, so no key or id reaches a log. [review]
- Logs never carry tokens or secrets at any level, nor personal names or external ids above debug. [review]
- Each log line carries the request id. [review]
- Who changed what is kept in an audit table in the database (changed fields only, secrets redacted), never only in a log (see [database.md](database.md)). [review]
- A CSV export puts an apostrophe before a cell that starts with `=`, `+`, `-`, `@`, a tab or a carriage return, and starts the file with a UTF-8 byte order mark. [test]
- A feature keeps only the personal data it needs. [review]

## Rate limits

- Every sign-in, sign-up and token-issuing endpoint, and every anonymous write, is rate-limited per client address (an IPv6 client counted by its /64) and per key or token where one exists. [test]
- Each public endpoint has its own limiter, so a lookup can't spend the budget of the sign-up that follows it. [test]
- An anonymous write is bounded before its body is read: a size cap, per-address and global daily limits, nothing in it that can ping anyone, and a switch that closes it. [review]
- Cloudflare Turnstile, where a site uses it, fails closed: a missing, invalid or reused token is refused with 403, and Cloudflare out of reach is refused with 503. [test]
- An empty Turnstile secret switches Turnstile off with a line in the startup log. Local runs and tests go that way, or use Cloudflare's published always-pass test keys. [test]
- A trusted non-browser client passes Turnstile with a hashed, rate-limited key that opens nothing else, never with a bypass a bot could copy. [review]
- A Go `http.Server` sets `ReadHeaderTimeout`, `ReadTimeout` and `IdleTimeout`, and no global `WriteTimeout`, which would cut WebSockets and SSE streams. [review]

## Behind Cloudflare and Apache

- The visitor's address is restored once, in Apache: `mod_remoteip` trusts Cloudflare's `CF-Connecting-IP` only from Cloudflare's published ranges. [review]
- An app reads the address Apache gives it: a PHP app its `REMOTE_ADDR`, a Go service the last `X-Forwarded-For` entry, which is the one Apache appends. [review]
- An app never reads `CF-Connecting-IP` itself. [review]
- The list of Cloudflare's ranges is refreshed when Cloudflare changes it. [review]
- Other Cloudflare headers, such as `cf-verified-bot`, are hints for logs, never security decisions, since a client that reaches the origin directly can send them. [review]
- A response that differs by user, role or origin is never publicly cacheable, since Cloudflare ignores `Vary` and could hand one visitor's copy to another. [review]

## Secrets

- No secret is ever committed. `.env`, the deploy config and any real config file that holds one are git-ignored beside a tracked `.example` that documents each setting with an empty placeholder. [review]
- An SSH key lives outside the repo, named by its path. Personal values, such as an alert email, come from `.env` at deploy time. [review]
- shared-tooling is public: no host, key, token or personal value goes in it. Each comes from the project's git-ignored deploy config or its environment. [review]
- A Go service's production secrets live only on the droplet, in a root-owned 0600 `EnvironmentFile`. [review]
- A secret never goes in a unit's `Environment=` lines, which systemd shows to any local user, and never sits on the dev machine. [review]
- A secret that only the host needs is generated on the host. [review]
- Only the public folder is web-served. `.env`, the code, the database, private uploads and backups sit outside the web root, and a vhost never points at the app folder. [review]
- The deploy never uploads `.env` or the database. [review]
- Where a folder needs deny rules, they refuse dotfiles, databases, Composer files, archives and every script but the front controller. They are in place before the files they guard, and are tested with encoded, doubled-slash and dot-segment paths. [test]
- Maintenance scripts run from the command line only and refuse HTTP. [review]
- A private registry token (Font Awesome Pro) lives only in the machine's `~/.npmrc`. The tracked `.npmrc` holds only the registry and settings. [review]
- CI writes that token from a repository secret for the install and removes it before the project's own code runs. Dependabot gets the same secret, with the registry declared in `dependabot.yml`. [CI]
- Each key reaches only what it needs: an API key is restricted to its API and the droplet's address, development uses none or a second key restricted to the dev machine's address, and a cloud role reads and writes only its own items. [review]
- An exposed secret is rotated at once, or deleted if it is unused. A password that may have been exposed is reset to a fresh high-entropy value. [review]
- A copy of the live database pulled for development holds real accounts, hashes and tokens, so it stays on the dev machine, git-ignored. [review]

## Dependencies

The audit jobs each stack runs, and how packages are added and updated, are in [packages.md](packages.md).

- `npm audit` fails on high and above, for shipped packages only (`--audit-level=high --omit=dev`), in CI. It is the shared `web.yml` default. [CI]
- In CI, `composer audit` includes dev packages, since they run there and on developer machines. [CI]
- A security fix comes from the package itself. A framework's security release is applied even before the advisory database lists it. [review]
- A finding in code the app never runs waits for its package's own fix, never a forced version. [review]
- A public repo runs CodeQL, in its own `codeql.yml`, over its JavaScript or TypeScript, its C# (build mode none) and its workflows. CodeQL has no PHP support. [review]
- A security problem is reported privately to the maintainer, never in a public issue. [review]
