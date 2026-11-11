# lint/go

The shared golangci-lint config, and `golangci-sync`, which writes each module's copy from it.

golangci-lint has no way to extend another config, so each module keeps a full `.golangci.yml`. The tool generates it: the template with the module's name filled in (for goimports' `local-prefixes`), with the module's own `.golangci.local.yml` merged on top. CI runs it with `-check`, so a hand edit, or a template change a module hasn't taken yet, fails the build.

## Use it in a module

From the repo that holds shared-tooling at `shared/`:

```bash
go run -C shared/lint/go . -dir backend
```

`-dir` is the Go module's folder relative to that repo (`.` when `go.mod` is at the root, the default). Commit the `.golangci.yml` it writes. Add `-check` to compare without writing.

## A module's own rules

Put what only that module needs in `.golangci.local.yml` beside its `go.mod`, with the reason beside each entry, as the template does:

```yaml
linters:
  # Not bodyclose: the server makes no HTTP requests.
  disable:
    - bodyclose
  settings:
    exhaustive:
      # A switch over Discord's types handles the few that matter here; its default says
      # what the rest are and why they're skipped.
      default-signifies-exhaustive: true
  exclusions:
    # A Go file ships inside one of the frontend's npm packages; it is not this module's.
    paths:
      - web/node_modules
```

How it merges: mappings merge key by key, lists append what they don't already hold (exclusion rules always append), and any other value replaces the template's. `linters.disable` takes those linters out of the template's `enable` list, since golangci-lint refuses one that is both.

## The tool itself

`main.go` is its own Go module (with `gopkg.in/yaml.v3`), so a project's `go test ./...` and `golangci-lint run ./...` skip it. It's linted with its own template: `go run . -dir .` writes the `.golangci.yml` here.
