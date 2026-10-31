// Package web serves the nvirellia.im profile sheet and its static assets.
package web

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"html/template"
	"io"
	"io/fs"
	"log"
	"net/http"

	"github.com/pelikanade/nvirellia.im/internal/feed"
)

// Feeds supplies the current feed snapshot.
type Feeds interface {
	Feed() feed.Feed
}

type server struct {
	feeds Feeds
	pages *template.Template
}

// NewHandler routes the site from assets, which must contain templates/ and static/.
func NewHandler(feeds Feeds, assets fs.FS) (http.Handler, error) {
	static, err := fs.Sub(assets, "static")
	if err != nil {
		return nil, err
	}
	funcs := template.FuncMap{
		"icon":  icon,
		"asset": assetURL(static),
	}
	pages, err := template.New("").Funcs(funcs).ParseFS(assets, "templates/*.html")
	if err != nil {
		return nil, err
	}

	s := &server{feeds: feeds, pages: pages}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /{$}", s.index)
	mux.HandleFunc("GET /healthz", healthz)
	mux.Handle("GET /static/", http.StripPrefix("/static/", longCache(http.FileServerFS(static))))
	return mux, nil
}

func (s *server) index(w http.ResponseWriter, _ *http.Request) {
	p, err := newPage(s.feeds.Feed())
	if err != nil {
		serverError(w, "build page", err)
		return
	}
	var buf bytes.Buffer
	if err := s.pages.ExecuteTemplate(&buf, "layout.html", p); err != nil {
		serverError(w, "render layout.html", err)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Write(buf.Bytes())
}

func healthz(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	io.WriteString(w, "ok")
}

func assetURL(static fs.FS) func(string) (string, error) {
	return func(name string) (string, error) {
		b, err := fs.ReadFile(static, name)
		if err != nil {
			return "", err
		}
		h := sha256.Sum256(b)
		return "/static/" + name + "?v=" + hex.EncodeToString(h[:])[:12], nil
	}
}

func longCache(h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "public, max-age=604800")
		h.ServeHTTP(w, r)
	})
}

func serverError(w http.ResponseWriter, what string, err error) {
	log.Printf("web: %s: %v", what, err)
	http.Error(w, "internal error", http.StatusInternalServerError)
}
