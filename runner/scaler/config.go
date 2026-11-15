package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"path"
	"path/filepath"
	"regexp"
	"strings"
)

// Config is the scaler's settings. CiRunner.psm1 sends them as one line of JSON on
// standard input, so the token is never on a command line or in the container's
// environment.
type Config struct {
	// Token is a GitHub token with admin rights on every repo, which the scale set client
	// trades for short-lived ones of its own.
	Token string `json:"token"`
	// Owner is the account that owns the repos.
	Owner string `json:"owner"`
	// Repos are the repos served, each with a scale set of its own.
	Repos []string `json:"repos"`
	// Name is each scale set's name, the label a job's runs-on names, and the start of
	// each runner's name.
	Name string `json:"name"`
	// MaxJobs is how many jobs may run at once, across every repo.
	MaxJobs int `json:"maxJobs"`
	// Backend is where the runners run: "docker" (the default) or "process".
	Backend string `json:"backend"`
	// StopFile, when set, stops the scaler when it appears.
	StopFile string `json:"stopFile"`

	// Image is the job image each runner's container runs (docker).
	Image string `json:"image"`
	// JobMemory is the most memory one job's container may use, in bytes; 0 sets no limit
	// of its own (docker).
	JobMemory int64 `json:"jobMemory"`
	// ShmSize is the size of each container's /dev/shm, in bytes, which Chrome needs
	// (docker).
	ShmSize int64 `json:"shmSize"`
	// CgroupParent is the systemd slice every job's container runs in, whose limits cap
	// the CPU and memory the jobs share (docker).
	CgroupParent string `json:"cgroupParent"`
	// DockerRepos are the repos whose job containers may use the distro's Docker, which
	// lets a job control every container there (docker).
	DockerRepos []string `json:"dockerRepos"`
	// WorkRoot holds those repos' work folders, at the same path in the distro as in the
	// container (docker).
	WorkRoot string `json:"workRoot"`
	// CacheVolume is the Docker volume every job container mounts at /ci-cache, which
	// keeps the download and build caches between jobs; empty mounts none (docker).
	CacheVolume string `json:"cacheVolume"`

	// RunnerDir is an extracted runner release, copied for each job (process).
	RunnerDir string `json:"runnerDir"`
	// JobsDir is where each job's copy goes (process).
	JobsDir string `json:"jobsDir"`
	// Env is added to each runner's environment, such as a Go cache of the runners' own
	// (process).
	Env map[string]string `json:"env"`
}

// The backends a Config may name.
const (
	backendDocker  = "docker"
	backendProcess = "process"
)

// readConfig reads the settings from the first line of r. The line may end in a CR, as
// one piped from PowerShell does.
func readConfig(r io.Reader) (Config, error) {
	line, err := bufio.NewReader(r).ReadString('\n')
	if err != nil && !errors.Is(err, io.EOF) {
		return Config{}, fmt.Errorf("read the settings: %w", err)
	}
	decoder := json.NewDecoder(strings.NewReader(line))
	decoder.DisallowUnknownFields()
	var config Config
	if err := decoder.Decode(&config); err != nil {
		return Config{}, fmt.Errorf("parse the settings: %w", err)
	}
	if config.Backend == "" {
		config.Backend = backendDocker
	}
	if err := config.validate(); err != nil {
		return Config{}, fmt.Errorf("check the settings: %w", err)
	}
	return config, nil
}

// validate holds each value to a plain shape, since each reaches an API path, a
// container's name or its limits.
func (c Config) validate() error {
	owner := regexp.MustCompile(`^[A-Za-z0-9-]+$`)
	name := regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,39}$`)
	switch {
	case c.Token == "":
		return errors.New("no token")
	case !owner.MatchString(c.Owner):
		return fmt.Errorf("owner %q isn't an account name", c.Owner)
	case len(c.Repos) == 0:
		return errors.New("no repos")
	case !name.MatchString(c.Name):
		return fmt.Errorf("name %q may hold only a-z, 0-9 and -, up to 40 of them", c.Name)
	case c.MaxJobs < 1:
		return fmt.Errorf("maxJobs is %d; it needs at least 1", c.MaxJobs)
	}
	served, err := repoSet(c.Repos)
	if err != nil {
		return err
	}
	switch c.Backend {
	case backendDocker:
		return c.validateDocker(served)
	case backendProcess:
		if !filepath.IsAbs(c.RunnerDir) || !filepath.IsAbs(c.JobsDir) {
			return errors.New("the process backend needs runnerDir and jobsDir, as absolute paths")
		}
		return nil
	default:
		return fmt.Errorf("backend %q is neither %s nor %s", c.Backend, backendDocker, backendProcess)
	}
}

func (c Config) validateDocker(served map[string]bool) error {
	switch {
	case c.Image == "":
		return errors.New("no image")
	case c.JobMemory < 0, c.ShmSize < 0:
		return errors.New("a size is below 0")
	case c.CgroupParent != "" && !strings.HasSuffix(c.CgroupParent, ".slice"):
		return fmt.Errorf("cgroupParent %q isn't a systemd slice", c.CgroupParent)
	case len(c.DockerRepos) > 0 && (!path.IsAbs(c.WorkRoot) || path.Clean(c.WorkRoot) == "/"):
		return errors.New("dockerRepos needs workRoot, an absolute path below /")
	case c.CacheVolume != "" && !regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9_.-]*$`).MatchString(c.CacheVolume):
		return fmt.Errorf("cacheVolume %q isn't a volume name", c.CacheVolume)
	}
	for _, r := range c.DockerRepos {
		if !served[r] {
			return fmt.Errorf("docker repo %q isn't one of the repos", r)
		}
	}
	return nil
}

// repoSet checks each repo's name and that none is listed twice.
func repoSet(repos []string) (map[string]bool, error) {
	pattern := regexp.MustCompile(`^[A-Za-z0-9._-]+$`)
	seen := make(map[string]bool, len(repos))
	for _, r := range repos {
		if !pattern.MatchString(r) {
			return nil, fmt.Errorf("repo %q isn't a repo name", r)
		}
		if seen[r] {
			return nil, fmt.Errorf("repo %q is listed twice", r)
		}
		seen[r] = true
	}
	return seen, nil
}
