package main

import (
	"strings"
	"testing"
)

func TestReadConfig(t *testing.T) {
	t.Parallel()
	const valid = `{"token":"t","owner":"owner","repos":["app","site.example"],"name":"wsl","image":"ci-runner:1",` +
		`"maxJobs":4,"jobMemory":1024,"shmSize":2048,"cgroupParent":"ci.slice"}`
	tests := []struct {
		name  string
		input string
		want  string // a fragment of the error, or "" for none
	}{
		{"valid", valid + "\n", ""},
		{"a CR from PowerShell, then more input", valid + "\r\nignored\n", ""},
		{"no newline", valid, ""},
		{"empty", "", "parse"},
		{"an unknown field", strings.Replace(valid, `"token"`, `"extra":1,"token"`, 1), "unknown field"},
		{"no token", strings.Replace(valid, `"token":"t"`, `"token":""`, 1), "no token"},
		{"an owner with a slash", strings.Replace(valid, `"owner":"owner"`, `"owner":"a/b"`, 1), "account name"},
		{"no repos", strings.Replace(valid, `["app","site.example"]`, `[]`, 1), "no repos"},
		{"a repo with a slash", strings.Replace(valid, `"app"`, `"a/b"`, 1), "repo name"},
		{"a repo twice", strings.Replace(valid, `"site.example"`, `"app"`, 1), "twice"},
		{"a name in capitals", strings.Replace(valid, `"name":"wsl"`, `"name":"WSL"`, 1), "a-z"},
		{"no image", strings.Replace(valid, `"image":"ci-runner:1"`, `"image":""`, 1), "no image"},
		{"no jobs", strings.Replace(valid, `"maxJobs":4`, `"maxJobs":0`, 1), "maxJobs"},
		{"a negative size", strings.Replace(valid, `"shmSize":2048`, `"shmSize":-1`, 1), "below 0"},
		{"a parent that isn't a slice", strings.Replace(valid, `"ci.slice"`, `"/ci"`, 1), "slice"},
		{"no parent", strings.Replace(valid, `"ci.slice"`, `""`, 1), ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			config, err := readConfig(strings.NewReader(tt.input))
			switch {
			case tt.want == "" && err != nil:
				t.Fatalf("readConfig() error = %v, want none", err)
			case tt.want != "" && (err == nil || !strings.Contains(err.Error(), tt.want)):
				t.Fatalf("readConfig() error = %v, want one saying %q", err, tt.want)
			case tt.want == "" && (config.Owner != "owner" || len(config.Repos) != 2 || config.MaxJobs != 4):
				t.Fatalf("readConfig() = %+v, want the values given", config)
			}
		})
	}
}
