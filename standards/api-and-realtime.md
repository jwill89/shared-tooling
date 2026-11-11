# API and real-time

How every project's HTTP API, its OpenAPI spec, its generated client and its live feeds are shaped, in Go and PHP alike.

Where an RFC describes a behaviour, the API follows it ([README.md](README.md) says which RFCs count): RFC 9110 for methods, statuses and conditional requests, RFC 9111 for caching, RFC 9457 for error bodies. Sign-in, access and limits are in [security.md](security.md); static files and the app shell are in [performance.md](performance.md).

## Paths and methods

- Every endpoint sits under one base path: `/api/v1` in a Go service, `/api` in a PHP site. The examples below write it `/api`. [review]
- Endpoints are resource-shaped and shared by every client (the SPA, a plugin, a native app). No endpoint exists for one screen. [review]
- A report is a filter on its resource (`?from&to`), not an endpoint of its own. [review]
- A collection is a plural noun (`/api/decks`), an item is `/api/<resource>/{id}`, and a sub-collection nests (`/api/<resource>/{id}/<subs>/{subId}`). [review]
- Path segments are kebab-case. [review]
- JSON fields and query parameters are camelCase. Tables stay snake_case, and the server maps between them in its definitions (see [naming.md](naming.md) and [database.md](database.md)). [review]
- A trailing slash is accepted and answers the same as the path without it. [test]
- `GET` reads. [review]
- `POST` creates, answering 201 with the new resource, or runs a command. [test]
- `PUT` replaces the whole resource, as RFC 9110 defines it. A request that changes only some fields is a `PATCH`. [test]
- `PATCH` changes only the fields it sends, including flipping a flag or a single reorder. [test]
- `DELETE` removes and answers 204 with an empty body. [test]
- A state change that isn't CRUD is `POST /api/<resource>/{id}/<verb>` (`…/close`, `…/approve`). [review]
- A bulk write is a `POST` verb (`…/reorder`, or `POST /api/media/bulk-delete` with the ids in the body). [review]
- Deleting everything, optionally narrowed by a query filter, is `DELETE /api/<resource>/all` and answers `{ "deleted": N }`. [review]
- Signing in and out, sign-up and every other credential ceremony are operations under the base path's `auth/` (`/api/v1/auth/*`), in the spec like any other endpoint, and are the one exception that stays action-shaped (`POST /api/v1/auth/login`, `POST /api/v1/auth/passkey/finish`). Adding a credential to a signed-in account is resource-shaped (`POST /api/v1/me/passkeys`). [review]
- In a PHP router, a route with a fixed segment (`/media/random`) is registered before a route with a parameter in that place (`/media/{id}`). [review]
- A PHP app has one controller per resource, matching its route group and taking only the dependencies its methods use. [review]
- A PHP app is built in a factory kept apart from `index.php`, so each test can build its own. [test]

## Requests and responses

- A request body is JSON (`application/json`), and an upload is `multipart/form-data`. [review]
- A success body is the resource (a create or an update returns it), a list, or `{ "success": true }` for a command. [test]
- A list carries what its view shows, so the page needs no second call, and nothing more (no sub-entities). [review]
- A detail read can fold in a related collection with `?include=`. [review]
- An action that needs the whole item loads the detail first. [review]
- A read by many ids sends them comma-separated in `?ids=`, the form huma reads, and the API client sets that once. [review]
- A list of ids too long for a URL goes in a `POST` on its own exact route (`POST /api/media/by-ids`). [review]
- A value over a limit is refused with 422, never clamped quietly. [test]
- A result set the server caps carries a `truncated` flag. [test]
- A change never breaks a client that has shipped, such as a plugin: the old response stays when a new parameter is absent, or the client updates first, and an old path goes only after that. [review]
- A rate limit or cooldown is enforced on the server, answers 429 with `Retry-After`, is mirrored in the client and is noted on its endpoint in the spec. [test]

## Paging

- An infinite scroll or a feed pages by cursor: each page carries `nextCursor`, and the client asks for the next page with `?cursor=`, so items added meanwhile don't repeat. [test]
- A paged table takes `?limit&offset`, with `limit` at most 100, and sends the total in `X-Total-Count`. [test]

## Caching

Each project sets its own cache headers, starting from this baseline. A project that differs from it says how and why in its `AGENTS.md`.

