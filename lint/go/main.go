// Command golangci-sync writes a Go module's .golangci.yml from the shared template:
// the module name from its go.mod, and the module's own .golangci.local.yml merged on
// top. With -check it writes nothing and fails when the file on disk differs, which is
// how CI catches a hand edit or a template change not yet taken.
//
// Run it from the repo that holds shared-tooling as the submodule at shared/:
//
//	go run -C shared/lint/go . -dir backend
//	go run -C shared/lint/go . -dir backend -check
//
// -dir is the module's folder relative to that repo (default "."), or an absolute path.
//
// Merging: mappings merge key by key, lists append what they don't already hold, and
// any other value in the local file replaces the template's. A local `linters.disable`
// list takes those linters out of the template's `linters.enable` instead.
package main

import (
	"bufio"
	"bytes"
	"context"
	_ "embed"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"gopkg.in/yaml.v3"
)

//go:embed golangci.template.yml
var template string

const (
	outputName  = ".golangci.yml"
	overlayName = ".golangci.local.yml"
)

func main() {
	dir := flag.String("dir", ".", "the Go module's folder, relative to the repo holding shared/")
	check := flag.Bool("check", false, "fail if the file would change, instead of writing it")
	flag.Parse()

	if err := run(*dir, *check); err != nil {
		fmt.Fprintln(os.Stderr, "golangci-sync:", err)
		os.Exit(1)
	}
}

func run(dir string, check bool) error {
	moduleDir, err := resolveModuleDir(dir)
	if err != nil {
		return err
	}

	module, err := moduleName(filepath.Join(moduleDir, "go.mod"))
	if err != nil {
		return err
	}

	overlay, err := os.ReadFile(filepath.Join(moduleDir, overlayName)) //nolint:gosec // the module the caller named
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}

	want, err := render(module, overlay)
	if err != nil {
		return err
	}

	target := filepath.Join(moduleDir, outputName)
	if !check {
		return os.WriteFile(target, want, 0o644) //nolint:gosec // a config file, read by everyone
	}

	have, err := os.ReadFile(target) //nolint:gosec // the module the caller named
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if !bytes.Equal(normalize(have), normalize(want)) {
		return fmt.Errorf("%s is not what the shared template and %s make; run `go run -C shared/lint/go . -dir %s` and commit the result", target, overlayName, dir)
	}
	fmt.Printf("%s is current\n", target)
	return nil
}

// resolveModuleDir reads -dir against the superproject: the repo whose submodule this
// tool sits in. Outside a submodule (run inside shared-tooling itself) it is read
// against the working directory.
func resolveModuleDir(dir string) (string, error) {
	if filepath.IsAbs(dir) {
		return dir, nil
	}
	out, err := exec.CommandContext(context.Background(), "git", "rev-parse", "--show-superproject-working-tree").Output()
	if err != nil {
		return "", fmt.Errorf("finding the repo that holds shared/: %w", err)
	}
	root := strings.TrimSpace(string(out))
	if root == "" {
		root = "."
	}
	return filepath.Join(root, dir), nil
}

func moduleName(goMod string) (string, error) {
	f, err := os.Open(goMod) //nolint:gosec // the module the caller named
	if err != nil {
		return "", err
	}
	defer func() { _ = f.Close() }() // read-only: a failed close loses nothing

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		if name, ok := strings.CutPrefix(strings.TrimSpace(scanner.Text()), "module "); ok {
			return strings.Trim(strings.TrimSpace(name), `"`), nil
		}
	}
	if err := scanner.Err(); err != nil {
		return "", err
	}
	return "", fmt.Errorf("%s names no module", goMod)
}

