package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"log/slog"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/actions/scaleset"
	cerrdefs "github.com/containerd/errdefs"
	"github.com/moby/moby/api/pkg/stdcopy"
	"github.com/moby/moby/api/types/container"
	"github.com/moby/moby/client"
)

const (
	// runnerGroupID is the Default group, the only one a personal account's repo has.
	runnerGroupID = 1
	// idleGrace is how long a new runner may wait for a job before it can be retired.
	idleGrace = 2 * time.Minute

	// The labels on each job container, by which a restarted scaler finds the ones still
	// running and the module's status and stop find them all.
	labelJob      = "ci-runner.job"
	labelRepo     = "ci-runner.repo"
	labelRunner   = "ci-runner.runner"
	labelRunnerID = "ci-runner.runner-id"
)

// runner is one job container and the registration GitHub knows it by.
type runner struct {
	id        int64
	container string
	started   time.Time
	busy      bool
	retiring  bool
}

// repoScaler keeps one repo's scale set supplied with a runner for each job GitHub
// assigns it.
type repoScaler struct {
	repo   string
	config *Config
	pool   *pool
	docker *client.Client
	log    *slog.Logger

	mu        sync.Mutex
	github    *scaleset.Client
	scaleSet  int
	runners   map[string]*runner
	assigned  int
	failures  int
	holdUntil time.Time
}

func newRepoScaler(repo string, config *Config, p *pool, docker *client.Client, log *slog.Logger) *repoScaler {
	return &repoScaler{repo: repo, config: config, pool: p, docker: docker, log: log, runners: map[string]*runner{}}
}

// run serves the repo until ctx ends, starting over after a failure: a lost connection,
// a machine that slept, or a session an earlier run left open, which GitHub closes a few
// minutes later.
func (s *repoScaler) run(ctx context.Context) {
	delay := 5 * time.Second
	for {
		began := time.Now()
		err := s.serve(ctx)
		if ctx.Err() != nil {
			return
		}
		if time.Since(began) > 10*time.Minute {
			delay = 5 * time.Second
		}
		s.log.Warn("lost the connection to GitHub; starting over", "in", delay, "error", err)
		select {
		case <-ctx.Done():
			return
		case <-time.After(delay):
		}
		delay = min(delay*2, 5*time.Minute)
	}
}

// serve finds or creates the repo's scale set, opens a message session on it, and
// handles its messages until ctx ends or a call fails.
func (s *repoScaler) serve(ctx context.Context) error {
	github, err := scaleset.NewClientWithPersonalAccessToken(scaleset.NewClientWithPersonalAccessTokenConfig{
		GitHubConfigURL:     fmt.Sprintf("https://github.com/%s/%s", s.config.Owner, s.repo),
		PersonalAccessToken: s.config.Token,
		SystemInfo:          systemInfo(0),
	})
	if err != nil {
		return fmt.Errorf("make the client: %w", err)
	}
	set, err := s.ensureScaleSet(ctx, github)
	if err != nil {
		return err
	}
	github.SetSystemInfo(systemInfo(set.ID))
	s.mu.Lock()
	s.github, s.scaleSet = github, set.ID
	s.mu.Unlock()

	session, err := github.MessageSessionClient(ctx, set.ID, s.config.Name)
	if err != nil {
		return fmt.Errorf("open a message session: %w", err)
	}
	defer func() {
		if err := session.Close(context.WithoutCancel(ctx)); err != nil {
			s.log.Warn("couldn't close the message session", "error", err)
		}
	}()
	s.log.Info("listening for jobs", "scaleSet", set.ID)
	s.converge(ctx, session.Session().Statistics)

	lastID := 0
	for {
		pollCtx, cancel := context.WithCancel(ctx)
		offered := s.pool.beginPoll(s.repo, cancel)
		msg, err := session.GetMessage(pollCtx, lastID, offered)
		cut := pollCtx.Err() != nil
		s.pool.endPoll(s.repo)
		cancel()
		switch {
		case ctx.Err() != nil:
			return fmt.Errorf("poll: %w", ctx.Err())
		case err != nil && !cut:
			return fmt.Errorf("poll: %w", err)
		case msg == nil:
			// The poll ended empty, or was cut short because the room changed or a runner
			// exited: plan again on the last statistics.
			s.converge(ctx, nil)
			continue
		}
		if err := s.handle(ctx, session, msg); err != nil {
			return err
		}
		if err := session.DeleteMessage(context.WithoutCancel(ctx), msg.MessageID); err != nil {
			return fmt.Errorf("acknowledge message %d: %w", msg.MessageID, err)
		}
		lastID = msg.MessageID
	}
}

