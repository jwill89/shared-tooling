package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
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
	// Image is the job image each runner's container runs.
	Image string `json:"image"`
	// MaxJobs is how many jobs may run at once, across every repo.
	MaxJobs int `json:"maxJobs"`
	// JobMemory is the most memory one job's container may use, in bytes; 0 sets no limit
	// of its own.
	JobMemory int64 `json:"jobMemory"`
	// ShmSize is the size of each container's /dev/shm, in bytes, which Chrome needs.
	ShmSize int64 `json:"shmSize"`
	// CgroupParent is the systemd slice every job's container runs in, whose limits cap
	// the CPU and memory the jobs share.
	CgroupParent string `json:"cgroupParent"`
}

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
	if err := config.validate(); err != nil {
		return Config{}, fmt.Errorf("check the settings: %w", err)
	}
	return config, nil
}

// validate holds each value to a plain shape, since each reaches an API path, a
// container's name or its limits.
func (c Config) validate() error {
	owner := regexp.MustCompile(`^[A-Za-z0-9-]+$`)
	repo := regexp.MustCompile(`^[A-Za-z0-9._-]+$`)
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
	case c.Image == "":
		return errors.New("no image")
	case c.MaxJobs < 1:
		return fmt.Errorf("maxJobs is %d; it needs at least 1", c.MaxJobs)
	case c.JobMemory < 0, c.ShmSize < 0:
		return errors.New("a size is below 0")
	case c.CgroupParent != "" && !strings.HasSuffix(c.CgroupParent, ".slice"):
		return fmt.Errorf("cgroupParent %q isn't a systemd slice", c.CgroupParent)
	}
	seen := make(map[string]bool, len(c.Repos))
	for _, r := range c.Repos {
		if !repo.MatchString(r) {
			return fmt.Errorf("repo %q isn't a repo name", r)
		}
		if seen[r] {
			return fmt.Errorf("repo %q is listed twice", r)
		}
		seen[r] = true
	}
	return nil
}
