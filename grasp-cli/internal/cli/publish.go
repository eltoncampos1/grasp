package cli

import (
	"encoding/json"
	"fmt"
	"os/exec"
	"strconv"
	"strings"

	"github.com/spf13/cobra"

	"github.com/eltoncampos1/grasp-cli/internal/comments"
)

var publishCmd = &cobra.Command{
	Use:   "publish [pr-number]",
	Short: "Send the local comment threads to the pull request on GitHub",
	Long: `Posts each unpublished thread as a review comment, with its replies in the
body. A thread on a line the pull request's diff covers goes on that line;
one the diff does not show — or a comment on the base side — goes on the
file, with the function and line it was written on at the top. Threads
already published are skipped, so publishing again after writing three more
comments only sends those.

Without a number, publishes to the pull request the checked-out branch is
open on.`,
	Args: cobra.MaximumNArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		root, err := repoRoot()
		if err != nil {
			return err
		}

		number := 0
		if len(args) == 1 {
			if number, err = strconv.Atoi(args[0]); err != nil || number <= 0 {
				return fmt.Errorf("%s is not a pull request number", args[0])
			}
		} else if number, err = currentPR(root); err != nil {
			return err
		}

		headSha, err := prHeadSha(root, number)
		if err != nil {
			return err
		}

		store := comments.NewStore(root)
		doc, err := store.Load()
		if err != nil {
			return err
		}

		published, skipped, failed := 0, 0, 0
		for _, t := range doc.Threads {
			if t.PublishedURL != "" {
				skipped++
				continue
			}
			url, err := postThread(root, number, headSha, t)
			if err != nil {
				failed++
				logln("✗ %s %s:%d — %v", t.ID, t.File, t.Line, err)
				continue
			}
			if _, err := store.MarkPublished(t.ID, url); err != nil {
				return err
			}
			published++
			logln("✓ %s:%d → %s", t.File, t.Line, url)
		}
		logln("published %d, skipped %d already published, %d failed", published, skipped, failed)
		if failed > 0 {
			return fmt.Errorf("%d thread(s) failed", failed)
		}
		return nil
	},
}

func init() {
	rootCmd.AddCommand(publishCmd)
}

func currentPR(root string) (int, error) {
	out, err := ghAPI(root, "pr", "view", "--json", "number", "--jq", ".number")
	if err != nil {
		return 0, fmt.Errorf("no pull request for the current branch — name one: grasp publish N")
	}
	return strconv.Atoi(strings.TrimSpace(string(out)))
}

func prHeadSha(root string, number int) (string, error) {
	out, err := ghAPI(root, "pr", "view", fmt.Sprint(number), "--json", "headRefOid", "--jq", ".headRefOid")
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}

// postThread sends one thread as a PR review comment: on its line when the
// diff covers it, on the file otherwise (GitHub takes a line comment only
// inside the diff). Base-side threads carry a function-relative line, so they
// go on the file directly, with the anchor written at the top of the body.
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
		// The line is outside every hunk: fall back to a file-level comment.
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
	out, err := ghAPI(root, args...)
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

func ghAPI(root string, args ...string) ([]byte, error) {
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
