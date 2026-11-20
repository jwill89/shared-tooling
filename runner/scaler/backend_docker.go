package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"path"
	"strconv"
	"strings"
	"sync"
	"time"

	cerrdefs "github.com/containerd/errdefs"
	"github.com/moby/moby/api/pkg/stdcopy"
	"github.com/moby/moby/api/types/container"
	"github.com/moby/moby/client"
)

const (
	// The labels on each job container, by which a restarted scaler finds the ones still
	// running and the module's status and stop find them all.
	labelJob      = "ci-runner.job"
	labelRepo     = "ci-runner.repo"
	labelRunner   = "ci-runner.runner"
	labelRunnerID = "ci-runner.runner-id"
	labelWork     = "ci-runner.work"

	// dockerSocket is the distro's Docker socket, which the scaler's container mounts and
	// a job with Docker access gets too.
	dockerSocket = "/var/run/docker.sock"
	// runnerUID is the job image's runner user, which owns a job's work folder.
	runnerUID = 1001
	// cacheMount is where every job container has the shared cache volume, which the job
	// image's environment points Go, npm and Composer at.
	cacheMount = "/ci-cache"
)

// dockerBackend runs each runner in a fresh container of the job image. A repo listed in
// DockerRepos gets the distro's Docker in its containers, and a work folder at the same
// path in the distro, so a path a job hands `docker run -v` means the same to Docker.
type dockerBackend struct {
	docker *client.Client
	config *Config
	access map[string]bool
	gid    int
	log    *slog.Logger

	mu   sync.Mutex
	work map[string]string // a container's work folder in the distro, by handle
}

func newDockerBackend(ctx context.Context, config *Config, log *slog.Logger) (*dockerBackend, error) {
	docker, err := client.New(client.FromEnv)
	if err != nil {
		return nil, fmt.Errorf("connect to Docker: %w", err)
	}
	b := &dockerBackend{docker: docker, config: config, access: map[string]bool{}, log: log, work: map[string]string{}}
	for _, repo := range config.DockerRepos {
		b.access[repo] = true
	}
	if len(b.access) > 0 {
		// The job runs as the runner user, which may use the socket through its group.
		if b.gid, err = socketGroup(dockerSocket); err != nil {
			return nil, err
		}
		if err := os.MkdirAll(config.WorkRoot, 0o750); err != nil {
			return nil, fmt.Errorf("make the work root: %w", err)
		}
	}
	if _, err := docker.Ping(ctx, client.PingOptions{}); err != nil {
		return nil, fmt.Errorf("reach Docker: %w", err)
	}
	return b, nil
}

func (b *dockerBackend) workFolder(repo, name string) string {
	if b.access[repo] {
		return path.Join(b.config.WorkRoot, name)
	}
	return "_work"
}

func (b *dockerBackend) start(ctx context.Context, s spec) (string, error) {
	initProcess := true
	labels := map[string]string{
		labelJob:      b.config.Name,
		labelRepo:     s.repo,
		labelRunner:   s.name,
		labelRunnerID: strconv.FormatInt(s.runnerID, 10),
	}
	host := &container.HostConfig{
		Init:    &initProcess,
		ShmSize: b.config.ShmSize,
		Resources: container.Resources{
			Memory:       b.config.JobMemory,
			CgroupParent: b.config.CgroupParent,
		},
	}
	if b.config.CacheVolume != "" {
		// Docker makes the volume on first use from the image's /ci-cache, so it belongs
		// to the runner user.
		host.Binds = append(host.Binds, b.config.CacheVolume+":"+cacheMount)
	}
	if b.access[s.repo] {
		if err := os.MkdirAll(s.workFolder, 0o750); err != nil {
			return "", fmt.Errorf("make the work folder: %w", err)
		}
		if err := os.Chown(s.workFolder, runnerUID, runnerUID); err != nil {
			return "", fmt.Errorf("give the work folder to the runner user: %w", err)
		}
		labels[labelWork] = s.workFolder
		host.Binds = append(host.Binds, dockerSocket+":"+dockerSocket, s.workFolder+":"+s.workFolder)
		host.GroupAdd = []string{strconv.Itoa(b.gid)}
	}
	created, err := b.docker.ContainerCreate(ctx, client.ContainerCreateOptions{
		Name: "ci-" + s.repo + "-" + s.name,
		Config: &container.Config{
			Image:  b.config.Image,
			Env:    jobEnv(s.jitConfig, b.config.JobCpus),
			Labels: labels,
		},
		HostConfig: host,
	})
	if err != nil {
		b.removeWork(s.workFolder, labels[labelWork] != "")
		return "", fmt.Errorf("create the container: %w", err)
	}
	b.mu.Lock()
	if labels[labelWork] != "" {
		b.work[created.ID] = s.workFolder
	}
	b.mu.Unlock()
	if _, err := b.docker.ContainerStart(ctx, created.ID, client.ContainerStartOptions{}); err != nil {
		b.remove(ctx, created.ID)
		return "", fmt.Errorf("start the container: %w", err)
	}
	return created.ID, nil
}

