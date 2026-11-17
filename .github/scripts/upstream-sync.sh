#!/usr/bin/env bash
# Opens a PR that merges upstream Attendee into the fork when Codex judges the sync worthwhile.
#   prepare: starts `git merge --no-commit` and writes the Codex prompt. Sets output run=true|false.
#   finish:  reads the Codex decision, then commits, bumps the minor version, pushes and opens the PR.
# shellcheck disable=SC2153,SC2016 # LABEL, TARGET, BEHIND come from the sourced state file.
# Codex runs between the two with no GitHub token; only finish writes to GitHub, with SYNC_TOKEN
# (a PR opened with GITHUB_TOKEN would not trigger CI).
set -euo pipefail

UPSTREAM="${UPSTREAM:-attendee-labs/attendee}"
BASE="${BASE_BRANCH:-main}"
BRANCH_PREFIX="upstream-sync/"
TMP="${RUNNER_TEMP:?}"
PROMPT="$TMP/upstream-sync-prompt.md"
DECISION="$TMP/upstream-sync-decision.json"
STATE="$TMP/upstream-sync-state"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/stdout}"

prepare() {
  : "${SYNC_TOKEN:?UPSTREAM_SYNC_TOKEN secret is not set}"
  local ref="${SYNC_REF:-$BASE}"
  local open
  open=$(gh pr list -R "$GITHUB_REPOSITORY" --state open --json headRefName \
    --jq "[.[] | select(.headRefName | startswith(\"$BRANCH_PREFIX\"))][0].headRefName // \"\"")
  if [ -n "$open" ]; then
    echo "Upstream sync PR from $open is still open; not opening another." | tee -a "$SUMMARY"
    echo "run=false" >>"$GITHUB_OUTPUT"
    return
  fi

  git remote add upstream "https://github.com/$UPSTREAM.git"
  git fetch --no-tags upstream "$ref"
  local target behind label
  target=$(git rev-parse FETCH_HEAD)
  behind=$(git rev-list --count "HEAD..$target")
  if [ "$behind" -eq 0 ]; then
    echo "\`$BASE\` already contains $UPSTREAM $ref." | tee -a "$SUMMARY"
    echo "run=false" >>"$GITHUB_OUTPUT"
    return
  fi
  case "$ref" in
    "$BASE") label="$BASE@${target:0:7}" ;;
    pull/*/head) label="PR #$(cut -d/ -f2 <<<"$ref")" ;;
    *) label="$ref" ;;
  esac

  git config user.name "github-actions[bot]"
  git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
  git merge --no-ff --no-commit "$target" >/dev/null 2>&1 || true
  git rev-parse -q --verify MERGE_HEAD >/dev/null || { echo "git merge did not start" >&2; exit 1; }
  # version.json stays on the fork's own line; finish bumps it.
  git checkout HEAD -- version.json
  git diff --name-only --diff-filter=U >"$TMP/upstream-sync-conflicts.txt"

  printf 'TARGET=%s\nLABEL=%q\nBEHIND=%s\n' "$target" "$label" "$behind" >"$STATE"
  {
    cat .github/codex/upstream-sync-prompt.md
    echo
    echo "## Context"
    echo "Merging $UPSTREAM $label ($target). \`$BASE\` is $behind commits behind it."
    echo
    echo "### Files with conflicts"
    if [ -s "$TMP/upstream-sync-conflicts.txt" ]; then sed 's/^/- /' "$TMP/upstream-sync-conflicts.txt"; else echo "None."; fi
    echo
    echo "### Upstream commits (newest first, up to 300)"
    git log --no-merges --format='- %h %s' "HEAD..$target" | head -300
    echo
    echo "### Files upstream changed (up to 300)"
    git diff --stat=200 "HEAD...$target" | tail -300
  } >"$PROMPT"
  echo "run=true" >>"$GITHUB_OUTPUT"
}

finish() {
  : "${SYNC_TOKEN:?UPSTREAM_SYNC_TOKEN secret is not set}"
  # shellcheck disable=SC1090
  source "$STATE"
  jq -e 'has("sync") and has("reason")' "$DECISION" >/dev/null || { echo "Codex gave no valid decision" >&2; exit 1; }
  if [ "$(jq -r .sync "$DECISION")" != "true" ]; then
    git merge --abort
    { echo "### No sync PR for $UPSTREAM $LABEL"; jq -r .reason "$DECISION"; } >>"$SUMMARY"
    return
  fi

  # Only tracked files: anything new that Codex wrote is left out.
  git add -u
  if [ -n "$(git diff --name-only --diff-filter=U)" ]; then
    echo "Conflicts remain after Codex: $(git diff --name-only --diff-filter=U | paste -sd' ' -)" >&2
    exit 1
  fi
  if [ -s "$TMP/upstream-sync-conflicts.txt" ] &&
    xargs grep -lE '^(<<<<<<<|>>>>>>>)( |$)' <"$TMP/upstream-sync-conflicts.txt" 2>/dev/null; then
    echo "Conflict markers remain in the files above" >&2
    exit 1
  fi

  local version
  version=$(jq -r .version version.json | awk -F. '{ printf "%d.%d.0", $1, $2 + 1 }')
  jq --arg v "$version" '.version = $v' version.json >"$TMP/version.json" && mv "$TMP/version.json" version.json
  git add version.json

  local title="feat: sync fork with upstream attendee $LABEL"
  git commit -q -m "$title" -m "Merges $UPSTREAM $LABEL ($TARGET), $BEHIND commits. Opened by the upstream-check workflow; Codex resolved the merge."
  local branch="$BRANCH_PREFIX${TARGET:0:7}"
  git push -q "https://x-access-token:${SYNC_TOKEN}@github.com/${GITHUB_REPOSITORY}.git" "HEAD:refs/heads/$branch"

  {
    echo "Merges $UPSTREAM $LABEL into the fork ($BEHIND commits). Opened by the upstream-check workflow. Codex resolved the merge and wrote the notes below; check them."
    echo
    echo "**Why sync:** $(jq -r .reason "$DECISION")"
    echo
    jq -r .summary "$DECISION"
    echo
    echo "### Check before you merge"
    jq -r '.risks[] | "- " + .' "$DECISION"
    echo
    echo "**meeting overlay imports:** $(jq -r .overlay_check "$DECISION")"
    echo
    echo "### Conflicts Codex resolved"
    if [ -s "$TMP/upstream-sync-conflicts.txt" ]; then sed 's/^/- `/; s/$/`/' "$TMP/upstream-sync-conflicts.txt"; else echo "None."; fi
    echo
    echo "**Merge with a merge commit, not squash**, so the next sync has a real merge-base."
    echo
    echo "Rollout: publish \`attendee-base\` for QA at the new tag, deploy QA, check that a Meet bot records, then prod."
  } >"$TMP/upstream-sync-body.md"
  GH_TOKEN="$SYNC_TOKEN" gh pr create -R "$GITHUB_REPOSITORY" --base "$BASE" --head "$branch" \
    --title "$title" --body-file "$TMP/upstream-sync-body.md" | tee -a "$SUMMARY"
}

case "${1:-}" in
  prepare) prepare ;;
  finish) finish ;;
  *) echo "usage: $0 prepare|finish" >&2; exit 2 ;;
esac
