package main

import (
	"context"
	"fmt"
	"sync"
	"testing"
)

func TestCapacity(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name                string
		maxJobs, total, own int
		want                int
	}{
		{"an idle machine offers all its room", 6, 0, 0, 6},
		{"a repo keeps its own and gets the room left", 6, 4, 2, 4},
		{"a full machine offers only a repo's own", 6, 6, 3, 3},
		{"an overfull machine offers only a repo's own", 6, 8, 1, 1},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			if got := capacity(tt.maxJobs, tt.total, tt.own); got != tt.want {
				t.Errorf("capacity(%d, %d, %d) = %d, want %d", tt.maxJobs, tt.total, tt.own, got, tt.want)
			}
		})
	}
}

// pollFor opens a poll for repo and returns the capacity it offered and a context the pool
// cancels when it cuts the poll short.
func pollFor(p *pool, repo string) (int, context.Context) {
	ctx, cancel := context.WithCancel(context.Background())
	return p.beginPoll(repo, cancel), ctx
}

func TestPoolCutsPollsShortWhenTheRoomChanges(t *testing.T) {
	t.Parallel()
	p := newPool(2)

	offered, roomy := pollFor(p, "a")
	if offered != 2 {
		t.Fatalf("an idle machine offered %d, want 2", offered)
	}
	p.add("b")
	if roomy.Err() != nil {
		t.Fatal("a poll was cut short while room was left")
	}
	p.add("b")
	if roomy.Err() == nil {
		t.Fatal("a poll offering room wasn't cut short when the machine filled")
	}
	p.endPoll("a")

	offered, full := pollFor(p, "a")
	if offered != 0 {
		t.Fatalf("a full machine offered %d to a repo with no runners, want 0", offered)
	}
	offered, own := pollFor(p, "b")
	if offered != 2 {
		t.Fatalf("a full machine offered %d to a repo with 2 runners, want 2", offered)
	}
	p.done("b")
	if full.Err() == nil || own.Err() == nil {
		t.Fatal("the polls offering no room weren't cut short when room came free")
	}
}

func TestPoolReservesNoMoreThanTheRoom(t *testing.T) {
	t.Parallel()
	p := newPool(7)
	if got := p.reserve("a", 25); got != 7 {
		t.Fatalf("25 jobs on an idle machine of 7 got %d places, want 7", got)
	}
	if got := p.reserve("b", 1); got != 0 {
		t.Fatalf("a full machine gave %d places, want 0", got)
	}
	if got := p.reserve("a", 0); got != 0 {
		t.Fatalf("wanting none gave %d places", got)
	}
	p.done("a")
	if got := p.reserve("b", 3); got != 1 {
		t.Fatalf("a freed place gave %d, want 1", got)
	}
	if offered, _ := pollFor(p, "a"); offered != 6 {
		t.Fatalf("a full machine offered %d to a repo with 6 runners, want 6", offered)
	}
}

func TestPoolReservesTheLastPlaceOnce(t *testing.T) {
	t.Parallel()
	const repos, maxJobs = 18, 7
	p := newPool(maxJobs)
	var wg sync.WaitGroup
	got := make([]int, repos)
	for i := range repos {
		wg.Go(func() { got[i] = p.reserve(fmt.Sprint("repo-", i), 3) })
	}
	wg.Wait()
	total := 0
	for _, n := range got {
		total += n
	}
	if total != maxJobs {
		t.Fatalf("repos reserving side by side got %d places, want %d", total, maxJobs)
	}
}

func TestPoolCutsPollsShortWhenAReservationFillsIt(t *testing.T) {
	t.Parallel()
	p := newPool(3)
	_, roomy := pollFor(p, "a")
	p.reserve("b", 2)
	if roomy.Err() != nil {
		t.Fatal("a poll was cut short while room was left")
	}
	p.reserve("b", 5)
	if roomy.Err() == nil {
		t.Fatal("a poll offering room wasn't cut short when a reservation filled the machine")
	}
}

func TestPoolCountsAnAdoptedRunnerPastTheLimit(t *testing.T) {
	t.Parallel()
	p := newPool(1)
	p.add("a")
	p.add("a")
	if got := p.reserve("b", 1); got != 0 {
		t.Fatalf("an overfull machine gave %d places, want 0", got)
	}
	p.done("a")
	if got := p.reserve("b", 1); got != 0 {
		t.Fatalf("a machine still full gave %d places, want 0", got)
	}
	p.done("a")
	if got := p.reserve("b", 1); got != 1 {
		t.Fatalf("a machine with room gave %d places, want 1", got)
	}
}

func TestPoolInterruptsOneRepo(t *testing.T) {
	t.Parallel()
	p := newPool(4)
	_, mine := pollFor(p, "a")
	_, other := pollFor(p, "b")
	p.interrupt("a")
	if mine.Err() == nil || other.Err() != nil {
		t.Fatal("interrupt didn't cut short only the repo's own poll")
	}
	p.interrupt("c") // a repo with no poll open
}

func TestPoolIgnoresARepoWithNoRunners(t *testing.T) {
	t.Parallel()
	p := newPool(1)
	p.done("a")
	if offered, _ := pollFor(p, "a"); offered != 1 {
		t.Fatalf("offered %d after a stray done, want 1", offered)
	}
}
