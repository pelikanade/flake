package feed

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strings"
)

// GitHub reads the head commit of a public repository's main branch. The site
// compares each host's nixos_flake_info revision against it to tell whether a
// host runs the published flake.
//
//	GET <api>/repos/<owner>/<repo>/commits/main -> {"sha": "..."}
//
// The request is unauthenticated, so the feed caches the answer for several
// minutes to stay well below GitHub's per-IP limit.
type GitHub struct {
	baseURL string
	repo    string
	client  *http.Client
}

// NewGitHub returns a client for repo ("owner/name") on baseURL. The default
// deployment passes https://api.github.com.
func NewGitHub(baseURL, repo string) (*GitHub, error) {
	if baseURL == "" {
		return nil, errors.New("GITHUB_API_URL is required")
	}
	if _, err := url.Parse(baseURL); err != nil {
		return nil, fmt.Errorf("GITHUB_API_URL: %w", err)
	}
	repo = strings.Trim(strings.TrimSpace(repo), "/")
	if parts := strings.Split(repo, "/"); len(parts) != 2 || parts[0] == "" || parts[1] == "" {
		return nil, fmt.Errorf("FLAKE_REPO: want owner/repo, got %q", repo)
	}
	return &GitHub{
		baseURL: strings.TrimRight(baseURL, "/"),
		repo:    repo,
		client:  &http.Client{},
	}, nil
}

// Revision implements RevisionSource.
func (g *GitHub) Revision(ctx context.Context) (string, error) {
	var body struct {
		SHA string `json:"sha"`
	}
	target := joinURL(g.baseURL, "/repos/"+g.repo+"/commits/main", nil)
	if err := getJSON(ctx, g.client, target, "github", &body); err != nil {
		return "", err
	}
	sha := strings.ToLower(strings.TrimSpace(body.SHA))
	if sha == "" {
		return "", errors.New("github: empty commit sha")
	}
	return sha, nil
}
