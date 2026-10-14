#!/usr/bin/env bash
# review-context.sh - read-only facts for the go-code-review skill.
#
# Usage: review-context.sh [target]        (default: main)
#   target: a branch name (main), a remote-tracking ref (origin/main),
#           or a full ref (refs/heads/main).
#
# Run from anywhere inside the repository. Prints key=value lines and a few
# <name>_begin / <name>_end blocks. Ends with status=ok (exit 0) or
# status=stop plus stop_reason (exit 2).
#
# Never fetches, checks out, writes files, or changes refs, index or config.
# Compatible with macOS /bin/bash 3.2.

set -euo pipefail
export GIT_OPTIONAL_LOCKS=0 GIT_PAGER=cat LC_ALL=C

target="${1:-main}"

emit() { printf '%s=%s\n' "$1" "$2"; }
stop() { emit status stop; emit stop_reason "$1"; exit 2; }
resolve() { git rev-parse --verify -q "$1^{commit}" 2>/dev/null; }

# file_mtime_iso <path>: UTC ISO-8601 mtime, or "unknown".
file_mtime_iso() {
  local f="$1" epoch
  if [ ! -e "$f" ]; then echo unknown; return; fi
  epoch=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || true)
  case "$epoch" in ''|*[!0-9]*) echo unknown; return ;; esac
  date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || echo unknown
}

# dir_of: reads paths on stdin, prints each path's directory ("." for root files).
dir_of() { awk '{ n = split($0, a, "/"); if (n == 1) { print "."; next } d = a[1]; for (i = 2; i < n; i++) d = d "/" a[i]; print d }'; }

root=$(git rev-parse --show-toplevel 2>/dev/null) || stop "not inside a git work tree"
cd "$root"

emit generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
emit repo_root "$root"

# Repository slug from the origin URL (credentials stripped), else the folder name.
origin_url=$(git remote get-url origin 2>/dev/null || true)
if [ -n "$origin_url" ]; then
  slug=$(printf '%s\n' "$origin_url" | sed -E 's#^[A-Za-z][A-Za-z0-9+.-]*://##; s#^[^@/]*@##; s#^([^/:]+):#\1/#; s#\.git$##; s#/+$##')
else
  slug=$(basename "$root")
fi
slug=$(printf '%s\n' "$slug" | sed -E 's#[^A-Za-z0-9._/-]#_#g; s#\.\.+#_#g; s#^/+##')
emit repo_slug "$slug"

# --- HEAD -------------------------------------------------------------------
head_sha=$(resolve HEAD) || stop "HEAD does not point to a commit (empty repository?)"
branch=$(git symbolic-ref --short -q HEAD || echo DETACHED)
emit branch "$branch"
emit head_sha "$head_sha"
emit head_subject "$(git log -1 --format=%s HEAD)"
if [ "$(git rev-parse --is-shallow-repository)" = true ]; then shallow=true; else shallow=false; fi
emit shallow_clone "$shallow"

