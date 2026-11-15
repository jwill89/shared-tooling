package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestCopyTree(t *testing.T) {
	t.Parallel()
	from := t.TempDir()
	files := map[string]string{
		"run.sh":                       "#!/bin/sh\n",
		"bin/Runner.Listener.dll":      "listener",
		"externals/node24/bin/node.js": "node",
	}
	for name, content := range files {
		path := filepath.Join(from, filepath.FromSlash(name))
		if err := os.MkdirAll(filepath.Dir(path), 0o750); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	to := filepath.Join(t.TempDir(), "job")
	if err := copyTree(from, to); err != nil {
		t.Fatalf("copyTree() error = %v", err)
	}
	for name, content := range files {
		got, err := os.ReadFile(filepath.Join(to, filepath.FromSlash(name)))
		if err != nil || string(got) != content {
			t.Errorf("%s = %q, %v; want %q", name, got, err, content)
		}
	}
	// A copy never lands on files already there: each job's folder starts empty.
	if err := copyTree(from, to); err == nil {
		t.Error("copyTree() over an earlier copy succeeded, want an error")
	}
}

func TestTailBuffer(t *testing.T) {
	t.Parallel()
	b := newTailBuffer(3)
	for _, chunk := range []string{"one\r\ntwo\n", "thr", "ee\nfour\nfive"} {
		if _, err := b.Write([]byte(chunk)); err != nil {
			t.Fatal(err)
		}
	}
	if got, want := b.String(), "three\nfour\nfive"; got != want {
		t.Errorf("String() = %q, want %q", got, want)
	}
	if got := b.String(); !strings.HasSuffix(got, "five") {
		t.Errorf("String() again = %q, want the same lines", got)
	}
}
