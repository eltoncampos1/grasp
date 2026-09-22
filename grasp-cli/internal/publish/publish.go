// Package publish posts local comment threads to a pull request as GitHub
// review comments, via gh. Shared by `grasp publish` and the MCP server's
// publish_comments tool.
package publish

import (
	"encoding/json"
	"fmt"
	"os/exec"
	"strconv"
	"strings"

	"github.com/eltoncampos1/grasp-cli/internal/comments"
)

type Summary struct {
	Published int
	Skipped   int
	Failed    int
}

// Run publishes every unpublished thread to PR number. A thread on a line the
// PR's diff covers goes on that line; one the diff does not show — or a
// base-side thread, whose line is function-relative — goes on the file with
// its anchor written at the top. Published threads are marked and skipped on
// the next run.
func Run(root string, number int, log func(string)) (Summary, error) {
	var sum Summary
	headSha, err := prHeadSha(root, number)
	if err != nil {
		return sum, err
	}
	store := comments.NewStore(root)
	doc, err := store.Load()
	if err != nil {
		return sum, err
	}
	for _, t := range doc.Threads {
		if t.PublishedURL != "" {
			sum.Skipped++
			continue
		}
		url, err := postThread(root, number, headSha, t)
		if err != nil {
			sum.Failed++
			log(fmt.Sprintf("✗ %s %s:%d — %v", t.ID, t.File, t.Line, err))
			continue
		}
		if _, err := store.MarkPublished(t.ID, url); err != nil {
			return sum, err
		}
		sum.Published++
		log(fmt.Sprintf("✓ %s:%d → %s", t.File, t.Line, url))
	}
	return sum, nil
}

// CurrentPR resolves the pull request the checked-out branch is open on.
func CurrentPR(root string) (int, error) {
	out, err := gh(root, "pr", "view", "--json", "number", "--jq", ".number")
	if err != nil {
		return 0, fmt.Errorf("no pull request for the current branch — name one")
	}
	return strconv.Atoi(strings.TrimSpace(string(out)))
}

func prHeadSha(root string, number int) (string, error) {
	out, err := gh(root, "pr", "view", fmt.Sprint(number), "--json", "headRefOid", "--jq", ".headRefOid")
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}

func postThread(root string, number int, headSha string, t *comments.Thread) (string, error) {
	body := threadBody(t)

	if t.Side == "new" {
		url, err := postComment(root, number, map[string]string{
			"body":      body,
			"commit_id": headSha,
			"path":      t.File,
			"side":      "RIGHT",
		}, t.Line)
		if err == nil {
			return url, nil
		}
		body = fmt.Sprintf("`%s:%d` (outside the diff):\n\n%s", t.File, t.Line, body)
	} else {
		body = fmt.Sprintf("On the base side of `%s`, line %d of `%s`:\n\n%s", t.File, t.Line, t.Function, body)
	}

	return postComment(root, number, map[string]string{
		"body":         body,
		"commit_id":    headSha,
		"path":         t.File,
		"subject_type": "file",
	}, 0)
}

func postComment(root string, number int, fields map[string]string, line int) (string, error) {
	args := []string{"api", fmt.Sprintf("repos/{owner}/{repo}/pulls/%d/comments", number)}
	for k, v := range fields {
		args = append(args, "-f", k+"="+v)
	}
	if line > 0 {
		args = append(args, "-F", "line="+strconv.Itoa(line))
	}
	out, err := gh(root, args...)
	if err != nil {
		return "", err
	}
	var resp struct {
		HTMLURL string `json:"html_url"`
	}
	if err := json.Unmarshal(out, &resp); err != nil {
		return "", err
	}
	return resp.HTMLURL, nil
}

func threadBody(t *comments.Thread) string {
	var parts []string
	for i, c := range t.Comments {
		if i == 0 {
			parts = append(parts, c.Body)
		} else {
			parts = append(parts, fmt.Sprintf("**%s** replied:\n\n%s", c.Author, c.Body))
		}
	}
	return strings.Join(parts, "\n\n---\n\n")
}

func gh(root string, args ...string) ([]byte, error) {
	cmd := exec.Command("gh", args...)
	cmd.Dir = root
	out, err := cmd.Output()
	if err != nil {
		if ee, ok := err.(*exec.ExitError); ok && len(ee.Stderr) > 0 {
			return nil, fmt.Errorf("%s", strings.TrimSpace(string(ee.Stderr)))
		}
		return nil, err
	}
	return out, nil
}