# --- Target -----------------------------------------------------------------
emit target_input "$target"
target_ref=""
target_note=""
case "$target" in
  refs/*)
    resolve "$target" >/dev/null || stop "target ref $target does not exist locally"
    target_ref="$target"
    target_note="explicit full ref"
    ;;
  *)
    if [ "${target#*/}" != "$target" ] && git show-ref --verify -q "refs/remotes/$target"; then
      target_ref="refs/remotes/$target"
      target_note="explicit remote-tracking ref"
    else
      local_ok=false
      if git show-ref --verify -q "refs/heads/$target"; then local_ok=true; fi
      remote_ref=""
      for r in $(git remote); do
        if git show-ref --verify -q "refs/remotes/$r/$target"; then
          if [ -z "$remote_ref" ] || [ "$r" = origin ]; then remote_ref="refs/remotes/$r/$target"; fi
        fi
      done

      if $local_ok && [ -n "$remote_ref" ]; then
        l=$(resolve "refs/heads/$target")
        r=$(resolve "$remote_ref")
        if [ "$l" = "$r" ]; then
          target_ref="$remote_ref"
          target_note="refs/heads/$target is identical to $remote_ref"
        elif git merge-base --is-ancestor "$l" "$r"; then
          target_ref="$remote_ref"
          target_note="refs/heads/$target is $(git rev-list --count "$l..$r") commit(s) behind $remote_ref; using $remote_ref"
        else
          counts=$(git rev-list --left-right --count "$l...$r" | tr '\t' ' ')
          emit target_local "refs/heads/$target $l"
          emit target_remote "$remote_ref $r"
          emit target_local_ahead_behind "$counts"
          stop "ambiguous target: refs/heads/$target has commits that $remote_ref does not (local ahead/behind: $counts). Re-run with an explicit target: refs/heads/$target or ${remote_ref#refs/remotes/}"
        fi
      elif $local_ok; then
        target_ref="refs/heads/$target"
        target_note="local branch only (no remote-tracking ref)"
      elif [ -n "$remote_ref" ]; then
        target_ref="$remote_ref"
        target_note="remote-tracking ref only (no local branch)"
      else
        default=$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)
        hint=""
        if [ -n "$default" ]; then hint="; the origin default branch is $default"; fi
        stop "target '$target' not found locally (no refs/heads/$target or refs/remotes/*/$target)$hint"
      fi
    fi
    ;;
esac
target_sha=$(resolve "$target_ref")
emit target_ref "$target_ref"
emit target_sha "$target_sha"
emit target_note "$target_note"
emit last_fetch "$(file_mtime_iso "$(git rev-parse --git-path FETCH_HEAD)")"

# --- Merge base -------------------------------------------------------------
if ! mb=$(git merge-base HEAD "$target_ref"); then
  if [ "$shallow" = true ]; then
    stop "no merge base between HEAD and $target_ref; this is a shallow clone, so history may be truncated"
  fi
  stop "no merge base between HEAD and $target_ref (unrelated histories)"
fi
emit merge_base "$mb"
emit merge_base_count "$(git merge-base --all HEAD "$target_ref" | wc -l | tr -d ' ')"
if [ "$mb" = "$head_sha" ]; then
  stop "HEAD is already contained in $target_ref; the branch introduces no commits to review"
fi

ahead=$(git rev-list --count "$mb..HEAD")
emit commits_in_branch "$ahead"
emit commits_on_target_not_in_branch "$(git rev-list --count "HEAD..$target_ref")"
emit merge_commits_in_branch "$(git rev-list --merges --count "$mb..HEAD")"
emit diff_shortstat "$(git diff --shortstat -M "$mb" HEAD | sed 's/^ *//')"

