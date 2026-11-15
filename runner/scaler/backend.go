package main

import (
	"context"
	"time"
)

// spec is one runner to start: its name, the repo it serves, its registration, its
// single-use configuration, and the work folder the configuration names.
type spec struct {
	name       string
	repo       string
	runnerID   int64
	jitConfig  string
	workFolder string
}

// found is a runner an earlier run of the scaler left running.
type found struct {
	handle   string
	repo     string
	name     string
	runnerID int64
	started  time.Time
}

// backend is where runners run: a container each (dockerBackend), or a process each on
// this machine (processBackend).
type backend interface {
	// workFolder is the work folder a repo's runner should use, which its single-use
	// configuration carries.
	workFolder(repo, name string) string
	// start starts a runner, and returns the handle the other methods take.
	start(ctx context.Context, s spec) (string, error)
	// wait returns the runner's exit code once it exits, or ctx's error when ctx ends
	// first.
	wait(ctx context.Context, handle string) (int64, error)
	// remove stops the runner if it is running, and removes whatever it left.
	remove(ctx context.Context, handle string)
	// tail returns the last lines the runner wrote, to say why it failed.
	tail(ctx context.Context, handle string) string
	// running returns the runners an earlier run left running, after removing what the
	// stopped ones left.
	running(ctx context.Context) ([]found, error)
	// shutdown is called once, as the scaler exits.
	shutdown(ctx context.Context)
}
