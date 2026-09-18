#!/bin/sh
# Stands in for the GitHub CLI in tests: answers the handful of `gh` calls the publisher
# makes with canned JSON about pull 42 of acme/sample_app, so the suite never reaches the
# network. Pull 99 answers a different head sha, for the head-mismatch warning, and pull
# 404 fails the way gh fails on a branch with no pull request. A `pr view` asking for the
# branch fields answers pull 7, whose feature branch is open against main, for the worktree
# recipe. An `api` call whose argv
# carries GHFAIL answers GitHub's validation error. With FAKE_GH_LOG set it appends each
# argv as one line to that file, so a test can read back the flags it was called with.
if [ -n "$FAKE_GH_LOG" ]; then
  printf '%s\n' "$*" >> "$FAKE_GH_LOG"
fi

args="$*"

case "$1 $2" in
  "pr view")
    number=$3
    case "$args" in
      *baseRefName,headRefName*)
        case "$number" in
          404)
            echo 'no pull requests found for branch "review/publish"' 1>&2
            exit 1
            ;;
        esac

        printf '{"baseRefName":"main","headRefName":"feature","title":"Add greeting","url":"https://github.com/acme/sample_app/pull/%s"}\n' \
          "$number"
        exit 0
        ;;
    esac

    case "$number" in
      ""|-*) number=42 ;;
      404)
        echo 'no pull requests found for branch "review/publish"' 1>&2
        exit 1
        ;;
    esac

    case "$number" in
      99) head=9999999 ;;
      *) head=0000000 ;;
    esac

    printf '{"number":%s,"url":"https://github.com/acme/sample_app/pull/%s","headRefOid":"%s","baseRefName":"main"}\n' \
      "$number" "$number" "$head"
    exit 0
    ;;
  "pr diff")
    cat <<'DIFF'
diff --git a/lib/sample_app/greeter.ex b/lib/sample_app/greeter.ex
index 1111111..2222222 100644
--- a/lib/sample_app/greeter.ex
+++ b/lib/sample_app/greeter.ex
@@ -1,6 +1,8 @@
 defmodule SampleApp.Greeter do
   @moduledoc false
   def farewell(name), do: "Bye, " <> name
+  def greet(name), do: "Hello, " <> name
+  def shout(name), do: String.upcase(name)
   def plain(name), do: name
   def other(name), do: name
 end
diff --git a/lib/sample_app/formatter.ex b/lib/sample_app/formatter.ex
index 3333333..4444444 100644
--- a/lib/sample_app/formatter.ex
+++ b/lib/sample_app/formatter.ex
@@ -10,3 +10,4 @@ defmodule SampleApp.Formatter do
   def shout(text), do: String.upcase(text)
+  def whisper(text), do: String.downcase(text)
   def plain(text), do: text
 end
DIFF
    exit 0
    ;;
esac

if [ "$1" = "api" ]; then
  case "$args" in
    *GHFAIL*)
      echo 'HTTP 422: Validation Failed (https://docs.github.com/rest)' 1>&2
      exit 1
      ;;
  esac

  endpoint=
  for arg in "$@"; do
    case "$arg" in
      repos/*/pulls/*) endpoint=$arg ;;
    esac
  done

  case "$endpoint" in
    */comments|*/comments/*/replies)
      number=$(printf '%s' "$endpoint" | sed 's|.*/pulls/||; s|/.*||')
      printf '{"id":%s,"html_url":"https://github.com/acme/sample_app/pull/%s#discussion_r%s"}\n' \
        "$$" "$number" "$$"
      exit 0
      ;;
  esac
fi

echo 'fake gh: unexpected arguments' 1>&2
exit 2
