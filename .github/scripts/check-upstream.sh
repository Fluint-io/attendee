#!/usr/bin/env bash
# Warns when upstream Attendee has releases this fork's default branch lacks, merged PRs, or new open PRs.
# An item is new when it falls between the last successful scheduled-style run's start and this run's
# start, so each item alerts once. Slack when SLACK_WEBHOOK_URL is set; the job summary always.
# SINCE_OVERRIDE re-reports from a given time without Slack; such runs are titled "(backfill)" and
# never become the baseline.
set -euo pipefail

UPSTREAM="${UPSTREAM:-attendee-labs/attendee}"
FORK="${GITHUB_REPOSITORY:?}"
BASE="${BASE_BRANCH:-main}"
WORKFLOW="${WORKFLOW_FILE:-upstream-check.yml}"
FIRST_RUN_LOOKBACK_DAYS=7
MAX_COMMITS=40
MAX_OTHER_PRS=10
MAX_SLACK_RELEASES=5
PRIORITY_PATHS='^bots/[a-z_]+adapter(/|\.py$)|(^|/)Dockerfile[^/]*$|chrom'
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/stdout}"
upstream_owner="${UPSTREAM%%/*}"
upstream_name="${UPSTREAM##*/}"

compare() { gh api "repos/$FORK/compare/$BASE...$upstream_owner:$upstream_name:$1"; }
slack_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

if [ -n "${GITHUB_RUN_ID:-}" ]; then
  until_ts=$(gh api "repos/$FORK/actions/runs/$GITHUB_RUN_ID" --jq '.created_at')
else
  until_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
fi
# The workflow is unknown (404) until it exists on the default branch; that counts as a first run.
if [ -n "${SINCE_OVERRIDE:-}" ]; then
  since="$SINCE_OVERRIDE"
elif ! since=$(gh api "repos/$FORK/actions/workflows/$WORKFLOW/runs?status=success&per_page=50" \
  --jq '[.workflow_runs[] | select(.display_title | contains("(backfill)") | not)][0].created_at // ""' 2>/tmp/runs.err); then
  grep -q 'HTTP 404' /tmp/runs.err || { cat /tmp/runs.err >&2; exit 1; }
  since=""
fi
if [ -z "$since" ]; then
  since=$(date -u -d "-$FIRST_RUN_LOOKBACK_DAYS days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
    date -u -v-"$FIRST_RUN_LOOKBACK_DAYS"d +%Y-%m-%dT%H:%M:%SZ)
fi
is_new() { [[ "$1" > "$since" && ! "$1" > "$until_ts" ]]; }
echo "Reporting items created after $since and up to $until_ts."

slack=""

# Releases the fork lacks, checked one by one since a hotfix release need not contain earlier ones.
releases=$(gh api "repos/$UPSTREAM/releases?per_page=30" \
  --jq '.[] | select(.draft or .prerelease | not) | [.tag_name, .html_url, .published_at] | @tsv')
missing=()
while IFS=$'\t' read -r tag url published; do
  [[ "$tag" =~ ^[A-Za-z0-9._+-]+$ ]] || continue
  ahead=$(compare "$tag" | jq '.ahead_by')
  [ "$ahead" -eq 0 ] && continue
  missing+=("$tag"$'\t'"$url"$'\t'"$published"$'\t'"$ahead")
done <<<"$releases"

