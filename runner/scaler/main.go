// Command scaler runs GitHub Actions jobs for a set of repos, each on a fresh runner,
// starting a runner only when a job is waiting for one.
//
// Each repo gets a runner scale set, which GitHub matches jobs to by its name. The
// scaler holds a long poll open on each, and when GitHub assigns a set jobs, it starts a
// single-use runner per job; the runner takes its job and exits, and what it left is
// removed. Nothing runs between jobs but the polls. MaxJobs caps the jobs running at
// once across every repo, and the rest wait in GitHub's queue.
//
// The backend says where a runner runs: "docker" starts a container of the job image
// for each, through the Docker socket the scaler's own container mounts; "process"
// starts a copy of an extracted runner release as a process on this machine, for the
// Windows jobs a container can't take.
//
// It reads its settings as one line of JSON on standard input (Config). It stops on
// SIGINT or SIGTERM, or when StopFile appears, which is how CiRunner.psm1 stops it on
// Windows, where no signal reaches it. CiRunner.psm1 builds and runs it.
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"
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
	if config.StopFile != "" {
		ctx, stop = context.WithCancel(ctx)
		defer stop()
		if err := watchStopFile(ctx, config.StopFile, stop); err != nil {
			return err
		}
	}

	var b backend
	switch config.Backend {
	case backendProcess:
		b, err = newProcessBackend(&config, log)
	default:
		b, err = newDockerBackend(ctx, &config, log)
	}
	if err != nil {
		return err
	}

	p := newPool(config.MaxJobs)
	scalers := make(map[string]*repoScaler, len(config.Repos))
	for _, repo := range config.Repos {
		scalers[repo] = newRepoScaler(repo, &config, p, b, log.With("repo", repo))
	}
	left, err := b.running(ctx)
	if err != nil {
		return err
	}
	for _, f := range left {
		if s := scalers[f.repo]; s != nil {
			s.adopt(ctx, f)
		} else {
			b.remove(ctx, f.handle)
		}
	}

	log.Info("serving", "backend", config.Backend, "repos", len(config.Repos), "maxJobs", config.MaxJobs)
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
	b.shutdown(context.WithoutCancel(ctx))
	log.Info("stopped")
	return nil
}

// watchStopFile removes a stop file an earlier run left, then calls stop once the file
// appears again.
func watchStopFile(ctx context.Context, path string, stop context.CancelFunc) error {
	if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("clear the stop file: %w", err)
	}
	go func() {
		tick := time.NewTicker(2 * time.Second)
		defer tick.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-tick.C:
				if _, err := os.Stat(path); err == nil {
					stop()
					return
				}
			}
		}
	}()
	return nil
}
