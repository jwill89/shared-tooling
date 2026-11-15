package main

import (
	"slices"
	"time"
)

// runnerView is what a plan needs to know of one runner.
type runnerView struct {
	name    string
	started time.Time
	busy    bool
}

// plan says how many runners to start, and which idle ones to retire, so that a repo has
// one runner for each job GitHub has assigned it, running or waiting. An idle runner
// retires only once it has waited longer than grace, since GitHub may yet hand it a job
// it assigned while the runner came online.
func plan(assigned int, runners []runnerView, now time.Time, grace time.Duration) (start int, retire []string) {
	if assigned >= len(runners) {
		return assigned - len(runners), nil
	}
	var idle []runnerView
	for _, r := range runners {
		if !r.busy && now.Sub(r.started) > grace {
			idle = append(idle, r)
		}
	}
	slices.SortFunc(idle, func(a, b runnerView) int { return a.started.Compare(b.started) })
	for _, r := range idle[:min(len(runners)-assigned, len(idle))] {
		retire = append(retire, r.name)
	}
	return 0, retire
}

// backoff is how long a repo waits before starting runners again after its failures-th
// runner in a row exited before taking a job: a broken image or a refused registration
// then costs a container every few minutes, not a stream of them.
func backoff(failures int) time.Duration {
	const (
		first = 5 * time.Second
		most  = 5 * time.Minute
	)
	delay := first
	for i := 1; i < failures && delay < most; i++ {
		delay *= 2
	}
	return min(delay, most)
}
