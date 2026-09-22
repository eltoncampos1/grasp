package cli

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"

	"github.com/spf13/cobra"

	"github.com/eltoncampos1/grasp-cli/internal/comments"
	"github.com/eltoncampos1/grasp-cli/internal/config"
	"github.com/eltoncampos1/grasp-cli/internal/gitx"
	"github.com/eltoncampos1/grasp-cli/internal/indexer"
	"github.com/eltoncampos1/grasp-cli/internal/webserver"
)

var (
	webBase    string
	webPort    int
	webNoOpen  bool
	webNoIndex bool
)

var webCmd = &cobra.Command{
	Use:   "web",
	Short: "Index the current branch and serve the review canvas",
	Long: `Indexes the working tree against the base branch and serves the embedded
viewer on 127.0.0.1, opening the browser unless --no-open. The canvas redraws
live whenever .grasp/index.json is rewritten — by grasp index, or by grasp pr
pointing it at a pull request's worktree (use --no-index then, so the PR's
index is served untouched).

Comment threads land in .grasp/comments.json under this checkout and survive
a worktree's --close; grasp publish sends them to the pull request.`,
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

		port := cfg.Web.Port
		if webPort != 0 {
			port = webPort
		}
		author, _ := gitx.Run(root, "config", "user.name")

		server := &webserver.Server{
			IndexPath: indexPath,
			Port:      port,
			Editor:    cfg.Web.Editor,
			Author:    author,
			Comments:  comments.NewStore(root),
		}
		return server.Run(func(url string) {
			logln("grasp: %s  (index: %s)", url, indexPath)
			if cfg.Web.Open && !webNoOpen {
				_ = exec.Command("open", url).Start()
			}
		})
	},
}

func init() {
	webCmd.Flags().StringVar(&webBase, "base", "", "ref to review against (default: config, then origin/HEAD)")
	webCmd.Flags().IntVar(&webPort, "port", 0, "viewer port (default: config, then 4040)")
	webCmd.Flags().BoolVar(&webNoOpen, "no-open", false, "do not open the browser")
	webCmd.Flags().BoolVar(&webNoIndex, "no-index", false, "serve the index already on disk (e.g. a PR's)")
	rootCmd.AddCommand(webCmd)
}