stats=$(git diff --numstat -M "$mb" HEAD | awk '{ n++; if ($1 ~ /^[0-9]+$/) c += $1; if ($2 ~ /^[0-9]+$/) c += $2 } END { print n + 0, c + 0 }')
nfiles=${stats% *}
nlines=${stats#* }
if [ "$nfiles" -gt 80 ] || [ "$nlines" -gt 3000 ]; then size=large; else size=normal; fi
emit size_warning "$size"

echo "commits_begin"
git log -n 100 --no-decorate --date=short --format='%h %ad %s' "$mb..HEAD"
if [ "$ahead" -gt 100 ]; then echo "... $((ahead - 100)) more"; fi
echo "commits_end"

echo "changed_files_begin"
git diff --name-status -M "$mb" HEAD | awk 'NR <= 400 { print } END { if (NR > 400) printf "... %d more\n", NR - 400 }'
echo "changed_files_end"

echo "changed_areas_begin"
git diff --name-only -M "$mb" HEAD \
  | awk -F/ '{ if (NF > 2) k = $1 "/" $2; else if (NF == 2) k = $1; else k = "(root)"; c[k]++ } END { for (k in c) printf "%5d %s\n", c[k], k }' \
  | sort -rn | awk 'NR <= 40'
echo "changed_areas_end"

# Generated Go files (standard "Code generated ... DO NOT EDIT." header) and vendored files.
emit vendored_files_changed "$(git diff --name-only -M "$mb" HEAD | awk '("/" $0) ~ /\/vendor\// { n++ } END { print n + 0 }')"
echo "generated_files_begin"
git diff --name-only --diff-filter=AMR -M "$mb" HEAD | while IFS= read -r f; do
  case "$f" in vendor/* | */vendor/*) continue ;; *.go) ;; *) continue ;; esac
  if git show "HEAD:$f" 2>/dev/null | awk 'NR <= 30 && /^\/\/ Code generated .* DO NOT EDIT\.$/ { found = 1 } END { exit !found }'; then
    echo "$f"
  fi
done | awk 'NR <= 300'
echo "generated_files_end"

# --- Working tree -----------------------------------------------------------
status_out=$(git status --porcelain=v1 --untracked-files=normal)
if [ -n "$status_out" ]; then
  emit worktree_dirty true
  emit worktree_changed_paths "$(printf '%s\n' "$status_out" | wc -l | tr -d ' ')"
  echo "worktree_status_begin"
  printf '%s\n' "$status_out" | awk 'NR <= 50'
  echo "worktree_status_end"
else
  emit worktree_dirty false
fi

# --- Go module and tooling --------------------------------------------------
emit go_mod_files "$(git ls-files -- ':(glob)**/go.mod' | awk 'NR <= 30' | tr '\n' ' ' | sed 's/ $//')"
if [ -f go.mod ]; then
  emit module_path "$(awk '$1 == "module" { print $2; exit }' go.mod)"
  emit go_directive "$(awk '$1 == "go" { print $2; exit }' go.mod)"
  emit toolchain_directive "$(awk '$1 == "toolchain" { print $2; exit }' go.mod)"
fi
if [ -d vendor ]; then emit vendor_dir true; else emit vendor_dir false; fi
if command -v go >/dev/null 2>&1; then
  # Run outside the module with GOTOOLCHAIN=local so no toolchain is downloaded.
  emit local_go "$(cd / && GOTOOLCHAIN=local go version 2>/dev/null || echo unknown)"
else
  emit local_go "not installed"
fi

# git ls-files matches names case-sensitively (unlike [ -e ] on macOS filesystems).
emit tooling_files "$(git ls-files -- Makefile makefile GNUmakefile Justfile justfile .justfile Taskfile.yml Taskfile.yaml magefile.go \
  .golangci.yml .golangci.yaml .golangci.toml .golangci.json buf.yaml buf.work.yaml .goreleaser.yml .goreleaser.yaml | tr '\n' ' ' | sed 's/ $//')"
emit ci_files "$(git ls-files -- '.github/workflows/*' .gitlab-ci.yml .circleci/config.yml Jenkinsfile '.buildkite/*' azure-pipelines.yml bitbucket-pipelines.yml | tr '\n' ' ' | sed 's/ $//')"

echo "instruction_files_begin"
find . \( -name .git -o -name vendor -o -name node_modules -o -name testdata -o -path ./.claude/worktrees \) -prune -o \
  -type f \( -name AGENTS.md -o -name CLAUDE.md -o -name CLAUDE.local.md -o -name CONTRIBUTING.md \) -print 2>/dev/null \
  | sed 's#^\./##' | sort | awk 'NR <= 60'
echo "instruction_files_end"

echo "changed_dirs_with_instructions_begin"
# Parent folders of changed files that contain AGENTS.md / CLAUDE.md.
git diff --name-only -M "$mb" HEAD | dir_of | sort -u | while IFS= read -r d; do
  while :; do
    for n in AGENTS.md CLAUDE.md; do
      if [ "$d" != "." ] && [ -f "$d/$n" ]; then echo "$d/$n"; fi
    done
    case "$d" in */*) d=${d%/*} ;; *) break ;; esac
  done
done | sort -u | awk 'NR <= 60'
echo "changed_dirs_with_instructions_end"

emit evidence_dir "$HOME/.claude/release-evidence/$slug/$(printf '%.12s' "$head_sha")"
emit status ok
