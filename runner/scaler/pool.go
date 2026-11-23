package main

import (
	"context"
	"sync"
)

// pool shares the machine's limit on jobs among the repos. Each repo's poll tells GitHub
// how many runners the repo may have, its own and the room left on the machine, which
// GitHub takes as a hint: it can still assign a repo more jobs than that. So a repo
// reserves a place here before it starts each runner, and a job with no place left waits,
// assigned, until a runner exits and frees one.
type pool struct {
	mu      sync.Mutex
	max     int
	total   int
	running map[string]int
	polls   map[string]openPoll
}

// openPoll is a repo's poll in flight: how to cut it short, and whether it offered GitHub
// no room beyond the repo's own runners.
type openPoll struct {
	cancel context.CancelFunc
	full   bool
}

func newPool(maxJobs int) *pool {
	return &pool{max: maxJobs, running: map[string]int{}, polls: map[string]openPoll{}}
}

// capacity is how many runners a repo may have: the ones it has, and whatever room the
// machine has left.
func capacity(maxJobs, total, own int) int {
	return own + max(0, maxJobs-total)
}

// beginPoll records a repo's poll, which cancel cuts short, and returns the capacity it
// offers GitHub.
func (p *pool) beginPoll(repo string, cancel context.CancelFunc) int {
	p.mu.Lock()
	defer p.mu.Unlock()
	own := p.running[repo]
	offered := capacity(p.max, p.total, own)
	p.polls[repo] = openPoll{cancel: cancel, full: offered == own}
	return offered
}

// endPoll forgets a repo's poll once it has returned.
func (p *pool) endPoll(repo string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	delete(p.polls, repo)
}

// reserve claims places for up to want of a repo's new runners, as many as the machine
// has room for, and counts them at once, so repos planning side by side can't both take
// the last place. It returns how many it claimed; done gives back a place whose runner
// didn't start. When that fills the machine, the polls that offered room are cut short,
// and each asks again offering none.
func (p *pool) reserve(repo string, want int) int {
	p.mu.Lock()
	defer p.mu.Unlock()
	got := min(want, max(0, p.max-p.total))
	if got <= 0 {
		return 0
	}
	p.running[repo] += got
	p.total += got
	if p.total >= p.max {
		p.cancelPolls(false)
	}
	return got
}

// add counts a runner already running, one an earlier run of the scaler left, whether or
// not the machine has room for it.
func (p *pool) add(repo string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.running[repo]++
	p.total++
	if p.total >= p.max {
		p.cancelPolls(false)
	}
}

// done counts a repo's runner gone, or gives back a place it reserved for one that didn't
// start. When that frees room on a full machine, the polls that offered none are cut
// short, and each asks again offering the room.
func (p *pool) done(repo string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.running[repo] == 0 {
		return
	}
	p.running[repo]--
	if p.running[repo] == 0 {
		delete(p.running, repo)
	}
	p.total--
	if p.total == p.max-1 {
		p.cancelPolls(true)
	}
}

// interrupt cuts a repo's poll short, so the repo plans again at once rather than when the
// poll ends: after one of its runners exits, say, the last statistics still counted it.
func (p *pool) interrupt(repo string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if poll, ok := p.polls[repo]; ok {
		poll.cancel()
		delete(p.polls, repo)
	}
}

func (p *pool) cancelPolls(full bool) {
	for repo, poll := range p.polls {
		if poll.full == full {
			poll.cancel()
			delete(p.polls, repo)
		}
	}
}