// jobEnv is a job container's environment. The runner reads its configuration from
// ACTIONS_RUNNER_INPUT_JITCONFIG and clears it from its own environment, so the job's
// steps don't inherit it; they inherit the rest. A container sees the processors every
// running job shares, not its own share of them, so a job is told its share: CI_CPUS for
// the tools whose shared settings read it (Vitest's workers), and the knobs Go and .NET
// read themselves, which size go test's packages at once and its tests' parallelism, and
// dotnet test's.
func jobEnv(jitConfig string, cpus int) []string {
	env := []string{"ACTIONS_RUNNER_INPUT_JITCONFIG=" + jitConfig}
	if cpus > 0 {
		n := strconv.Itoa(cpus)
		env = append(env, "CI_CPUS="+n, "GOMAXPROCS="+n, "DOTNET_PROCESSOR_COUNT="+n)
	}
	return env
}

func (b *dockerBackend) wait(ctx context.Context, handle string) (int64, error) {
	wait := b.docker.ContainerWait(ctx, handle, client.ContainerWaitOptions{Condition: container.WaitConditionNotRunning})
	select {
	case result := <-wait.Result:
		return result.StatusCode, nil
	case err := <-wait.Error:
		if ctx.Err() != nil {
			return -1, fmt.Errorf("wait for the container: %w", ctx.Err())
		}
		b.log.Warn("lost track of a runner's container", "container", handle, "error", err)
		return -1, nil
	}
}

func (b *dockerBackend) remove(ctx context.Context, handle string) {
	_, err := b.docker.ContainerRemove(context.WithoutCancel(ctx), handle, client.ContainerRemoveOptions{Force: true})
	if err != nil && !cerrdefs.IsNotFound(err) {
		b.log.Warn("couldn't remove a container", "container", handle, "error", err)
	}
	b.mu.Lock()
	work, ok := b.work[handle]
	delete(b.work, handle)
	b.mu.Unlock()
	b.removeWork(work, ok)
}

// removeWork removes a job's work folder, with what the job's own containers wrote there
// as root.
func (b *dockerBackend) removeWork(folder string, made bool) {
	if !made {
		return
	}
	if err := os.RemoveAll(folder); err != nil {
		b.log.Warn("couldn't remove a job's work folder", "folder", folder, "error", err)
	}
}

func (b *dockerBackend) tail(ctx context.Context, handle string) string {
	logs, err := b.docker.ContainerLogs(context.WithoutCancel(ctx), handle, client.ContainerLogsOptions{ShowStdout: true, ShowStderr: true, Tail: "20"})
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

func (b *dockerBackend) running(ctx context.Context) ([]found, error) {
	list, err := b.docker.ContainerList(ctx, client.ContainerListOptions{All: true, Filters: make(client.Filters).Add("label", labelJob)})
	if err != nil {
		return nil, fmt.Errorf("list the job containers: %w", err)
	}
	var result []found
	kept := map[string]bool{}
	for _, c := range list.Items {
		if work := c.Labels[labelWork]; work != "" {
			b.mu.Lock()
			b.work[c.ID] = work
			b.mu.Unlock()
		}
		id, err := strconv.ParseInt(c.Labels[labelRunnerID], 10, 64)
		if err != nil || c.State != container.StateRunning {
			b.remove(ctx, c.ID)
			continue
		}
		kept[c.Labels[labelWork]] = true
		result = append(result, found{
			handle: c.ID, repo: c.Labels[labelRepo], name: c.Labels[labelRunner],
			runnerID: id, started: time.Unix(c.Created, 0),
		})
	}
	// Work folders no running container uses were left by a crash.
	if b.config.WorkRoot != "" {
		entries, err := os.ReadDir(b.config.WorkRoot)
		if err != nil && !errors.Is(err, os.ErrNotExist) {
			return nil, fmt.Errorf("read the work root: %w", err)
		}
		for _, e := range entries {
			folder := path.Join(b.config.WorkRoot, e.Name())
			if !kept[folder] {
				b.removeWork(folder, true)
			}
		}
	}
	return result, nil
}

// shutdown leaves the containers running: each finishes its job, and the next run of the
// scaler adopts the ones still going.
func (b *dockerBackend) shutdown(context.Context) {
	if err := b.docker.Close(); err != nil {
		b.log.Warn("couldn't close the Docker client", "error", err)
	}
}
