package cli

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"time"

	"github.com/spf13/cobra"

	"github.com/eltoncampos1/grasp-cli/internal/agent"
	"github.com/eltoncampos1/grasp-cli/internal/config"
	"github.com/eltoncampos1/grasp-cli/internal/indexer"
)

var (
	webBase    string
	webPort    int
	webNoOpen  bool
	webNoIndex bool
)

// v0: the viewer is borrowed from upstream grasp (`mix grasp.viewer`), run
// out of a checkout named by viewer.grasp_checkout. v1 embeds a viewer of its
// own and this command stops needing Elixir on the machine.
var webCmd = &cobra.Command{
	Use:   "web",
	Short: "Index the current branch and serve the review canvas",
	Long: `Indexes the working tree against the base branch and serves the viewer,
opening the browser unless --no-open. After grasp pr, use --no-index so the
index keeps pointing at the pull request's worktree.

v0 serves the canvas through upstream grasp's standalone viewer: set
viewer.grasp_checkout in .grasp/config.toml to a checkout of
https://github.com/gfrancischelli/grasp (requires Elixir 1.19+).`,
	RunE: func(cmd *cobra.Command, args []string) error {
		root, err := repoRoot()
		if err != nil {
			return err
		}
		cfg, err := config.Load(root)
		if err != nil {
			return err
		}

		if !webNoIndex {
			base, err := resolveBase(root, webBase)
			if err != nil {
				return err
			}
			if _, err := indexer.Build(indexer.Options{
				Root:    root,
				BaseRef: base,
				Log:     func(s string) { logln("%s", s) },
			}); err != nil {
				return err
			}
		}

		indexPath := filepath.Join(root, ".grasp", "index.json")
		if _, err := os.Stat(indexPath); err != nil {
			return fmt.Errorf("no index at %s — run grasp index first", indexPath)
		}

		if cfg.Viewer.GraspCheckout == "" {
			logln("index ready: %s", indexPath)
			logln("no viewer configured yet (v0 borrows upstream grasp's):")
			logln("  git clone https://github.com/gfrancischelli/grasp ~/dev/grasp")
			logln("  # then in .grasp/config.toml:  [viewer] grasp_checkout = \"~/dev/grasp/grasp\"")
			return nil
		}

		checkout := agent.ExpandPath(cfg.Viewer.GraspCheckout)
		if _, err := os.Stat(filepath.Join(checkout, "mix.exs")); err != nil {
			return fmt.Errorf("viewer.grasp_checkout %s has no mix.exs", checkout)
		}

		port := cfg.Web.Port
		if webPort != 0 {
			port = webPort
		}

		viewer := exec.Command("mix", "grasp.viewer", "--index", indexPath, "--port", fmt.Sprint(port))
		if cfg.Web.Editor != "" {
			viewer.Args = append(viewer.Args, "--editor", cfg.Web.Editor)
		}
		if cfg.Agent.Command != "" {
			viewer.Args = append(viewer.Args, "--agent-command", cfg.Agent.Command)
		}
		if cfg.Agent.Model != "" {
			viewer.Args = append(viewer.Args, "--agent-model", cfg.Agent.Model)
		}
		viewer.Dir = checkout
		viewer.Env = agent.Env(cfg.Agent) // the profile reaches the chat panel's spawns
		viewer.Stdout = os.Stdout
		viewer.Stderr = os.Stderr

		url := fmt.Sprintf("http://127.0.0.1:%d", port)
		if cfg.Web.Open && !webNoOpen {
			go func() {
				time.Sleep(4 * time.Second)
				_ = exec.Command("open", url).Run()
			}()
		}
		logln("serving %s (viewer: upstream grasp at %s)", url, checkout)
		return viewer.Run()
	},
}

func init() {
	webCmd.Flags().StringVar(&webBase, "base", "", "ref to review against (default: config, then origin/HEAD)")
	webCmd.Flags().IntVar(&webPort, "port", 0, "viewer port (default: config, then 4040)")
	webCmd.Flags().BoolVar(&webNoOpen, "no-open", false, "do not open the browser")
	webCmd.Flags().BoolVar(&webNoIndex, "no-index", false, "serve the index already on disk (e.g. a PR's)")
	rootCmd.AddCommand(webCmd)
}