// ensureScaleSet returns the repo's scale set of the configured name, creating it the
// first time. It outlives the scaler, so a job queued while the machine is off waits for
// it rather than finding no runner.
func (s *repoScaler) ensureScaleSet(ctx context.Context, github *scaleset.Client) (*scaleset.RunnerScaleSet, error) {
	set, err := github.GetRunnerScaleSet(ctx, runnerGroupID, s.config.Name)
	if err != nil {
		return nil, fmt.Errorf("look up the scale set: %w", err)
	}
	if set != nil {
		return set, nil
	}
	set, err = github.CreateRunnerScaleSet(ctx, &scaleset.RunnerScaleSet{
		Name:          s.config.Name,
		RunnerGroupID: runnerGroupID,
		Labels:        []scaleset.Label{{Name: s.config.Name}},
		// The image carries the runner's newest release, rebuilt as each one comes out.
		RunnerSetting: scaleset.RunnerSetting{DisableUpdate: true},
	})
	if err != nil {
		return nil, fmt.Errorf("create the scale set: %w", err)
	}
	s.log.Info("created the scale set", "scaleSet", set.ID)
	return set, nil
}

// handle acquires the jobs on offer, notes which runners have started one, and scales
// to the message's statistics.
func (s *repoScaler) handle(ctx context.Context, session *scaleset.MessageSessionClient, msg *scaleset.RunnerScaleSetMessage) error {
	if len(msg.JobAvailableMessages) > 0 {
		ids := make([]int64, 0, len(msg.JobAvailableMessages))
		for _, job := range msg.JobAvailableMessages {
			ids = append(ids, job.RunnerRequestID)
		}
		if _, err := session.AcquireJobs(ctx, ids); err != nil {
			return fmt.Errorf("acquire jobs: %w", err)
		}
	}
	for _, job := range msg.JobStartedMessages {
		s.mu.Lock()
		if r, ok := s.runners[job.RunnerName]; ok {
			r.busy = true
		}
		s.mu.Unlock()
		s.log.Info("job started", "job", job.JobDisplayName, "run", job.WorkflowRunID, "runner", job.RunnerName)
	}
	for _, job := range msg.JobCompletedMessages {
		s.log.Info("job finished", "job", job.JobDisplayName, "run", job.WorkflowRunID, "result", job.Result, "runner", job.RunnerName)
	}
	s.converge(ctx, msg.Statistics)
	return nil
}

// converge starts or retires runners so the repo has one for each job GitHub has
// assigned it. stats is nil after a poll that ended empty, and the last ones stand.
func (s *repoScaler) converge(ctx context.Context, stats *scaleset.RunnerScaleSetStatistic) {
	s.mu.Lock()
	if stats != nil {
		s.assigned = stats.TotalAssignedJobs
	}
	views := make([]runnerView, 0, len(s.runners))
	for name, r := range s.runners {
		if !r.retiring {
			views = append(views, runnerView{name: name, started: r.started, busy: r.busy})
		}
	}
	start, retire := plan(s.assigned, views, time.Now(), idleGrace)
	held := start > 0 && time.Now().Before(s.holdUntil)
	s.mu.Unlock()

	if held {
		start = 0
	}
	for range start {
		if err := s.startRunner(ctx); err != nil {
			s.log.Error("couldn't start a runner", "error", err)
			s.mu.Lock()
			s.failures++
			s.holdUntil = time.Now().Add(backoff(s.failures))
			s.mu.Unlock()
			break
		}
	}
	for _, name := range retire {
		s.retire(ctx, name)
	}
}

