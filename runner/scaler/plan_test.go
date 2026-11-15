package main

import (
	"slices"
	"testing"
	"time"
)

func TestPlan(t *testing.T) {
	t.Parallel()
	now := time.Date(2026, 1, 1, 12, 0, 0, 0, time.UTC)
	ago := func(d time.Duration) time.Time { return now.Add(-d) }
	tests := []struct {
		name       string
		assigned   int
		runners    []runnerView
		wantStart  int
		wantRetire []string
	}{
		{"nothing to do", 0, nil, 0, nil},
		{"a runner per new job", 3, nil, 3, nil},
		{"only the jobs without one", 3, []runnerView{{name: "a", started: ago(time.Second), busy: true}}, 2, nil},
		{"enough already", 1, []runnerView{{name: "a", started: ago(time.Hour), busy: true}}, 0, nil},
		{"a busy runner stays", 0, []runnerView{{name: "a", started: ago(time.Hour), busy: true}}, 0, nil},
		{"a new idle runner keeps waiting", 0, []runnerView{{name: "a", started: ago(time.Minute)}}, 0, nil},
		{"an idle runner past its grace retires", 0, []runnerView{{name: "a", started: ago(3 * time.Minute)}}, 0, []string{"a"}},
		{
			"only the surplus retires, oldest first",
			1,
			[]runnerView{
				{name: "new", started: ago(3 * time.Minute)},
				{name: "old", started: ago(9 * time.Minute)},
				{name: "older", started: ago(10 * time.Minute)},
			},
			0,
			[]string{"older", "old"},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			start, retire := plan(tt.assigned, tt.runners, now, 2*time.Minute)
			if start != tt.wantStart || !slices.Equal(retire, tt.wantRetire) {
				t.Errorf("plan() = %d, %v; want %d, %v", start, retire, tt.wantStart, tt.wantRetire)
			}
		})
	}
}

func TestBackoff(t *testing.T) {
	t.Parallel()
	tests := []struct {
		failures int
		want     time.Duration
	}{
		{1, 5 * time.Second},
		{2, 10 * time.Second},
		{4, 40 * time.Second},
		{7, 5 * time.Minute},
		{100, 5 * time.Minute},
	}
	for _, tt := range tests {
		if got := backoff(tt.failures); got != tt.want {
			t.Errorf("backoff(%d) = %v, want %v", tt.failures, got, tt.want)
		}
	}
}
