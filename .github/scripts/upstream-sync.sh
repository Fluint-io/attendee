#!/usr/bin/env bash
# Opens a PR that merges upstream Attendee into the fork when Codex judges the sync worthwhile.
#   prepare: (sync job) starts `git merge --no-commit` and writes the Codex prompt. Output run=true|false.
#   package: (sync job, no secrets) commits Codex's result as a git bundle. Output publish=true|false.
#   publish: (publish job) checks the bundle and opens the PR with SYNC_TOKEN.
# Codex can edit any file in the sync job's checkout, so that job holds no GitHub secret. Only publish
# holds a write token; it runs from a fresh checkout of main and treats the bundle and notes as data.
set -euo pipefail

UPSTREAM="${UPSTREAM:-attendee-labs/attendee}"
BASE="${BASE_BRANCH:-main}"
REF="${SYNC_REF:-$BASE}"
BRANCH_PREFIX="upstream-sync/"
TMP="${RUNNER_TEMP:?}"
OUT="$TMP/upstream-sync" # passed from the sync job to the publish job as an artifact
PROMPT="$TMP/upstream-sync-prompt.md"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/stdout}"
RESULT_REF="refs/heads/upstream-sync-result"
MARKERS='^(<<<<<<<|>>>>>>>)( |$)'