// startRunner asks GitHub for a single-use runner in the scale set and starts its
// container, which takes one job and exits.
func (s *repoScaler) startRunner(ctx context.Context) error {
	s.mu.Lock()
	github, setID := s.github, s.scaleSet
	s.mu.Unlock()
	suffix, err := randomSuffix()
	if err != nil {
		return err
	}
	name := s.config.Name + "-" + suffix
	jit, err := github.GenerateJitRunnerConfig(ctx, &scaleset.RunnerScaleSetJitRunnerSetting{Name: name, WorkFolder: "_work"}, setID)
	if err != nil {
		return fmt.Errorf("get a runner from GitHub: %w", err)
	}
	if jit.Runner == nil {
		return errors.New("GitHub's runner configuration names no runner")
	}
	id := int64(jit.Runner.ID)

	initProcess := true
	created, err := s.docker.ContainerCreate(ctx, client.ContainerCreateOptions{
		Name: "ci-" + s.repo + "-" + suffix,
		Config: &container.Config{
			Image: s.config.Image,
			// The runner reads its configuration from here and clears it from its own
			// environment, so the job's steps don't inherit it.
			Env: []string{"ACTIONS_RUNNER_INPUT_JITCONFIG=" + jit.EncodedJITConfig},
			Labels: map[string]string{
				labelJob:      s.config.Name,
				labelRepo:     s.repo,
				labelRunner:   name,
				labelRunnerID: strconv.FormatInt(id, 10),
			},
		},
		HostConfig: &container.HostConfig{
			Init:    &initProcess,
			ShmSize: s.config.ShmSize,
			Resources: container.Resources{
				Memory:       s.config.JobMemory,
				CgroupParent: s.config.CgroupParent,
			},
		},
	})
	if err != nil {
		s.unregister(ctx, github, id)
		return fmt.Errorf("create the container: %w", err)
	}
	if _, err := s.docker.ContainerStart(ctx, created.ID, client.ContainerStartOptions{}); err != nil {
		s.removeContainer(ctx, created.ID)
		s.unregister(ctx, github, id)
		return fmt.Errorf("start the container: %w", err)
	}

	r := &runner{id: id, container: created.ID, started: time.Now()}
	s.track(ctx, name, r)
	s.log.Info("runner started", "runner", name)
	return nil
}

// adopt takes on a job container an earlier run of the scaler left running. Its state is
// unknown, so it counts as busy: it exits after its job, or takes the next one.
func (s *repoScaler) adopt(ctx context.Context, name, containerID string, id int64, started time.Time) {
	s.track(ctx, name, &runner{id: id, container: containerID, started: started, busy: true})
	s.log.Info("took on a running runner", "runner", name)
}

// track counts a runner against the machine's limit and watches its container.
func (s *repoScaler) track(ctx context.Context, name string, r *runner) {
	s.mu.Lock()
	s.runners[name] = r
	s.mu.Unlock()
	s.pool.add(s.repo)
	go s.watch(ctx, name, r)
}