if [ ${#missing[@]} -eq 0 ]; then
  echo "Fork \`$BASE\` contains the latest $UPSTREAM release." >>"$SUMMARY"
else
  latest=$(cut -f1 <<<"${missing[0]}")
  cmp=$(compare "$latest")
  behind=$(jq '.ahead_by' <<<"$cmp")
  compare_base="https://github.com/$FORK/compare/$BASE...$upstream_owner:$upstream_name"
  commit_lines() {
    jq -r --argjson n "$1" --arg repo "$UPSTREAM" --arg fmt "$2" '.commits | reverse | .[:$n][]
      | (.commit.message | split("\n")[0]) as $t | "https://github.com/\($repo)/commit/\(.sha)" as $u
      | if $fmt == "md" then "- [\(.sha[:7])](\($u)) \($t)"
        else "• <\($u)|\(.sha[:7])> \($t | gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;"))" end' <<<"$cmp"
  }

  releases_md=""
  new_releases=()
  for r in "${missing[@]}"; do
    IFS=$'\t' read -r tag url published ahead <<<"$r"
    releases_md+="- [$tag]($url) (${published%%T*}): $ahead commits behind, [compare]($compare_base:$tag)"$'\n'
    is_new "$published" && new_releases+=("<$url|$tag>")
  done

  {
    echo "### $UPSTREAM has ${#missing[@]} release(s) not in \`$BASE\`"
    echo "\`$BASE\` is **$behind commits behind $latest**. [Compare]($compare_base:$latest)"
    echo
    echo "$releases_md"
    # The compare API returns only the oldest 250 commits.
    if [ "$behind" -gt 250 ]; then
      echo "#### Commits (from the oldest 250 of $behind; see Compare for the rest)"
    else
      echo "#### Commits (newest first, up to $MAX_COMMITS)"
    fi
    commit_lines "$MAX_COMMITS" md
    echo
  } >>"$SUMMARY"
  echo "::warning title=Fork behind upstream::$BASE is $behind commits behind $UPSTREAM $latest ($compare_base:$latest)"

  if [ ${#new_releases[@]} -gt 0 ]; then
    shown="${new_releases[*]:0:$MAX_SLACK_RELEASES}"
    [ ${#new_releases[@]} -gt "$MAX_SLACK_RELEASES" ] && shown+=" (${#new_releases[@]} new releases in all)"
    slack+=":warning: *Upstream Attendee released $shown*, which Fluint-io/attendee \`$BASE\` does not have. It is $behind commits behind $latest. <$compare_base:$latest|Compare $BASE...$latest>
$(commit_lines 10 slack)

"
  fi
fi

# Comma-separated priority areas a PR touches: adapter dirs, Dockerfile, chrome/chromedriver files.
pr_areas() {
  gh api --paginate "repos/$UPSTREAM/pulls/$1/files?per_page=100" --jq '.[].filename' |
    { grep -iE "$PRIORITY_PATHS" || true; } |
    # Labels are built only from safe characters; any other match is reported as "chrome".
    awk '/^bots\/[a-z_]+adapter(\/|\.py$)/ { sub(/^bots\//, ""); sub(/[\/.].*/, ""); print; next }
      /(^|\/)Dockerfile[A-Za-z0-9._-]*$/ { sub(/.*\//, ""); print; next }
      { print "chrome" }' |
    sort -u | paste -sd, -
}
clean() { local t=${1//'##['/'# #['}; printf '%s\n' "$t"; }

# Merged PRs: reverts first, then priority areas, then the rest.
merged=$(gh api -X GET --paginate search/issues -f q="repo:$UPSTREAM is:pr is:merged merged:$since..$until_ts" -f per_page=100 -f sort=created -f order=desc \
  --jq '.items[] | [.number, (.title | gsub("[\t\n]"; " ")), .html_url, .user.login, .pull_request.merged_at,
    ([(.body // "") | scan("[Rr]everts (?:[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)?#([0-9]+)")] | .[0][0] // "")] | @tsv')
reverts="" # lines: reverted title (lowercase) TAB revert number TAB reverted number
m_revert_md="" m_prio_md="" m_other_md="" m_revert_slack="" m_prio_slack="" m_other_slack=""
m_other_count=0
while IFS=$'\t' read -r number title url author merged_at reverted; do
  [ -z "$number" ] && continue
  is_new "$merged_at" || continue
  title=$(clean "$title")
  slack_title=$(slack_escape <<<"$title")
  areas=$(pr_areas "$number")
  tag="${areas:+ ($areas)}"
  # Search is sorted newest first, so a revert is seen before the PR it reverts.
  reverted_by=$(awk -F'\t' -v n="$number" '$3 == n { print $2; exit }' <<<"$reverts")
  tag+="${reverted_by:+ — reverted in #$reverted_by}"
  if [ -n "$reverted" ] || [[ "$title" =~ ^[Rr]evert ]]; then
    if [ -n "$reverted" ]; then
      reverted_title=$(clean "$(gh api "repos/$UPSTREAM/pulls/$reverted" --jq '.title')")
      what="#$reverted \"$reverted_title\""
      what_slack="<https://github.com/$UPSTREAM/pull/$reverted|#$reverted> \"$(slack_escape <<<"$reverted_title")\""
      reverts+="$(tr '[:upper:]' '[:lower:]' <<<"$reverted_title")"$'\t'"$number"$'\t'"$reverted"$'\n'
    else
      what="(no PR number in body)" what_slack="$what"
    fi
    m_revert_md+="- **REVERT** [#$number]($url) reverts $what, by @$author$tag"$'\n'
    m_revert_slack+="• *REVERT* <$url|#$number> reverts $what_slack, by $author$tag"$'\n'
  elif [ -n "$areas" ]; then
    m_prio_md+="- [#$number]($url) $title, by @$author$tag"$'\n'
    m_prio_slack+="• <$url|#$number> $slack_title, by $author$tag"$'\n'
  else
    m_other_md+="- [#$number]($url) $title, by @$author$tag"$'\n'
    m_other_count=$((m_other_count + 1))
    [ "$m_other_count" -le "$MAX_OTHER_PRS" ] && m_other_slack+="• <$url|#$number> $slack_title, by $author$tag"$'\n'
  fi
  echo "Merged PR: #$number $title ($author)${reverted:+ [reverts #$reverted]}$tag"
done <<<"$merged"

if [ -n "$m_revert_md$m_prio_md$m_other_md" ]; then
  {
    echo "### Merged $UPSTREAM PRs ($since to $until_ts)"
    [ -n "$m_revert_md" ] && echo "#### Reverts" && echo "$m_revert_md"
    [ -n "$m_prio_md" ] && echo "#### High priority (bot adapters, Dockerfile, Chrome)" && echo "$m_prio_md"
    [ -n "$m_other_md" ] && echo "#### Other" && echo "$m_other_md"
  } >>"$SUMMARY"
  slack+=":twisted_rightwards_arrows: *Merged upstream Attendee PRs*
${m_revert_slack:+*Reverts:*
$m_revert_slack}${m_prio_slack:+*High priority:*
$m_prio_slack}${m_other_slack:+*Other:*
$m_other_slack}"
  [ "$m_other_count" -gt "$MAX_OTHER_PRS" ] && slack+="…and $((m_other_count - MAX_OTHER_PRS)) more."$'\n'
  slack+=$'\n'
fi

# New open PRs: priority areas first. One that re-applies a change reverted above is linked to it.
prs=$(gh api --paginate "repos/$UPSTREAM/pulls?state=open&sort=created&direction=desc&per_page=100" \
  --jq '.[] | [.number, (.title | gsub("[\t\n]"; " ")), .html_url, .user.login, .created_at,
    ([(.body // "") | scan("#([0-9]+)")] | map(.[0]) | join(","))] | @tsv')
adapter_md="" other_md="" adapter_slack="" other_slack=""
other_count=0
while IFS=$'\t' read -r number title url author created refs; do
  [ -z "$number" ] && continue
  is_new "$created" || continue
  title=$(clean "$title")
  areas=$(pr_areas "$number")
  lower=$(tr '[:upper:]' '[:lower:]' <<<"$title")
  note=""
  while IFS=$'\t' read -r r_title r_num r_orig; do
    [ -z "$r_num" ] && continue
    if [ "$lower" = "$r_title" ] || [[ ",$refs," == *",$r_num,"* || ",$refs," == *",$r_orig,"* ]]; then
      note=" — re-applies #$r_orig, reverted in #$r_num"
    fi
  done <<<"$reverts"
  slack_title=$(slack_escape <<<"$title")
  if [ -n "$areas" ]; then
    adapter_md+="- [#$number]($url) $title, by @$author ($areas)$note"$'\n'
    adapter_slack+="• <$url|#$number> $slack_title, by $author ($areas)$note"$'\n'
  else
    other_md+="- [#$number]($url) $title, by @$author$note"$'\n'
    other_count=$((other_count + 1))
    [ "$other_count" -le "$MAX_OTHER_PRS" ] && other_slack+="• <$url|#$number> $slack_title, by $author$note"$'\n'
  fi
  echo "New PR: #$number $title ($author)${areas:+ [$areas]}$note"
done <<<"$prs"

if [ -n "$adapter_md$other_md" ]; then
  {
    echo "### New open $UPSTREAM PRs ($since to $until_ts)"
    [ -n "$adapter_md" ] && echo "#### High priority (bot adapters, Dockerfile, Chrome)" && echo "$adapter_md"
    [ -n "$other_md" ] && echo "#### Other" && echo "$other_md"
  } >>"$SUMMARY"
  slack+=":eyes: *New upstream Attendee PRs*
${adapter_slack:+*High priority:*
$adapter_slack}${other_slack:+*Other:*
$other_slack}"
  [ "$other_count" -gt "$MAX_OTHER_PRS" ] && slack+="…and $((other_count - MAX_OTHER_PRS)) more: https://github.com/$UPSTREAM/pulls"$'\n'
fi

if [ -z "$slack" ]; then
  echo "Nothing new since $since; not alerting."
  exit 0
fi
if [ -z "${SLACK_WEBHOOK_URL:-}" ] || [ -n "${SINCE_OVERRIDE:-}" ]; then
  echo "Backfill run or SLACK_WEBHOOK_URL unset; the warning is in the job summary only. Would post:"
  echo "$slack"
  exit 0
fi
jq -n --arg text "$slack" '{text: $text}' |
  curl -fsS -X POST -H 'Content-Type: application/json' --data @- "$SLACK_WEBHOOK_URL" >/dev/null
echo "Posted to Slack."
