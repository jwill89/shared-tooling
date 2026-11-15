package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"
)

// processBackend runs each runner as a process on this machine, from a fresh copy of an
// extracted runner release in a folder of its own: the runner writes its registration
// beside itself, so two can't share one copy. It serves the jobs a container can't take,
// such as Windows ones, and runs them as the user the scaler runs as.
type processBackend struct {
	runnerDir string
	jobsDir   string
	env       []string
	log       *slog.Logger

	mu    sync.Mutex
	procs map[string]*runnerProcess
}

// runnerProcess is one runner's process, its folder, and what it wrote.
type runnerProcess struct {
	cmd    *exec.Cmd
	dir    string
	output *tailBuffer
	done   chan struct{}
	code   int64
}

func newProcessBackend(config *Config, log *slog.Logger) (*processBackend, error) {
	if _, err := os.Stat(filepath.Join(config.RunnerDir, "bin", listenerName())); err != nil {
		return nil, fmt.Errorf("find the runner in %s: %w", config.RunnerDir, err)
	}
	if err := os.MkdirAll(config.JobsDir, 0o750); err != nil {
		return nil, fmt.Errorf("make the jobs folder: %w", err)
	}
	env := make([]string, 0, len(config.Env))
	for key, value := range config.Env {
		env = append(env, key+"="+value)
	}
	return &processBackend{runnerDir: config.RunnerDir, jobsDir: config.JobsDir, env: env, log: log, procs: map[string]*runnerProcess{}}, nil
}

func listenerName() string {
	if runtime.GOOS == "windows" {
		return "Runner.Listener.exe"
	}
	return "Runner.Listener"
}

func (b *processBackend) workFolder(string, string) string { return "_work" }

func (b *processBackend) start(ctx context.Context, s spec) (string, error) {
	dir := filepath.Join(b.jobsDir, s.name)
	if err := copyTree(b.runnerDir, dir); err != nil {
		b.removeDir(dir)
		return "", fmt.Errorf("copy the runner: %w", err)
	}
	output := newTailBuffer(20)
	// Not bound to ctx: a runner outlives a lost connection to GitHub, and shutdown ends it.
	//nolint:gosec // G204: the listener of the runner release the config names
	cmd := exec.CommandContext(context.WithoutCancel(ctx), filepath.Join(dir, "bin", listenerName()), "run")
	cmd.Dir = dir
	// The runner reads its configuration from the environment and clears it from its own,
	// so the job's steps don't inherit it.
	cmd.Env = append(append(os.Environ(), b.env...), "ACTIONS_RUNNER_INPUT_JITCONFIG="+s.jitConfig)
	cmd.Stdout = output
	cmd.Stderr = output
	if err := cmd.Start(); err != nil {
		b.removeDir(dir)
		return "", fmt.Errorf("start the runner: %w", err)
	}
	p := &runnerProcess{cmd: cmd, dir: dir, output: output, done: make(chan struct{})}
	go func() {
		err := cmd.Wait()
		var exit *exec.ExitError
		switch {
		case err == nil:
			p.code = 0
		case errors.As(err, &exit):
			p.code = int64(exit.ExitCode())
		default:
			p.code = -1
		}
		close(p.done)
	}()
	b.mu.Lock()
	b.procs[s.name] = p
	b.mu.Unlock()
	return s.name, nil
}

func (b *processBackend) process(handle string) *runnerProcess {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.procs[handle]
}

func (b *processBackend) wait(ctx context.Context, handle string) (int64, error) {
	p := b.process(handle)
	if p == nil {
		return -1, nil
	}
	select {
	case <-p.done:
		return p.code, nil
	case <-ctx.Done():
		return -1, fmt.Errorf("wait for the runner: %w", ctx.Err())
	}
}

func (b *processBackend) remove(_ context.Context, handle string) {
	p := b.process(handle)
	if p == nil {
		return
	}
	select {
	case <-p.done:
	default:
		// The runner, its worker and the job's own processes go together.
		if err := killTree(p.cmd.Process); err != nil {
			b.log.Warn("couldn't stop a runner", "runner", handle, "error", err)
		}
		select {
		case <-p.done:
		case <-time.After(30 * time.Second):
			b.log.Warn("a runner hasn't exited 30 s after being stopped", "runner", handle)
		}
	}
	b.removeDir(p.dir)
	b.mu.Lock()
	delete(b.procs, handle)
	b.mu.Unlock()
}

