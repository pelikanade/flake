package main

import (
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"gorm.io/gorm"
)

// BuildEvent is a request to build a repository's current default-branch head.
// Force marks Build now, which skips the last-built check and the probe; the
// index page shows a waiting event's age, so the time it was raised is kept.
type BuildEvent struct {
	Force      bool
	ReceivedAt time.Time
}
type repositoryRun struct {
	repository Repository
	queued     *BuildEvent
	active     bool
	cancel     context.CancelFunc
	wake       chan struct{}
}
type Server struct {
	cfg        Config
	db         *gorm.DB
	ctx        context.Context
	cancel     context.CancelFunc
	wg         sync.WaitGroup
	mu         sync.Mutex
	repos      map[string]*repositoryRun
	activeJobs map[uint64]*repositoryRun
	slots      chan struct{}
	client     *http.Client
}

func NewServer(cfg Config) (*Server, error) {
	db, err := openState(cfg.StateDir)
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithCancel(context.Background())
	s := &Server{cfg: cfg, db: db, ctx: ctx, cancel: cancel, repos: make(map[string]*repositoryRun), activeJobs: make(map[uint64]*repositoryRun), slots: make(chan struct{}, cfg.GlobalBuildCap), client: &http.Client{Timeout: 15 * time.Second}}
	for _, repo := range cfg.Repositories {
		state := RepositoryState{Name: repo.Name}
		if err := db.FirstOrCreate(&state, RepositoryState{Name: repo.Name}).Error; err != nil {
			s.Close()
			return nil, err
		}
		s.repos[repo.Name] = &repositoryRun{repository: repo, wake: make(chan struct{}, 1)}
	}
	var recordedRepos []string
	if err := db.Model(&Job{}).Distinct("repo").Pluck("repo", &recordedRepos).Error; err != nil {
		s.Close()
		return nil, err
	}
	for _, name := range recordedRepos {
		if err := pruneHistory(db, name, cfg.Retention); err != nil {
			s.Close()
			return nil, err
		}
	}
	for _, repo := range s.repos {
		s.wg.Add(1)
		go s.runRepository(repo)
	}
	if cfg.PollInterval > 0 {
		s.wg.Add(1)
		go s.pollRepositories()
	}
	return s, nil
}

func (s *Server) pollRepositories() {
	defer s.wg.Done()
	for {
		for _, repo := range s.repos {
			s.enqueue(repo, BuildEvent{ReceivedAt: time.Now().UTC()})
		}
		select {
		case <-s.ctx.Done():
			return
		case <-time.After(s.cfg.PollInterval):
		}
	}
}

func (s *Server) Close() {
	s.cancel()
	s.wg.Wait()
	if db, err := s.db.DB(); err == nil {
		db.Close()
	}
}

func (s *Server) enqueue(repo *repositoryRun, event BuildEvent) {
	s.mu.Lock()
	if repo.queued == nil || event.Force || !repo.queued.Force {
		repo.queued = &event
	}
	s.mu.Unlock()
	select {
	case repo.wake <- struct{}{}:
	default:
	}
}

func (s *Server) runRepository(repo *repositoryRun) {
	defer s.wg.Done()
	for {
		select {
		case <-s.ctx.Done():
			return
		case <-repo.wake:
		}
		for {
			s.mu.Lock()
			if repo.queued == nil || s.ctx.Err() != nil {
				s.mu.Unlock()
				break
			}
			event := *repo.queued
			repo.queued = nil
			repo.active = true
			ctx, cancel := context.WithCancel(s.ctx)
			repo.cancel = cancel
			s.mu.Unlock()
			s.runEvent(ctx, repo, event)
			cancel()
			if s.ctx.Err() == nil {
				if err := pruneHistory(s.db, repo.repository.Name, s.cfg.Retention); err != nil {
					log.Printf("retention for %s: %v", repo.repository.Name, err)
				}
			}
			s.mu.Lock()
			repo.active = false
			repo.cancel = nil
			s.mu.Unlock()
		}
	}
}

func resolveHead(ctx context.Context, repo Repository) (branch, commit string, err error) {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	var transcript bytes.Buffer
	out, err := runCommand(ctx, &transcript, "git", "ls-remote", "--symref", "--exit-code", "--", repo.URL, "HEAD")
	if err != nil {
		return "", "", fmt.Errorf("resolve default branch: %w\n%s", err, transcript.String())
	}
	for _, line := range strings.Split(out, "\n") {
		fields := strings.Fields(line)
		if len(fields) == 3 && fields[0] == "ref:" && fields[2] == "HEAD" {
			branch = fields[1]
		}
		if len(fields) == 2 && fields[1] == "HEAD" {
			commit = fields[0]
		}
	}
	if !strings.HasPrefix(branch, "refs/heads/") || len(commit) != 40 && len(commit) != 64 {
		return "", "", fmt.Errorf("remote HEAD must name a default branch and commit")
	}
	if _, err := hex.DecodeString(commit); err != nil {
		return "", "", fmt.Errorf("remote HEAD contains an invalid commit")
	}
	return branch, commit, nil
}