fail() { echo "$*" >&2; exit 1; }
fetch_upstream() {
  git remote get-url upstream >/dev/null 2>&1 || git remote add upstream "https://github.com/$UPSTREAM.git"
  git fetch -q --no-tags upstream "$REF"
  git rev-parse FETCH_HEAD
}
label_for() {
  case "$REF" in
    "$BASE") echo "$BASE@${1:0:7}" ;;
    pull/*/head) echo "PR #$(cut -d/ -f2 <<<"$REF")" ;;
    *) echo "$REF" ;;
  esac
}
minor_bump() { jq -r .version | awk -F. '{ printf "%d.%d.0", $1, $2 + 1 }'; }
# The PR branch runs its own workflows with repository secrets before anyone reviews it, so .github
# always stays as on main. Upstream .github changes are listed in the PR for a person to port.
keep_base_github() { git restore --source=HEAD --staged --worktree -- .github; }

prepare() {
  mkdir -p "$OUT"
  local open
  open=$(gh api --paginate "repos/$GITHUB_REPOSITORY/pulls?state=open&per_page=100" \
    --jq ".[].head.ref | select(startswith(\"$BRANCH_PREFIX\"))")
  open=${open%%$'\n'*}
  if [ -n "$open" ]; then
    echo "Upstream sync PR from $open is still open; not opening another." | tee -a "$SUMMARY"
    echo "run=false" >>"$GITHUB_OUTPUT"
    return
  fi

  local target behind
  target=$(fetch_upstream)
  behind=$(git rev-list --count "HEAD..$target")
  if [ "$behind" -eq 0 ]; then
    echo "\`$BASE\` already contains $UPSTREAM $REF." | tee -a "$SUMMARY"
    echo "run=false" >>"$GITHUB_OUTPUT"
    return
  fi

  git config user.name "github-actions[bot]"
  git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
  git merge --no-ff --no-commit "$target" >/dev/null 2>&1 || true
  git rev-parse -q --verify MERGE_HEAD >/dev/null || fail "git merge did not start"
  # version.json stays on the fork's own line; package bumps it.
  git checkout HEAD -- version.json
  git diff --name-only "HEAD...$target" -- .github >"$OUT/dropped-github.txt"
  keep_base_github
  git diff --name-only --diff-filter=U >"$OUT/conflicts.txt"

  {
    cat .github/codex/upstream-sync-prompt.md
    echo
    echo "## Context"
    echo "Merging $UPSTREAM $(label_for "$target") ($target). \`$BASE\` is $behind commits behind it."
    echo
    echo "### Files with conflicts"
    if [ -s "$OUT/conflicts.txt" ]; then sed 's/^/- /' "$OUT/conflicts.txt"; else echo "None."; fi
    echo
    echo "### Upstream commits (newest first, up to 300)"
    git log --no-merges --max-count=300 --format='- %h %s' "HEAD..$target"
    echo
    echo "### Files upstream changed (up to 300)"
    git diff --stat=200 "HEAD...$target" | tail -300
  } >"$PROMPT"
  echo "run=true" >>"$GITHUB_OUTPUT"
}

package() {
  local decision="$OUT/decision.json"
  jq -e '.sync | type == "boolean"' "$decision" >/dev/null 2>&1 || fail "Codex gave no valid decision"
  if [ "$(jq -r .sync "$decision")" != "true" ]; then
    git merge --abort
    { echo "### No upstream sync PR"; jq -r .reason "$decision"; } >>"$SUMMARY"
    echo "publish=false" >>"$GITHUB_OUTPUT"
    return
  fi

  # Only tracked files: anything new that Codex wrote is left out.
  git add -u
  keep_base_github
  local unmerged
  unmerged=$(git diff --name-only --diff-filter=U)
  [ -z "$unmerged" ] || fail "Conflicts remain after Codex: $(paste -sd' ' - <<<"$unmerged")"
  local version
  version=$(git show HEAD:version.json | minor_bump)
  jq --arg v "$version" '.version = $v' version.json >"$TMP/version.json"
  mv "$TMP/version.json" version.json
  git add version.json
  git commit -q --no-verify -m "feat: sync fork with upstream attendee $(label_for "$(git rev-parse MERGE_HEAD)")"
  git update-ref "$RESULT_REF" HEAD
  git bundle create -q "$OUT/sync.bundle" "$RESULT_REF" "^HEAD^1"
  echo "publish=true" >>"$GITHUB_OUTPUT"
}

publish() {
  : "${SYNC_TOKEN:?UPSTREAM_SYNC_TOKEN secret is not set}"
  local base result parents p1 p2 extra target
  base=$(git rev-parse HEAD)
  git bundle verify -q "$OUT/sync.bundle" >/dev/null || fail "Invalid sync bundle"
  git fetch -q "$OUT/sync.bundle" "$RESULT_REF:refs/sync/result"
  result=$(git rev-parse refs/sync/result)
  parents=$(git rev-list --parents -n1 "$result")
  read -r _ p1 p2 extra <<<"$parents"
  [ "$p1" = "$base" ] && [ -n "${p2:-}" ] && [ -z "${extra:-}" ] ||
    fail "The sync result is not a two-parent merge onto the current $BASE ($base)"
  target=$(fetch_upstream)
  git merge-base --is-ancestor "$p2" "$target" || fail "The merged commit $p2 is not in upstream $REF"

  git diff --quiet "$base" "$result" -- .github || fail "The sync result changes .github"

  local changed=() hits rc=0
  mapfile -d '' -t changed < <(git diff -z --name-only --diff-filter=d "$base" "$result")
  if [ ${#changed[@]} -gt 0 ]; then
    hits=$(git grep -lE "$MARKERS" "$result" -- "${changed[@]}") || rc=$?
    [ "$rc" -eq 1 ] || fail "Conflict markers remain, or the scan failed (exit $rc): ${hits:-}"
  fi

  local want got
  want=$(git show "$base:version.json" | minor_bump)
  got=$(git show "$result:version.json" | jq -r .version)
  [ "$got" = "$want" ] || fail "version.json is $got; expected $want"

  local label behind branch title decision="$OUT/decision.json" body="$TMP/upstream-sync-body.md"
  label=$(label_for "$p2")
  behind=$(git rev-list --count "$base..$p2")
  branch="$BRANCH_PREFIX${p2:0:7}-${GITHUB_RUN_ID:?}-${GITHUB_RUN_ATTEMPT:-1}"
  title="feat: sync fork with upstream attendee $label"
  git push -q "https://x-access-token:${SYNC_TOKEN}@github.com/${GITHUB_REPOSITORY}.git" "$result:refs/heads/$branch"

  {
    echo "Merges $UPSTREAM $label into the fork ($behind commits). Opened by the upstream-check workflow. Codex resolved the merge and wrote the notes below; check them."
    echo
    echo "**Why sync:** $(jq -r .reason "$decision")"
    echo
    jq -r .summary "$decision"
    echo
    echo "### Check before you merge"
    jq -r '.risks[]? | "- " + .' "$decision"
    echo
    echo "**meeting overlay imports:** $(jq -r .overlay_check "$decision")"
    echo
    echo "### Conflicts Codex resolved"
    if grep -qE '^[A-Za-z0-9._/@+-]+$' "$OUT/conflicts.txt" 2>/dev/null; then
      # shellcheck disable=SC2016 # literal backticks
      grep -E '^[A-Za-z0-9._/@+-]+$' "$OUT/conflicts.txt" | sed 's/^/- `/; s/$/`/'
    else
      echo "None."
    fi
    echo
    echo "### Upstream \`.github\` changes left out"
    echo "The sync never changes \`.github\`, because this branch runs its workflows before review. Port these by hand if they matter:"
    if grep -qE '^[A-Za-z0-9._/@+-]+$' "$OUT/dropped-github.txt" 2>/dev/null; then
      # shellcheck disable=SC2016 # literal backticks
      grep -E '^[A-Za-z0-9._/@+-]+$' "$OUT/dropped-github.txt" | sed 's/^/- `/; s/$/`/'
    else
      echo "None."
    fi
    echo
    echo "**Merge with a merge commit, not squash**, so the next sync has a real merge-base."
    echo
    echo "Rollout: publish \`attendee-base\` for QA at the new tag, deploy QA, check that a Meet bot records, then prod."
  } >"$body"
  GH_TOKEN="$SYNC_TOKEN" gh pr create -R "$GITHUB_REPOSITORY" --base "$BASE" --head "$branch" \
    --title "$title" --body-file "$body" | tee -a "$SUMMARY"
}

case "${1:-}" in
  prepare) prepare ;;
  package) package ;;
  publish) publish ;;
  *) echo "usage: $0 prepare|package|publish" >&2; exit 2 ;;
esac