// removeDir removes a runner's folder. Windows holds a file a moment after the process
// that had it open exits, so it tries a few times.
func (b *processBackend) removeDir(dir string) {
	var err error
	for range 5 {
		if err = os.RemoveAll(dir); err == nil {
			return
		}
		time.Sleep(time.Second)
	}
	b.log.Warn("couldn't remove a runner's folder", "folder", dir, "error", err)
}

func (b *processBackend) tail(_ context.Context, handle string) string {
	if p := b.process(handle); p != nil {
		return p.output.String()
	}
	return ""
}

// running returns nothing: a runner process doesn't outlive the scaler (shutdown ends it),
// so whatever is in the jobs folder was left by a crash and is removed.
func (b *processBackend) running(context.Context) ([]found, error) {
	entries, err := os.ReadDir(b.jobsDir)
	if err != nil {
		return nil, fmt.Errorf("read the jobs folder: %w", err)
	}
	for _, e := range entries {
		b.removeDir(filepath.Join(b.jobsDir, e.Name()))
	}
	return nil, nil
}

// shutdown ends every runner: a job running in one fails, as on a lost runner.
func (b *processBackend) shutdown(ctx context.Context) {
	b.mu.Lock()
	handles := make([]string, 0, len(b.procs))
	for handle := range b.procs {
		handles = append(handles, handle)
	}
	b.mu.Unlock()
	for _, handle := range handles {
		b.remove(ctx, handle)
	}
}

// copyTree copies the folder from into to, which must not exist yet.
func copyTree(from, to string) error {
	return filepath.WalkDir(from, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(from, path)
		if err != nil {
			return fmt.Errorf("place %s: %w", path, err)
		}
		target := filepath.Join(to, rel)
		info, err := entry.Info()
		if err != nil {
			return fmt.Errorf("read %s: %w", path, err)
		}
		if entry.IsDir() {
			if err := os.MkdirAll(target, info.Mode().Perm()|0o700); err != nil {
				return fmt.Errorf("make %s: %w", target, err)
			}
			return nil
		}
		return copyFile(path, target, info.Mode().Perm())
	})
}

func copyFile(from, to string, mode fs.FileMode) error {
	source, err := os.Open(from) //nolint:gosec // G304: a file of the runner release being copied
	if err != nil {
		return fmt.Errorf("open %s: %w", from, err)
	}
	defer func() { _ = source.Close() }() // opened to read

	//nolint:gosec // G304: a path inside the jobs folder
	target, err := os.OpenFile(to, os.O_WRONLY|os.O_CREATE|os.O_EXCL, mode)
	if err != nil {
		return fmt.Errorf("create %s: %w", to, err)
	}
	if _, err := io.Copy(target, source); err != nil {
		_ = target.Close() // the copy's own error is the one to report
		return fmt.Errorf("copy %s: %w", from, err)
	}
	if err := target.Close(); err != nil {
		return fmt.Errorf("write %s: %w", to, err)
	}
	return nil
}

// tailBuffer keeps the last lines written to it.
type tailBuffer struct {
	mu      sync.Mutex
	max     int
	lines   []string
	partial string
}

func newTailBuffer(lines int) *tailBuffer { return &tailBuffer{max: lines} }

func (t *tailBuffer) Write(p []byte) (int, error) {
	t.mu.Lock()
	defer t.mu.Unlock()
	text := t.partial + strings.ReplaceAll(string(p), "\r", "")
	parts := strings.Split(text, "\n")
	t.partial = parts[len(parts)-1]
	t.lines = append(t.lines, parts[:len(parts)-1]...)
	if extra := len(t.lines) - t.max; extra > 0 {
		t.lines = t.lines[extra:]
	}
	return len(p), nil
}

func (t *tailBuffer) String() string {
	t.mu.Lock()
	defer t.mu.Unlock()
	lines := t.lines
	if t.partial != "" {
		lines = append(lines[:len(lines):len(lines)], t.partial)
	}
	if extra := len(lines) - t.max; extra > 0 {
		lines = lines[extra:]
	}
	return strings.TrimSpace(strings.Join(lines, "\n"))
}