func (s *Server) checkout(ctx context.Context, repo Repository, commit string) (string, error) {
	directory := filepath.Join(s.cfg.StateDir, "checkouts", repo.Name)
	if err := os.MkdirAll(directory, 0700); err != nil {
		return "", err
	}
	ctx, cancel := context.WithTimeout(ctx, s.cfg.JobTimeout)
	defer cancel()
	var transcript bytes.Buffer
	commands := [][]string{{"init", "--quiet", directory}, {"-C", directory, "fetch", "--quiet", "--force", "--no-tags", "--", repo.URL, commit}, {"-C", directory, "checkout", "--quiet", "--detach", "--force", commit}}
	for _, args := range commands {
		if _, err := runCommand(ctx, &transcript, "git", args...); err != nil {
			return "", fmt.Errorf("checkout: %w\n%s", err, transcript.String())
		}
	}
	return directory, nil
}

func (s *Server) runEvent(ctx context.Context, repo *repositoryRun, event BuildEvent) {
	_, commit, err := resolveHead(ctx, repo.repository)
	if err != nil {
		s.recordResult(repo.repository.Name, "failure", err.Error(), "")
		return
	}
	var state RepositoryState
	if err := s.db.First(&state, "name = ?", repo.repository.Name).Error; err != nil {
		log.Printf("read repository state: %v", err)
		return
	}
	if !event.Force && state.LastBuilt == commit {
		return
	}
	s.recordResult(repo.repository.Name, "running", "", "")
	s.report(repo.repository, commit, "pending", "Building declared entries")
	checkout, err := s.checkout(ctx, repo.repository, commit)
	var entries []string
	if err == nil {
		entries, err = LoadBuildList(checkout)
	}
	if err != nil {
		if s.ctx.Err() != nil {
			return
		}
		s.recordResult(repo.repository.Name, "failure", err.Error(), "")
		s.report(repo.repository, commit, "failure", "Build list could not be read: "+err.Error())
		return
	}
	planned := expandEntries(ctx, s.cfg, checkout, entries)
	// Every planned entry gets a record before anything runs. The UI is the only
	// control surface, so an entry that is planned but still waiting for a global
	// build slot has to be visible while the event runs, instead of appearing only
	// when it starts (ADR 0025).
	jobs := make([]Job, len(planned))
	for i, plan := range planned {
		job := Job{Repo: repo.repository.Name, Commit: commit, Result: Result{Entry: plan.Entry, Status: "planned", Transcript: plan.Transcript}}
		if err := s.db.Create(&job).Error; err != nil {
			s.recordResult(repo.repository.Name, "failure", "could not record the event's jobs: "+err.Error(), "")
			s.report(repo.repository, commit, "failure", "Could not record the event's jobs")
			return
		}
		jobs[i] = job
	}
	var workers sync.WaitGroup
	var resultMu sync.Mutex
	failed := 0
	eventError := ""
schedule:
	for i, job := range jobs {
		plan := planned[i]
		select {
		case <-ctx.Done():
			break schedule
		case s.slots <- struct{}{}:
		}
		s.mu.Lock()
		if ctx.Err() != nil {
			s.mu.Unlock()
			<-s.slots
			break
		}
		started := time.Now().UTC()
		err := s.db.Model(&Job{}).Where("id = ?", job.ID).Updates(map[string]any{"status": "running", "started_at": started}).Error
		if err == nil {
			jobs[i].Result.Status = "running"
			jobs[i].StartedAt = started
			job.Result.Status = "running"
			job.StartedAt = started
			s.activeJobs[job.ID] = repo
		}
		s.mu.Unlock()
		if err != nil {
			<-s.slots
			resultMu.Lock()
			eventError = err.Error()
			resultMu.Unlock()
			break
		}
		workers.Add(1)
		go func(job Job, plan Result) {
			defer workers.Done()
			defer func() { <-s.slots }()
			result := plan
			if plan.Status == "" {
				result = RunJob(ctx, s.cfg, checkout, plan.Entry, event.Force, transcriptWriter{s.db, job.ID})
				result.Transcript = plan.Transcript + result.Transcript
			}
			s.mu.Lock()
			delete(s.activeJobs, job.ID)
			s.mu.Unlock()
			if s.ctx.Err() != nil {
				return
			}
			now := time.Now().UTC()
			job.Result = result
			job.FinishedAt = &now
			err := s.db.Save(&job).Error
			resultMu.Lock()
			defer resultMu.Unlock()
			if result.Status == "failed" {
				failed++
			}
			if err != nil {
				eventError = err.Error()
			}
		}(job, plan)
	}
	workers.Wait()
	for _, job := range jobs {
		if job.Result.Status != "planned" {
			continue
		}
		if err := s.db.Model(&Job{}).Where("id = ?", job.ID).Updates(map[string]any{"status": "stopped", "error": "The event ended before this job started."}).Error; err != nil {
			log.Printf("close unstarted job %d: %v", job.ID, err)
		}
	}
	if s.ctx.Err() != nil {
		return
	}
	status, description, built := "success", "All entries succeeded", commit
	if ctx.Err() != nil {
		status, description, built = "error", "stopped by the operator", ""
	} else if eventError != "" {
		status, description, built = "failure", eventError, ""
	} else if failed > 0 {
		status, description, built = "failure", fmt.Sprintf("%d of %d entries failed", failed, len(planned)), ""
	}
	detail := ""
	if status != "success" {
		detail = description
	}
	s.recordResult(repo.repository.Name, status, detail, built)
	s.report(repo.repository, commit, status, description)
}

