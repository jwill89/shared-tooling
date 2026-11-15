package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strconv"
)

// killTree ends a process and every process it started, as a runner's worker and the
// job's own processes are.
func killTree(p *os.Process) error {
	//nolint:gosec // G204: taskkill with a process id
	if out, err := exec.CommandContext(context.Background(), "taskkill", "/T", "/F", "/PID", strconv.Itoa(p.Pid)).CombinedOutput(); err != nil {
		return fmt.Errorf("taskkill: %w: %s", err, out)
	}
	return nil
}

// socketGroup is a Unix socket's group; Windows has none.
func socketGroup(string) (int, error) {
	return 0, errors.New("a job's Docker access needs the scaler on Linux")
}
