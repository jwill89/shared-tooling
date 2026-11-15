// Command scaler runs GitHub Actions jobs for a set of repos, each in a fresh container,
// starting a runner only when a job is waiting for one.
//
// Each repo gets a runner scale set, which GitHub matches jobs to by its name. The
// scaler holds a long poll open on each, and when GitHub assigns a set jobs, it starts a
// single-use runner per job in a container of the job image; the runner takes its job
// and exits, and its container is removed. Nothing runs between jobs but the polls.
// MaxJobs caps the jobs running at once across every repo, and the rest wait in
// GitHub's queue.
//
// It reads its settings as one line of JSON on standard input (Config), and talks to
// Docker through the socket the container mounts. CiRunner.psm1 builds and runs it.
package main

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"strconv"
	"sync"
	"syscall"
	"time"

	cerrdefs "github.com/containerd/errdefs"
	"github.com/moby/moby/api/types/container"
	"github.com/moby/moby/client"
)

func main() {
	log := slog.New(slog.NewTextHandler(os.Stdout, nil))
	if err := run(log); err != nil {
		log.Error("the scaler stopped", "error", err)
		os.Exit(1)
	}
}

func run(log *slog.Logger) error {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	config, err := readConfig(os.Stdin)
	if err != nil {
		return err
	}
	docker, err := client.New(client.FromEnv)
	if err != nil {
		return fmt.Errorf("connect to Docker: %w", err)
	}
	defer func() {
		if err := docker.Close(); err != nil {
			log.Warn("couldn't close the Docker client", "error", err)
		}
	}()

	p := newPool(config.MaxJobs)
	scalers := make(map[string]*repoScaler, len(config.Repos))
	for _, repo := range config.Repos {
		scalers[repo] = newRepoScaler(repo, &config, p, docker, log.With("repo", repo))
	}
	if err := adoptContainers(ctx, docker, scalers, log); err != nil {
		return err
	}

	log.Info("serving", "repos", len(config.Repos), "maxJobs", config.MaxJobs, "image", config.Image)
	var wg sync.WaitGroup
	for i, repo := range config.Repos {
		s := scalers[repo]
		wg.Go(func() {
			// Staggered, so the repos don't all ask GitHub for tokens in the same instant.
			select {
			case <-ctx.Done():
				return
			case <-time.After(time.Duration(i) * 250 * time.Millisecond):
			}
			s.run(ctx)
		})
	}
	wg.Wait()
	log.Info("stopped; job containers still running finish their jobs")
	return nil
}

// adoptContainers takes on the job containers an earlier run left running, and removes
// the ones that stopped or belong to a repo no longer served.
func adoptContainers(ctx context.Context, docker *client.Client, scalers map[string]*repoScaler, log *slog.Logger) error {
	found, err := docker.ContainerList(ctx, client.ContainerListOptions{All: true, Filters: make(client.Filters).Add("label", labelJob)})
	if err != nil {
		return fmt.Errorf("list the job containers: %w", err)
	}
	for _, c := range found.Items {
		s := scalers[c.Labels[labelRepo]]
		id, err := strconv.ParseInt(c.Labels[labelRunnerID], 10, 64)
		if s == nil || err != nil || c.State != container.StateRunning {
			if _, err := docker.ContainerRemove(ctx, c.ID, client.ContainerRemoveOptions{Force: true}); err != nil && !cerrdefs.IsNotFound(err) {
				log.Warn("couldn't remove a stopped job container", "container", c.ID, "error", err)
			}
			continue
		}
		s.adopt(ctx, c.Labels[labelRunner], c.ID, id, time.Unix(c.Created, 0))
	}
	return nil
}