func (s *Server) recordResult(repo, status, detail, commit string) {
	updates := map[string]any{"last_result": status, "last_error": detail, "updated_at": time.Now().UTC()}
	if commit != "" {
		updates["last_built"] = commit
	}
	if err := s.db.Model(&RepositoryState{}).Where("name = ?", repo).Updates(updates).Error; err != nil {
		log.Printf("record repository result: %v", err)
	}
}

func (s *Server) report(repo Repository, commit, state, description string) {
	if len([]rune(description)) > 140 {
		description = string([]rune(description)[:140])
	}
	payload := map[string]string{"state": state, "description": description, "context": "freezer"}
	if s.cfg.PublicURL != "" {
		payload["target_url"] = strings.TrimRight(s.cfg.PublicURL, "/") + "/#repo-" + repo.Name
	}
	body, _ := json.Marshal(payload)
	request, err := http.NewRequestWithContext(s.ctx, "POST", s.cfg.GitHubAPIBase+"/repos/"+repo.GitHub+"/statuses/"+commit, bytes.NewReader(body))
	if err == nil {
		request.Header.Set("Authorization", "Bearer "+s.cfg.GitHubToken)
		request.Header.Set("Content-Type", "application/json")
		request.Header.Set("Accept", "application/vnd.github+json")
		request.Header.Set("X-GitHub-Api-Version", "2022-11-28")
		var response *http.Response
		response, err = s.client.Do(request)
		if err == nil {
			io.Copy(io.Discard, response.Body)
			response.Body.Close()
			if response.StatusCode != http.StatusCreated {
				err = fmt.Errorf("GitHub returned HTTP %d", response.StatusCode)
			}
		}
	}
	if err != nil && s.ctx.Err() == nil {
		log.Printf("commit status %s/%s: %v", repo.Name, commit, err)
		s.db.Model(&RepositoryState{}).Where("name = ?", repo.Name).Update("last_error", "Commit status delivery failed: "+err.Error())
	}
}

func (s *Server) buildNow(w http.ResponseWriter, r *http.Request) {
	repo := s.repos[r.PathValue("repo")]
	if repo == nil {
		s.errorPage(w, r, 404, "Repository not registered", "Register it in the server configuration.")
		return
	}
	s.enqueue(repo, BuildEvent{Force: true, ReceivedAt: time.Now().UTC()})
	http.Redirect(w, r, "/?notice=build&repo="+repo.repository.Name, http.StatusSeeOther)
}

func (s *Server) stopJob(w http.ResponseWriter, r *http.Request) {
	job, err := s.findJob(r.PathValue("id"))
	if err != nil {
		s.jobError(w, r, err)
		return
	}
	s.mu.Lock()
	repo := s.activeJobs[job.ID]
	if repo != nil {
		repo.cancel()
	}
	s.mu.Unlock()
	if repo == nil {
		s.errorPage(w, r, 409, "This job is no longer running", "Only a running job can be stopped.")
		return
	}
	http.Redirect(w, r, fmt.Sprintf("/jobs/%d?notice=stop", job.ID), http.StatusSeeOther)
}

func (s *Server) findJob(id string) (Job, error) {
	var job Job
	if id == "" || strings.Trim(id, "0123456789") != "" {
		return job, gorm.ErrRecordNotFound
	}
	err := s.db.First(&job, "id = ?", id).Error
	return job, err
}

func (s *Server) jobError(w http.ResponseWriter, r *http.Request, err error) {
	if errors.Is(err, gorm.ErrRecordNotFound) {
		s.errorPage(w, r, 404, "Job not found", "The job is missing or never existed.")
	} else {
		s.errorPage(w, r, 500, "Could not read job", err.Error())
	}
}
