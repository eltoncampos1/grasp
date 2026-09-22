// Package comments keeps review comment threads in .grasp/comments.json under
// the checkout the review was started from — never in a PR worktree, so a
// review outlives the tree it was written against.
package comments

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"
)

type Comment struct {
	ID     string `json:"id"`
	Author string `json:"author"`
	Body   string `json:"body"`
	At     string `json:"at"`
}

type Thread struct {
	ID           string    `json:"id"`
	Function     string    `json:"function"` // indexed function id
	File         string    `json:"file"`
	Line         int       `json:"line"` // new side: absolute; base side: line within base_source
	Side         string    `json:"side"` // "new" | "base"
	Resolved     bool      `json:"resolved"`
	PublishedURL string    `json:"published_url,omitempty"`
	Comments     []Comment `json:"comments"`
}

type Doc struct {
	Version int       `json:"version"`
	Threads []*Thread `json:"threads"`
}

// Store serializes access to one comments.json.
type Store struct {
	Path string
	mu   sync.Mutex
}

func NewStore(root string) *Store {
	return &Store{Path: filepath.Join(root, ".grasp", "comments.json")}
}

func (s *Store) Load() (*Doc, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.load()
}

func (s *Store) load() (*Doc, error) {
	doc := &Doc{Version: 1, Threads: []*Thread{}}
	data, err := os.ReadFile(s.Path)
	if os.IsNotExist(err) {
		return doc, nil
	}
	if err != nil {
		return nil, err
	}
	if err := json.Unmarshal(data, doc); err != nil {
		return nil, fmt.Errorf("cannot parse %s: %w", s.Path, err)
	}
	if doc.Threads == nil {
		doc.Threads = []*Thread{}
	}
	return doc, nil
}

func (s *Store) save(doc *Doc) error {
	if err := os.MkdirAll(filepath.Dir(s.Path), 0o755); err != nil {
		return err
	}
	data, err := json.MarshalIndent(doc, "", "  ")
	if err != nil {
		return err
	}
	tmp := s.Path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, s.Path)
}

// Mutate loads, applies fn, and saves atomically under the lock.
func (s *Store) Mutate(fn func(doc *Doc) error) (*Doc, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	doc, err := s.load()
	if err != nil {
		return nil, err
	}
	if err := fn(doc); err != nil {
		return nil, err
	}
	if err := s.save(doc); err != nil {
		return nil, err
	}
	return doc, nil
}

func (s *Store) AddThread(function, file string, line int, side, author, body string) (*Doc, error) {
	if side != "base" {
		side = "new"
	}
	return s.Mutate(func(doc *Doc) error {
		doc.Threads = append(doc.Threads, &Thread{
			ID:       newID("t"),
			Function: function,
			File:     file,
			Line:     line,
			Side:     side,
			Comments: []Comment{newComment(author, body)},
		})
		return nil
	})
}

func (s *Store) Reply(threadID, author, body string) (*Doc, error) {
	return s.Mutate(func(doc *Doc) error {
		t := find(doc, threadID)
		if t == nil {
			return fmt.Errorf("no thread %s", threadID)
		}
		t.Comments = append(t.Comments, newComment(author, body))
		return nil
	})
}

func (s *Store) SetResolved(threadID string, resolved bool) (*Doc, error) {
	return s.Mutate(func(doc *Doc) error {
		t := find(doc, threadID)
		if t == nil {
			return fmt.Errorf("no thread %s", threadID)
		}
		t.Resolved = resolved
		return nil
	})
}

func (s *Store) Delete(threadID string) (*Doc, error) {
	return s.Mutate(func(doc *Doc) error {
		for i, t := range doc.Threads {
			if t.ID == threadID {
				doc.Threads = append(doc.Threads[:i], doc.Threads[i+1:]...)
				return nil
			}
		}
		return fmt.Errorf("no thread %s", threadID)
	})
}

func (s *Store) MarkPublished(threadID, url string) (*Doc, error) {
	return s.Mutate(func(doc *Doc) error {
		if t := find(doc, threadID); t != nil {
			t.PublishedURL = url
		}
		return nil
	})
}

func find(doc *Doc, id string) *Thread {
	for _, t := range doc.Threads {
		if t.ID == id {
			return t
		}
	}
	return nil
}

func newComment(author, body string) Comment {
	return Comment{
		ID:     newID("c"),
		Author: author,
		Body:   body,
		At:     time.Now().UTC().Format(time.RFC3339),
	}
}

func newID(prefix string) string {
	b := make([]byte, 6)
	_, _ = rand.Read(b)
	return prefix + "_" + hex.EncodeToString(b)
}
