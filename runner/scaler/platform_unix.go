//go:build !windows

package main

import (
	"errors"
	"fmt"
	"os"
	"syscall"
)

// killTree ends the runner's process. Off Windows the scaler's runners are containers,
// whose processes Docker ends together, so this serves the process backend's tests.
func killTree(p *os.Process) error {
	if err := p.Kill(); err != nil && !errors.Is(err, os.ErrProcessDone) {
		return fmt.Errorf("kill: %w", err)
	}
	return nil
}

// socketGroup is the group that owns a Unix socket, which may use it.
func socketGroup(path string) (int, error) {
	info, err := os.Stat(path)
	if err != nil {
		return 0, fmt.Errorf("read Docker's socket: %w", err)
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return 0, fmt.Errorf("read the group of %s", path)
	}
	return int(stat.Gid), nil
}
