package webserver

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
)

// chatRunner drives the configured coding-agent CLI headless: one run at a
// time, the reviewed tree as its working directory, the chosen profile pinned
// in the environment. A follow-up resumes the same CLI conversation per grasp
// session, so the agent remembers what it already looked at.
type chatRunner struct {
	mu       sync.Mutex
	cmd      *exec.Cmd
	running  bool
	resumeID map[string]string // grasp session -> agent conversation id
}

// Tool allowlists per mode, after upstream grasp: read-only gives the agent
// the project's files and nothing that writes; edit adds Edit/Write and a
// Bash narrowed to commands that do not change the checked-out branch.
var chatTools = map[string]string{
	"read": "Read,Grep,Glob",
	"edit": "Read,Grep,Glob,Edit,Write,Bash(mix:*),Bash(go:*),Bash(git status),Bash(git diff:*),Bash(git fetch:*),Bash(gh pr view:*)",
}

var chatModels = map[string]bool{"haiku": true, "sonnet": true, "opus": true, "fable": true}

func newChatRunner() *chatRunner {
	return &chatRunner{resumeID: map[string]string{}}
}

func (c *chatRunner) forget(session string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	delete(c.resumeID, session)
}

// handleChat starts one agent run and streams the CLI's stream-json events to
// the browser as SSE. The transcript is the client's to keep; the server only
// remembers the conversation id for resuming.
func (s *Server) handleChat(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	var req struct {
		Message string `json:"message"`
		Mode    string `json:"mode"`
		Model   string `json:"model"`
		Session string `json:"session"`
		Fresh   bool   `json:"fresh"` // new conversation: drop the resume id
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	if strings.TrimSpace(req.Message) == "" {
		http.Error(w, "empty message", http.StatusBadRequest)
		return
	}
	if req.Session == "" {
		req.Session = "default"
	}
	tools, ok := chatTools[req.Mode]
	if !ok {
		tools = chatTools["read"]
	}

	c := s.chat
	c.mu.Lock()
	if c.running {
		c.mu.Unlock()
		http.Error(w, "a run is already in flight — stop it or wait", http.StatusConflict)
		return
	}
	if req.Fresh {
		delete(c.resumeID, req.Session)
	}
	resume := c.resumeID[req.Session]

	command := s.Agent.Command
	if command == "" {
		command = "claude"
	}
	if _, err := exec.LookPath(command); err != nil {
		c.mu.Unlock()
		http.Error(w, command+" is not on PATH — install the CLI or set agent.command", http.StatusFailedDependency)
		return
	}

	args := []string{
		"-p", req.Message,
		"--output-format", "stream-json", "--verbose",
		"--max-turns", "60",
		"--allowedTools", tools,
		"--append-system-prompt", s.chatSystemPrompt(),
	}
	if resume != "" {
		args = append(args, "--resume", resume)
	}
	if chatModels[req.Model] {
		args = append(args, "--model", req.Model)
	} else if s.Agent.Model != "" {
		args = append(args, "--model", s.Agent.Model)
	}

	cmd := exec.Command(command, args...)
	cmd.Dir = s.projectRoot()
	cmd.Env = s.agentEnv()
	stdout, err := cmd.StdoutPipe()
	if err == nil {
		cmd.Stderr = cmd.Stdout // interleave; the client shows stderr lines as errors
		err = cmd.Start()
	}
	if err != nil {
		c.mu.Unlock()
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	c.cmd = cmd
	c.running = true
	c.mu.Unlock()

	defer func() {
		c.mu.Lock()
		c.running = false
		c.cmd = nil
		c.mu.Unlock()
	}()

	flusher, _ := w.(http.Flusher)
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-store")

	scanner := bufio.NewScanner(stdout)
	scanner.Buffer(make([]byte, 1024*1024), 8*1024*1024)
	for scanner.Scan() {
		line := scanner.Text()
		if strings.HasPrefix(line, "{") {
			var probe struct {
				Type      string `json:"type"`
				SessionID string `json:"session_id"`
			}
			if json.Unmarshal([]byte(line), &probe) == nil && probe.SessionID != "" {
				c.mu.Lock()
				c.resumeID[req.Session] = probe.SessionID
				c.mu.Unlock()
			}
			fmt.Fprintf(w, "data: %s\n\n", line)
		} else if line != "" {
			msg, _ := json.Marshal(map[string]string{"type": "stderr", "text": line})
			fmt.Fprintf(w, "data: %s\n\n", msg)
		}
		if flusher != nil {
			flusher.Flush()
		}
	}
	err = cmd.Wait()
	done, _ := json.Marshal(map[string]any{"type": "done", "ok": err == nil})
	fmt.Fprintf(w, "data: %s\n\n", done)
	if flusher != nil {
		flusher.Flush()
	}
}

// handleChatReset forgets a session's conversation id, so the next prompt
// starts a fresh CLI conversation.
func (s *Server) handleChatReset(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Session string `json:"session"`
	}
	_ = json.NewDecoder(r.Body).Decode(&req)
	if req.Session == "" {
		req.Session = "default"
	}
	s.chat.forget(req.Session)
	writeJSON(w, map[string]bool{"reset": true})
}

func (s *Server) handleChatStop(w http.ResponseWriter, r *http.Request) {
	c := s.chat
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.cmd != nil && c.cmd.Process != nil {
		_ = c.cmd.Process.Kill()
	}
	writeJSON(w, map[string]bool{"stopped": true})
}

// chatSystemPrompt gives the agent the review's frame: where the index is,
// what changed, and the team's review rules.
func (s *Server) chatSystemPrompt() string {
	var b strings.Builder
	b.WriteString("You are the review agent inside grasp, a visual code-review tool. ")
	b.WriteString("Your working directory is the tree under review. ")
	b.WriteString("The call-graph index the reviewer sees is the JSON file at " + s.IndexPath + " ")
	b.WriteString("(functions with source, spans, calls and a change classification against the review base). ")

	if data, err := os.ReadFile(s.IndexPath); err == nil {
		var idx struct {
			Git       struct{ BaseRef, Branch string }
			Review    *struct{ PR int }
			Functions []struct{ ID, Change string }
		}
		if json.Unmarshal(data, &idx) == nil {
			var changed []string
			for _, f := range idx.Functions {
				if f.Change != "unchanged" && f.Change != "" {
					changed = append(changed, f.ID+" ("+f.Change+")")
				}
				if len(changed) == 60 {
					changed = append(changed, "…")
					break
				}
			}
			if idx.Review != nil && idx.Review.PR > 0 {
				fmt.Fprintf(&b, "This review is pull request #%d. ", idx.Review.PR)
			}
			if len(changed) > 0 {
				b.WriteString("Functions the branch changed against " + idx.Git.BaseRef + ": " + strings.Join(changed, ", ") + ". ")
			}
		}
	}

	rules := filepath.Join(filepath.Dir(s.Comments.Path), "review.md")
	if data, err := os.ReadFile(rules); err == nil && len(data) > 0 {
		b.WriteString("\n\nThe team's review rules (from .grasp/review.md):\n" + string(data))
	}
	return b.String()
}

// projectRoot is the root of the tree under review — the worktree when the
// index is a pull request's — read from the index so a reload follows it.
func (s *Server) projectRoot() string {
	if data, err := os.ReadFile(s.IndexPath); err == nil {
		var idx struct {
			Project struct {
				Root string `json:"root"`
			} `json:"project"`
		}
		if json.Unmarshal(data, &idx) == nil && idx.Project.Root != "" {
			if st, err := os.Stat(idx.Project.Root); err == nil && st.IsDir() {
				return idx.Project.Root
			}
		}
	}
	return filepath.Dir(filepath.Dir(s.Comments.Path))
}

func (s *Server) agentEnv() []string {
	env := os.Environ()
	if s.Agent.ConfigDir != "" {
		env = append(env, "CLAUDE_CONFIG_DIR="+expandHome(s.Agent.ConfigDir))
	}
	return env
}

func expandHome(path string) string {
	if strings.HasPrefix(path, "~/") {
		if home, err := os.UserHomeDir(); err == nil {
			return filepath.Join(home, path[2:])
		}
	}
	return path
}