- A response that differs per viewer or needs sign-in sends `Cache-Control: private, no-store`. [test]
- A public read sends `Cache-Control: no-cache` with an `ETag`, and answers a matching `If-None-Match` with 304 and no body. [test]
- A public read that changes slowly may send `Cache-Control: public, max-age=N`, and the project's `AGENTS.md` says why. [review]

## Errors

- Every error is an RFC 9457 problem details body, `application/problem+json`, which is huma's default, except on an operation a browser navigates to (below). A PHP app sends the same shape. [test]
- `detail` holds a message a user can read that says why. [test]
- A failed validation lists each broken field in `errors`, each entry with `message` and `location`, as huma sends them. [test]
- The UI shows that message (a toast, with field errors inline) and never a raw error. [review]
- 400 answers a request the server can't parse, such as malformed JSON. [test]
- 401 means not signed in. It is a problem details body, never a redirect to a sign-in page, and the client treats it as signed out, except from the `auth/` operations, where it is a sign-in that failed and stays with the page that tried it. [test]
- 403 means signed in but not allowed. A wrong current password, when changing it or deleting the account, is 403 too. [test]
- 404 answers an unknown id and anything the requester may not see, so ids can't be probed. [test]
- 409 answers a conflict: a duplicate, a taken code, or a row that has moved since it was read. [test]
- 422 answers a failed validation: a missing field, a value out of range, or a reference to nothing. [test]
- 429 answers a rate limit, with `Retry-After`. [test]
- A client error is never a 500 or a false success. [test]
- Every API error is problem details whatever the request's `Accept`, the framework's own 404, 405 (keeping `Allow`) and 500 included. [test]
- An operation a browser navigates to rather than calls, such as an OAuth provider's start and callback (`GET /api/v1/auth/<provider>/callback`), answers 302 with `Location` whatever happens: a failure, a rate limit included, redirects to the sign-in page with `?error=` and a reason the page knows, since a navigation can't show a problem body. The spec declares the 302 and its `Location`, and the operation's inputs carry no constraint the framework would refuse first. [test]
- The SPA fallback route never matches `/api/…`. [test]
- In production an unexpected exception answers only a generic message. Its own message and chain go out only in development. [test]
- A real exception is logged in full. A 404 or 405 is logged without a stack trace, so scanner traffic doesn't bury the real errors. [review]
- The API never answers 502 or 504, because Cloudflare swaps such a body for its own page. An upstream failure answers 429 (rate limited upstream), 500 (credentials or config) or 503 (unreachable). [review]

## OpenAPI

