package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

type Result struct {
	Entry          string
	Status         string
	CacheHit       bool
	MatchedNothing bool
	Published      int
	Error          string
	Transcript     string
}

type commandWriter struct {
	mu     sync.Mutex
	writer io.Writer
}

func (w *commandWriter) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.writer.Write(p)
}

func runCommand(ctx context.Context, transcript io.Writer, name string, args ...string) (string, error) {
	quoted := make([]string, len(args))
	for i, arg := range args {
		quoted[i] = arg
		if strings.ContainsAny(arg, " \t\n\"'\\$`&;()<>|*?[]{}#") {
			quoted[i] = "'" + strings.ReplaceAll(arg, "'", "'\"'\"'") + "'"
		}
	}
	if _, err := fmt.Fprintf(transcript, "\n$ %s %s\n", name, strings.Join(quoted, " ")); err != nil {
		return "", err
	}
	cmd := exec.CommandContext(ctx, name, args...)
	if name == "git" {
		cmd.Env = append(os.Environ(), "GIT_TERMINAL_PROMPT=0")
	}
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error {
		err := syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		if err == syscall.ESRCH {
			return os.ErrProcessDone
		}
		return err
	}
	cmd.WaitDelay = time.Second
	var stdout bytes.Buffer
	stream := &commandWriter{writer: transcript}
	cmd.Stdout = io.MultiWriter(stream, &stdout)
	cmd.Stderr = stream
	err := cmd.Run()
	if ctx.Err() != nil {
		err = ctx.Err()
	}
	return stdout.String(), err
}

func runNix(ctx context.Context, transcript io.Writer, args ...string) (string, error) {
	command := make([]string, 0, len(args)+9)
	command = append(command, args[0], "--extra-experimental-features", "nix-command flakes", "--option", "narinfo-cache-positive-ttl", "0", "--option", "narinfo-cache-negative-ttl", "0", "--no-write-lock-file")
	command = append(command, args[1:]...)
	return runCommand(ctx, transcript, "nix", command...)
}

func expandEntries(ctx context.Context, cfg Config, flake string, entries []string) []Result {
	var jobs []Result
	expanded := 0
	for _, entry := range entries {
		prefix, pattern, glob, parseErr := parseEntry(entry)
		result := Result{Entry: entry, Status: "failed"}
		if parseErr != nil {
			result.Error = parseErr.Error()
			jobs = append(jobs, result)
			continue
		}
		if !glob {
			jobs = append(jobs, Result{Entry: entry})
			continue
		}
		jobCtx, cancel := context.WithTimeout(ctx, cfg.JobTimeout)
		var transcript bytes.Buffer
		output, err := runNix(jobCtx, &transcript, "eval", "--json", "--apply", "builtins.attrNames", "--option", "allow-import-from-derivation", "false", "--", flake+"#"+prefix)
		cancel()
		var names []string
		if err == nil {
			err = json.Unmarshal([]byte(output), &names)
		}
		if err != nil {
			result.Error = fmt.Sprintf("glob expansion: %v\n%s", err, transcript.String())
			result.Transcript = transcript.String()
			jobs = append(jobs, result)
			continue
		}
		var matched []Result
		for _, name := range names {
			match, matchErr := path.Match(pattern, name)
			if matchErr != nil {
				err = matchErr
				break
			}
			if match {
				if expanded+len(matched) >= cfg.GlobCap {
					err = fmt.Errorf("glob exceeds per-event cap of %d", cfg.GlobCap)
					break
				}
				matched = append(matched, Result{Entry: prefix + "." + strconv.Quote(name), Transcript: transcript.String()})
			}
		}
		if err != nil {
			result.Error = err.Error()
			result.Transcript = transcript.String()
			jobs = append(jobs, result)
			continue
		}
		expanded += len(matched)
		if len(matched) == 0 {
			result.Status = "succeeded"
			result.MatchedNothing = true
			result.Transcript = transcript.String() + "\nThe glob matched nothing.\n"
			jobs = append(jobs, result)
		} else {
			jobs = append(jobs, matched...)
		}
	}
	return jobs
}

var copiedPaths = regexp.MustCompile(`(?m)^copying ([0-9]+) paths`)

func RunJob(ctx context.Context, cfg Config, flake, entry string, force bool, record io.Writer) Result {
	ctx, cancel := context.WithTimeout(ctx, cfg.JobTimeout)
	defer cancel()
	result := Result{Entry: entry, Status: "succeeded"}
	var transcript bytes.Buffer
	var stream io.Writer = &transcript
	if record != nil {
		stream = io.MultiWriter(&transcript, record)
	}
	if cfg.Cache == nil {
		buildStart := transcript.Len()
		_, err := runNix(ctx, stream, "build", "--no-link", "--print-build-logs", "--", flake+"#"+entry)
		if err != nil {
			result.Status = "failed"
			detail := transcript.Bytes()[buildStart:]
			if start := bytes.Index(detail, []byte("\nerror:")); start >= 0 {
				detail = detail[start+1:]
				if len(detail) > 4096 {
					result.Error = strings.TrimSpace(string(detail[:4096])) + "\nSee the full transcript for the remaining error."
				} else {
					result.Error = strings.TrimSpace(string(detail))
				}
			} else {
				result.Error = fmt.Sprintf("nix build: %v", err)
			}
			if ctx.Err() == context.Canceled {
				result.Status = "stopped"
			}
		}
		result.Transcript = transcript.String()
		return result
	}
	out, err := runNix(ctx, stream, "eval", "--raw", "--option", "allow-import-from-derivation", "false", "--", flake+"#"+entry+".outPath")
	if err == nil && out != "" && !force {
		if published, probeErr := runNix(ctx, stream, "path-info", "--store", cfg.Cache.StoreURL(), "--", out); probeErr == nil && strings.TrimSuffix(published, "\n") == out {
			result.CacheHit = true
			result.Transcript = transcript.String()
			return result
		}
	}
	copyStart := transcript.Len()
	_, err = runNix(ctx, stream, "copy", "--to", cfg.Cache.StoreURL(), "--print-build-logs", "--", flake+"#"+entry)
	if err != nil {
		result.Status = "failed"
		detail := transcript.Bytes()[copyStart:]
		if start := bytes.Index(detail, []byte("\nerror:")); start >= 0 {
			detail = detail[start+1:]
			if len(detail) > 4096 {
				result.Error = strings.TrimSpace(string(detail[:4096])) + "\nSee the full transcript for the remaining error."
			} else {
				result.Error = strings.TrimSpace(string(detail))
			}
		} else {
			result.Error = fmt.Sprintf("nix copy: %v", err)
		}
		if ctx.Err() == context.Canceled {
			result.Status = "stopped"
		}
	} else if match := copiedPaths.FindSubmatch(transcript.Bytes()[copyStart:]); match != nil {
		result.Published, _ = strconv.Atoi(string(match[1]))
	}
	result.Transcript = transcript.String()
	return result
}