// watch waits for a runner's container to exit, which it does after its one job, then
// removes the container and the registration and frees its place. When ctx ends it stops
// waiting and leaves the container, which the next run adopts.
func (s *repoScaler) watch(ctx context.Context, name string, r *runner) {
	wait := s.docker.ContainerWait(ctx, r.container, client.ContainerWaitOptions{Condition: container.WaitConditionNotRunning})
	code := int64(-1)
	select {
	case result := <-wait.Result:
		code = result.StatusCode
	case err := <-wait.Error:
		if ctx.Err() != nil {
			return
		}
		s.log.Warn("lost track of a runner's container", "runner", name, "error", err)
	}
	ran := time.Since(r.started)

	s.mu.Lock()
	busy, retiring := r.busy, r.retiring
	s.mu.Unlock()
	if code != 0 && !retiring {
		s.log.Warn("runner exited with an error", "runner", name, "exit", code, "output", s.tail(ctx, r.container))
	}
	s.removeContainer(ctx, r.container)

	s.mu.Lock()
	github := s.github
	delete(s.runners, name)
	switch {
	case busy:
		s.failures = 0
	case !retiring && ran < idleGrace:
		s.failures++
		s.holdUntil = time.Now().Add(backoff(s.failures))
	}
	s.mu.Unlock()

	// An ephemeral runner removes its own registration after its job; one that never
	// took a job would otherwise stay listed, offline.
	s.unregister(ctx, github, r.id)
	s.pool.done(s.repo)
	// A job assigned while this runner was finishing counted it as taken, so the repo
	// plans again now rather than when its poll ends.
	s.pool.interrupt(s.repo)
	s.log.Info("runner finished", "runner", name, "exit", code, "ran", ran.Round(time.Second))
}

// retire removes an idle runner. GitHub refuses to remove one that has just taken a job,
// and that one stays.
func (s *repoScaler) retire(ctx context.Context, name string) {
	s.mu.Lock()
	r, ok := s.runners[name]
	github := s.github
	if ok {
		r.retiring = true
	}
	s.mu.Unlock()
	if !ok || github == nil {
		return
	}
	if err := github.RemoveRunner(ctx, r.id); err != nil && !isNotFound(err) {
		s.mu.Lock()
		r.retiring = false
		s.mu.Unlock()
		s.log.Info("kept an idle runner GitHub wouldn't remove", "runner", name, "error", err)
		return
	}
	// watch then sees the container exit and frees its place.
	s.removeContainer(ctx, r.container)
	s.log.Info("retired an idle runner", "runner", name)
}

func (s *repoScaler) unregister(ctx context.Context, github *scaleset.Client, id int64) {
	if github == nil {
		return
	}
	if err := github.RemoveRunner(context.WithoutCancel(ctx), id); err != nil && !isNotFound(err) {
		s.log.Warn("couldn't remove a runner's registration", "runnerId", id, "error", err)
	}
}

func (s *repoScaler) removeContainer(ctx context.Context, id string) {
	_, err := s.docker.ContainerRemove(context.WithoutCancel(ctx), id, client.ContainerRemoveOptions{Force: true})
	if err != nil && !cerrdefs.IsNotFound(err) {
		s.log.Warn("couldn't remove a container", "container", id, "error", err)
	}
}

// tail returns the last lines a container wrote, to say why a runner failed.
func (s *repoScaler) tail(ctx context.Context, id string) string {
	logs, err := s.docker.ContainerLogs(context.WithoutCancel(ctx), id, client.ContainerLogsOptions{ShowStdout: true, ShowStderr: true, Tail: "20"})
	if err != nil {
		return "(no output: " + err.Error() + ")"
	}
	defer func() { _ = logs.Close() }() // opened to read
	var out bytes.Buffer
	if _, err := stdcopy.StdCopy(&out, &out, logs); err != nil {
		return "(no output: " + err.Error() + ")"
	}
	return strings.TrimSpace(out.String())
}

func isNotFound(err error) bool {
	return errors.Is(err, scaleset.NotFoundError) || errors.Is(err, scaleset.RunnerNotFoundError)
}

func randomSuffix() (string, error) {
	b := make([]byte, 4)
	if _, err := rand.Read(b); err != nil {
		return "", fmt.Errorf("make a runner name: %w", err)
	}
	return hex.EncodeToString(b), nil
}

func systemInfo(scaleSetID int) scaleset.SystemInfo {
	return scaleset.SystemInfo{System: "ci-runner-scaler", Subsystem: "scaler", Version: "1", ScaleSetID: scaleSetID}
}
