#!/usr/bin/env bash
# Warns when upstream Attendee has (a) releases this fork's default branch lacks, or (b) new open PRs.
# An item is new when it falls between the last successful run's start and this run's start,
# so each item alerts once. Slack when SLACK_WEBHOOK_URL is set; the job summary always.
set -euo pipefail

UPSTREAM="${UPSTREAM:-attendee-labs/attendee}"
FORK="${GITHUB_REPOSITORY:?}"
BASE="${BASE_BRANCH:-main}"
WORKFLOW="${WORKFLOW_FILE:-upstream-check.yml}"
FIRST_RUN_LOOKBACK_DAYS=7
MAX_COMMITS=40
MAX_OTHER_PRS=10
MAX_SLACK_RELEASES=5
ADAPTER_PATHS='^bots/[a-z_]*adapter'
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
if ! since=$(gh api "repos/$FORK/actions/workflows/$WORKFLOW/runs?status=success&per_page=1" \
  --jq '.workflow_runs[0].created_at // ""' 2>/tmp/runs.err); then
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

# Releases the fork lacks. Upstream releases are linear on main, so stop at the first one the fork has.
releases=$(gh api "repos/$UPSTREAM/releases?per_page=30" \
  --jq '.[] | select(.draft or .prerelease | not) | [.tag_name, .html_url, .published_at] | @tsv')
missing=()
while IFS=$'\t' read -r tag url published; do
  [ -z "$tag" ] && continue
  ahead=$(compare "$tag" | jq '.ahead_by')
  [ "$ahead" -eq 0 ] && break
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
    echo "#### Commits (newest first, up to $MAX_COMMITS)"
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

# New open upstream PRs; ones touching the bot adapters come first.
prs=$(gh api --paginate "repos/$UPSTREAM/pulls?state=open&sort=created&direction=desc&per_page=100" \
  --jq '.[] | [.number, (.title | gsub("[\t\n]"; " ")), .html_url, .user.login, .created_at] | @tsv')
adapter_md="" other_md="" adapter_slack="" other_slack=""
other_count=0
while IFS=$'\t' read -r number title url author created; do
  [ -z "$number" ] && continue
  is_new "$created" || continue
  title=${title//'##['/'# #['}
  files=$(gh api --paginate "repos/$UPSTREAM/pulls/$number/files?per_page=100" --jq '.[].filename')
  areas=$( (grep -E "$ADAPTER_PATHS" <<<"$files" || true) | sed -E 's#^bots/([a-z_]*adapter).*#\1#' | sort -u | paste -sd, -)
  slack_title=$(slack_escape <<<"$title")
  if [ -n "$areas" ]; then
    adapter_md+="- [#$number]($url) $title, by @$author ($areas)"$'\n'
    adapter_slack+="• <$url|#$number> $slack_title, by $author ($areas)"$'\n'
  else
    other_md+="- [#$number]($url) $title, by @$author"$'\n'
    other_count=$((other_count + 1))
    [ "$other_count" -le "$MAX_OTHER_PRS" ] && other_slack+="• <$url|#$number> $slack_title, by $author"$'\n'
  fi
  echo "New PR: #$number $title ($author)${areas:+ [$areas]}"
done <<<"$prs"

if [ -n "$adapter_md$other_md" ]; then
  {
    echo "### New open $UPSTREAM PRs ($since to $until_ts)"
    [ -n "$adapter_md" ] && echo "#### Touching bot adapters" && echo "$adapter_md"
    [ -n "$other_md" ] && echo "#### Other" && echo "$other_md"
  } >>"$SUMMARY"
  slack+=":eyes: *New upstream Attendee PRs*
${adapter_slack:+*Bot adapters:*
$adapter_slack}${other_slack:+*Other:*
$other_slack}"
  [ "$other_count" -gt "$MAX_OTHER_PRS" ] && slack+="…and $((other_count - MAX_OTHER_PRS)) more: https://github.com/$UPSTREAM/pulls"$'\n'
fi

if [ -z "$slack" ]; then
  echo "Nothing new since $since; not alerting."
  exit 0
fi
if [ -z "${SLACK_WEBHOOK_URL:-}" ]; then
  echo "SLACK_WEBHOOK_URL is not set; the warning is in the job summary only. Would post:"
  echo "$slack"
  exit 0
fi
jq -n --arg text "$slack" '{text: $text}' |
  curl -fsS -X POST -H 'Content-Type: application/json' --data @- "$SLACK_WEBHOOK_URL" >/dev/null
echo "Posted to Slack."
