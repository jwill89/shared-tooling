package main

import (
	"slices"
	"testing"
)

func TestJobEnv(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name string
		cpus int
		want []string
	}{
		{"no share", 0, []string{"ACTIONS_RUNNER_INPUT_JITCONFIG=jit"}},
		{"a share of two", 2, []string{
			"ACTIONS_RUNNER_INPUT_JITCONFIG=jit", "CI_CPUS=2", "GOMAXPROCS=2", "DOTNET_PROCESSOR_COUNT=2",
		}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			if got := jobEnv("jit", tt.cpus); !slices.Equal(got, tt.want) {
				t.Fatalf("jobEnv(%q, %d) = %q, want %q", "jit", tt.cpus, got, tt.want)
			}
		})
	}
}