func render(module string, overlay []byte) ([]byte, error) {
	// The template quotes the placeholder so it reads as YAML on its own; the name
	// goes in bare, as goimports' own examples write it.
	filled := strings.ReplaceAll(strings.ReplaceAll(template, `"{{module}}"`, module), "{{module}}", module)

	var doc yaml.Node
	if err := yaml.Unmarshal([]byte(filled), &doc); err != nil {
		return nil, fmt.Errorf("the template: %w", err)
	}

	if len(bytes.TrimSpace(overlay)) > 0 {
		var local yaml.Node
		if err := yaml.Unmarshal(overlay, &local); err != nil {
			return nil, fmt.Errorf("%s: %w", overlayName, err)
		}
		if local.Kind == yaml.DocumentNode && len(local.Content) == 1 {
			if err := merge(doc.Content[0], local.Content[0]); err != nil {
				return nil, fmt.Errorf("%s: %w", overlayName, err)
			}
		}
		applyDisable(doc.Content[0])
	}

	var buf bytes.Buffer
	enc := yaml.NewEncoder(&buf)
	enc.SetIndent(2)
	if err := enc.Encode(&doc); err != nil {
		return nil, err
	}
	if err := enc.Close(); err != nil {
		return nil, err
	}
	return spaceSections(buf.Bytes()), nil
}

// spaceSections puts back the blank line before each top-level section (and the
// comment above it), which the YAML encoder drops.
func spaceSections(out []byte) []byte {
	lines := strings.Split(string(out), "\n")
	var result []string
	seenKey := false
	for _, line := range lines {
		topLevelKey := line != "" && line[0] != ' ' && line[0] != '#' && line[0] != '-'
		if topLevelKey {
			if seenKey {
				// Back up over the comment block that belongs to this key.
				start := len(result)
				for start > 0 && strings.HasPrefix(result[start-1], "#") {
					start--
				}
				if start > 0 && result[start-1] != "" {
					result = append(result[:start], append([]string{""}, result[start:]...)...)
				}
			}
			seenKey = true
		}
		result = append(result, line)
	}
	return []byte(strings.Join(result, "\n"))
}

// merge folds src into dst.
func merge(dst, src *yaml.Node) error {
	if dst.Kind != yaml.MappingNode || src.Kind != yaml.MappingNode {
		return errors.New("expected a mapping")
	}
	for i := 0; i+1 < len(src.Content); i += 2 {
		key, value := src.Content[i], src.Content[i+1]
		existing := lookup(dst, key.Value)
		switch {
		case existing == nil:
			dst.Content = append(dst.Content, key, value)
		case existing.Kind == yaml.MappingNode && value.Kind == yaml.MappingNode:
			if err := merge(existing, value); err != nil {
				return fmt.Errorf("%s: %w", key.Value, err)
			}
		case existing.Kind == yaml.SequenceNode && value.Kind == yaml.SequenceNode:
			for _, item := range value.Content {
				if !holds(existing, item) {
					existing.Content = append(existing.Content, item)
				}
			}
		default:
			*existing = *value
		}
	}
	return nil
}

// applyDisable takes the linters a local file disables out of the template's enable
// list. golangci-lint refuses a linter that is both enabled and disabled.
func applyDisable(root *yaml.Node) {
	linters := lookup(root, "linters")
	if linters == nil {
		return
	}
	disable := lookup(linters, "disable")
	enable := lookup(linters, "enable")
	if disable == nil || enable == nil {
		return
	}
	kept := enable.Content[:0]
	for _, item := range enable.Content {
		if !holds(disable, item) {
			kept = append(kept, item)
		}
	}
	enable.Content = kept
	removeKey(linters, "disable")
}

func lookup(mapping *yaml.Node, key string) *yaml.Node {
	if mapping == nil || mapping.Kind != yaml.MappingNode {
		return nil
	}
	for i := 0; i+1 < len(mapping.Content); i += 2 {
		if mapping.Content[i].Value == key {
			return mapping.Content[i+1]
		}
	}
	return nil
}

func removeKey(mapping *yaml.Node, key string) {
	for i := 0; i+1 < len(mapping.Content); i += 2 {
		if mapping.Content[i].Value == key {
			mapping.Content = append(mapping.Content[:i], mapping.Content[i+2:]...)
			return
		}
	}
}

// holds reports whether a list already has a scalar with item's value. Mappings in a
// list (exclusion rules) are never the same item, so they always append.
func holds(list, item *yaml.Node) bool {
	if item.Kind != yaml.ScalarNode {
		return false
	}
	for _, existing := range list.Content {
		if existing.Kind == yaml.ScalarNode && existing.Value == item.Value {
			return true
		}
	}
	return false
}

// normalize lets a checkout with CRLF line endings compare equal.
func normalize(b []byte) []byte {
	return bytes.ReplaceAll(b, []byte("\r\n"), []byte("\n"))
}
