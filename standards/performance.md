# Performance

How every project stays fast on one small droplet and on visitors' phones: measuring, the server, caching, the front end and images.

API cache headers start from the baseline in [api-and-realtime.md](api-and-realtime.md). SQLite settings and queries are in [database.md](database.md), and the droplet's setup is in [deploy-and-ops.md](deploy-and-ops.md).

## Measure first

- Measure before optimizing: on the droplet, cold and cached, or on a copy scaled to the size expected. [review]
- Fix what the measurement shows, and keep the simple path otherwise. A whole-table `json_extract` is fine below tens of thousands of rows. [review]
- A risky choice, such as a new encoder or a heavy library, is settled by a timed spike with pass thresholds written down before it runs. [review]
- Every visitor gets the same page: no user-agent sniffing to serve crawlers something else. [review]

## The droplet

- Memory is the droplet's tightest resource, so a fix that saves memory there comes before other performance work. [review]
- Heavy work is bounded on the droplet's one vCPU: image encoding runs one job at a time, behind a gate with a timeout. [review]
- A scan runs in a fixed-size worker pool, throttled by its client's rate limiter. [review]
- A finished result, such as a past period's figures, is cached rather than recomputed. [review]
- Apache runs the event MPM with PHP-FPM, never prefork with mod_php. [review]
- Xdebug stays off in production. Turned on to debug, it goes off again: `phpdismod`, then restart PHP-FPM and any queue worker. [review]
- Each open SSE or WebSocket connection holds an Apache worker thread while it is open, which matters only with many viewers at once. [review]
- A PHP site never holds a stream open in PHP-FPM; its live traffic goes through a small Go service (see [api-and-realtime.md](api-and-realtime.md)). [review]

## Static files and caching

The headers each kind of static file gets, and purging at Cloudflare, are in [deploy-and-ops.md](deploy-and-ops.md).

- The HTML shell is revalidated on every visit (`no-cache`), so a returning browser never boots a shell that names deleted bundles. [review]
- Cache headers on static files are set for 2xx answers only (Apache `Header set` without `always`), so an error is never cached at the edge. [review]
- A missing static file answers 404, never the SPA's page, because Cloudflare caches by file extension and would keep that page as the file. [test]
- A server-side cache is cleared exactly by the writes that change it. [review]
- Where a cache store has no tags, each group's version number is part of its keys, and a write that skips the model's events bumps the version by hand. [review]

## Front end

- Every route view but the landing page is a lazy `import()`. [review]
- Vendor code sits in a few named chunks (`manualChunks`) that stay cached across routes. [review]
- After a deploy, `router.onError` recovers from a stale chunk's 404 with one full load of the target, guarded against loops in `sessionStorage`. [review]
- A heavy library or data set (an editor and its CSS, Konva, markdown-it, OpenCV.js) loads on first use, from the chunk that needs it. [review]
- Anything always on screen that draws on such a data set uses a light index of it instead. [review]
- Font Awesome uses the SVG core, with only the icons in use added to its library, rendered by `<font-awesome-icon>` and never by `dom.watch()`. [review]
- A service worker never caches an API answer or anything that differs per viewer: API requests go straight to the network, so data is never served stale. [review]
- It may cache content-hashed build files and media thumbnails cache-first, since a changed file gets a new URL and a cached copy can never be stale. [review]
- It doesn't cache the app shell (`index.html`), so a deploy is never served stale. An installable app may precache its shell through Workbox's versioned precache with `registerType: 'autoUpdate'`, so the next load after a deploy takes the new version. [review]
- A service worker's precache holds only what a public visitor can reach, found by walking the bundle graph, not by a filename glob, and a build check fails when the precache holds a file only a signed-in page loads. [test]
- A service worker registers in production builds only. [review]
- A picker searches the server, never loading a whole collection into the browser. [review]
- A large list pages, searches and sorts on the server, unless a measurement at the expected size shows the browser copes. [review]
- A list the browser receives whole sends an `ETag`, so an unchanged list costs an empty 304. [test]
- A large JSON response goes compressed in transit. [review]

## Images

- Served images are WebP or AVIF. [review]
- The server keeps a master of each image and makes every served size from it, such as a display size and a thumbnail. [review]
- Lossy derivatives are encoded at quality 80 to 82. [review]
- An image that can start off-screen gets `loading="lazy"`. The LCP image, and any other image visible at first render, stays eager. [review]
- Every image carries its intrinsic `width` and `height`, so the layout keeps its box while it loads. [test]
- A page offers only the derivatives the image manifest lists. [test]

Upload handling (byte-sniffed types, re-encoding, EXIF removal) is in [security.md](security.md).