- The spec is OpenAPI 3.1, generated from code. Every Go service generates it with huma. [CI]
- A PHP site generates its spec from code too (swagger-php attributes on controllers and schema classes, in custom PHP or Laravel) and follows the same conventions as the Go services. [CI]
- The spec is committed, and CI fails when it drifts from the code. [CI]
- Every body has a named schema that its endpoint references, never a bare `object`, and every property is described. [review]
- A type used only inside the server gets no schema. [review]
- Each operation declares its error responses as problem details. [review]
- A test checks each documented 2xx response against the spec. [test]
- The spec states exactly what the API sends: a field is optional only when the API omits it, and a field that can be null is marked nullable, so strict generated clients (C#) accept the responses. [test]
- After a spec generator upgrade, the new spec is diffed against the committed one. operationIds may change; paths and schemas may not. [review]
- The API contract carries its own version, apart from the app's, and it moves only when the API surface changes. [review]
- With huma, every response struct sets `Status` explicitly, because a zero panics the server. [review]
- With huma, every type embedded in a response is exported, because huma silently drops unexported embedded fields. [review]
- With huma, a sign-in operation reaches the session through its context (scs's `LoadAndSave` around the mux), so it needs no `Set-Cookie` output, and nothing outside the API signs anyone in. [review]

## Front-end client

- Front-end API types are generated from the committed spec with openapi-typescript (`npm run gen:types`), committed, and never edited by hand. [CI]
- The types are regenerated after each spec change, and CI checks they are current. [CI]
- Each entity the API sends is re-exported from the generated file. Only client-side shapes are written by hand. [review]
- API calls go through one framework-free client module, called from composables. No other file calls `fetch(`, which a project's own lint rule can hold by refusing `fetch(` anywhere else. [review]
- A caller that must tell failures apart gets a discriminated result (`ok`, `status`, `error`, `data`, `networkError`). [review]

## Writes and retries

- Two racing requests can't both succeed. A state change is a conditional update (`UPDATE … WHERE status = 'requested'`), and the loser gets 409. [review]
- An external side effect is claimed before it runs (`pending`, then `posting`, then `posted`). A failed one goes back to its prior state, and an ambiguous one tells staff to check before retrying. [review]
- A save can't silently undo someone else's change: a `PATCH` sends only the fields it edits, and a `PUT` carries the row's `updatedAt` and is answered 409 if the row has moved. [test]
- A write that a client may retry carries an idempotency key, checked inside the write transaction. [review]
- A retry from the same caller gets the original row with 200 (the first answer was 201), and the spec declares that 200. [review]
- An outbound send is saved with its outbox entry in one transaction and kept until the receiver confirms. [review]
- A failed send is retried with back-off (30 seconds up to 15 minutes, or the scheduler's next tick). A permanent 4xx other than 401, 403, 408 or 429 is set aside, not retried. [review]
- Scheduled work runs in-process, on a context that shutdown cancels, never from cron. [review]
- A scheduler sweeps once at startup, leaves unconfigured items pending, and keeps its cursor through a failure. [review]
- A long scan runs on a time budget, saves its progress, and marks a unit done only once it is fully scanned. [review]
- A feed that posts somewhere first records what is already there without posting it, on its first run and whenever its filters change. [review]
- A user's wall-clock time is stored with its IANA zone and the UTC instant it computes to. Recurrence runs in that zone, so it survives DST. [review]
- Go code that works with zones blank-imports `time/tzdata`. [review]

## Outbound calls

Checks on URLs that users or admins set are in [security.md](security.md).

- In Go, outbound HTTP calls share one client with a timeout (15 seconds) and are built with `http.NewRequestWithContext`, so a shutdown or a client disconnect cancels them. [lint: golangci noctx]
- A keyed or CORS-restricted third-party API is called through a server-side proxy, so the key stays a server setting and the field mapping lives in one place. [review]
- A third-party list that rarely changes is cached, with a fallback. [review]

## Real-time

### Choosing the channel

- WebSockets carry frequent two-way traffic: games, chat, live collaboration. [review]
- SSE carries the server's word that something changed. The browser still reads and writes over REST. [review]
- REST covers everything else, since it keeps HTTP caching. [review]
- A PHP site holds no stream: PHP-FPM can't hold a WebSocket, and an SSE stream ties up a worker that other sites share. Its live traffic goes through a small Go service beside it, which the PHP app hands a short-lived signed ticket. [review]

### Events

- Writes stay on REST, or are intents that a game sends over its socket. [review]
- The server validates and persists, then broadcasts. Clients reconcile from what it sends and never poll or hold the real state. [review]
- A change feed is an in-process hub that the handlers publish to after a write commits, so no event goes out for a write that rolled back. [review]
- A WebSocket event carries the new state, so the HTTP response and the broadcast carry the same truth. [review]
- An SSE event names what changed, and the client refetches it over REST, so REST stays the one way data is read. [review]
- An SSE client may gather events for a moment and refetch only the records they name. [review]
- Every SSE event has the same envelope: `id`, `type`, a scope id, `at`, and a `payload` object, which is `{}` when empty and never null. [review]
- Socket messages are one declared union of JSON message types, typed on both sides (Go and TypeScript), and the protocol carries a version both sides check, so a client out of step with its server says so rather than misreading messages. [review]

### Connections

- A live feed takes the same sign-in as the REST API and is authorized when it opens (see [security.md](security.md)). [review]
- A viewer with nothing to follow gets no feed. [review]
- A long-lived connection sends a heartbeat every 25 seconds, inside Apache's 120-second proxy timeout and Cloudflare's 100. [review]
- On SSE the heartbeat is a named `ping` event, not a comment, because a page can't see comments. [review]
- A client keeps one stream per tab. [review]
- A client reopens a stream that dropped, went silent or was given up by the browser, with back-off from 1 second to 16, and checks again when the tab wakes. [review]
- A client catches up from its last event id or cursor, refetches state when it can't, and never takes a failed read for a state change. [review]
- A new stream starts a few seconds back, so nothing made between a page's fetch and its stream opening is lost. [review]
- A cursor outside the kept window is told to fetch everything. [review]
- A record changed several times between looks is sent once. [review]
- A server shutdown ends open streams. [review]
