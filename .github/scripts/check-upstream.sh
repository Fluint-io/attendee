#!/usr/bin/env bash
# Warns when upstream Attendee has (a) releases this fork's default branch lacks, or (b) new open PRs.
# "New" means published/opened after this workflow's last successful run, so each item alerts once.
# Slack when SLACK_WEBHOOK_URL is set; the job summary always.
set -euo pipefail

UPSTREAM="${UPSTREAM:-attendee-labs/attendee}"
FORK="${GITHUB_REPOSITORY:?}"
BASE="${BASE_BRANCH:-main}"
WORKFLOW="${WORKFLOW_FILE:-upstream-check.yml}"
FIRST_RUN_LOOKBACK_DAYS=7
MAX_COMMITS=40
MAX_OTHER_PRS=10
ADAPTER_PATHS='^bots/[a-z_]*adapter'
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/stdout}"
upstream_owner="${UPSTREAM%%/*}"
upstream_name="${UPSTREAM##*/}"

compare() { gh api "repos/$FORK/compare/$BASE...$upstream_owner:$upstream_name:$1"; }

# The workflow is unknown (404) until it exists on the default branch; treat that as a first run.
since=$(gh api "repos/$FORK/actions/workflows/$WORKFLOW/runs?status=success&per_page=1" \
  --jq '.workflow_runs[0].created_at // ""' 2>/dev/null || true)
if [[ ! "$since" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]; then
  since=$(date -u -d "-$FIRST_RUN_LOOKBACK_DAYS days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
    date -u -v-"$FIRST_RUN_LOOKBACK_DAYS"d +%Y-%m-%dT%H:%M:%SZ)
  first_run=1
fi
echo "Reporting items newer than $since."

slack=""

# Releases the fork lacks. Upstream releases are linear on main, so stop at the first one the fork has.
releases=$(gh api "repos/$UPSTREAM/releases?per_page=30" \
  --jq '.[] | select(.draft or .prerelease | not) | [.tag_name, .html_url, .published_at] | @tsv')
missing=()
while IFS=$'\t' read -r tag url published; do
  [ -z "$tag" ] && continue
  [ "$(compare "$tag" | jq '.ahead_by')" -eq 0 ] && break
  missing+=("$tag"$'\t'"$url"$'\t'"$published")
done <<<"$releases"

if [ ${#missing[@]} -eq 0 ]; then
  echo "Fork \`$BASE\` contains the latest $UPSTREAM release." >>"$SUMMARY"
else
  latest=$(cut -f1 <<<"${missing[0]}")
  latest_published=$(cut -f3 <<<"${missing[0]}")
  cmp=$(compare "$latest")
  behind=$(jq '.ahead_by' <<<"$cmp")
  compare_url="https://github.com/$FORK/compare/$BASE...$upstream_owner:$upstream_name:$latest"
  commit_lines() {
    jq -r --argjson n "$1" --arg repo "$UPSTREAM" --arg fmt "$2" '.commits | reverse | .[:$n][]
      | (.commit.message | split("\n")[0]) as $t | "https://github.com/\($repo)/commit/\(.sha)" as $u
      | if $fmt == "md" then "- [\(.sha[:7])](\($u)) \($t)" else "• <\($u)|\(.sha[:7])> \($t)" end' <<<"$cmp"
  }

  releases_md=""
  releases_slack=""
  for r in "${missing[@]}"; do
    IFS=$'\t' read -r tag url published <<<"$r"
    releases_md+="- [$tag]($url) (${published%%T*})"$'\n'
    [ ${#releases_slack} -lt 1000 ] && releases_slack+="<$url|$tag> "
  done
  [ ${#missing[@]} -gt 5 ] && releases_slack="$(cut -d' ' -f1-5 <<<"$releases_slack") (${#missing[@]} releases in all) "

  {
    echo "### $UPSTREAM has ${#missing[@]} release(s) not in \`$BASE\`"
    echo "\`$BASE\` is **$behind commits behind $latest**. [Compare]($compare_url)"
    echo
    echo "$releases_md"
    echo "#### Commits (newest first, up to $MAX_COMMITS)"
    commit_lines "$MAX_COMMITS" md
    echo
  } >>"$SUMMARY"
  echo "::warning title=Fork behind upstream::$BASE is $behind commits behind $UPSTREAM $latest ($compare_url)"

  if [ -n "${first_run:-}" ] || [[ "$latest_published" > "$since" ]]; then
    slack+=":warning: *Upstream Attendee released ${releases_slack% }*, which Fluint-io/attendee \`$BASE\` does not have. It is $behind commits behind $latest. <$compare_url|Compare $BASE...$latest>
$(commit_lines 10 slack)

"
  fi
fi

# New open upstream PRs; ones touching the bot adapters come first.
prs=$(gh api --paginate "repos/$UPSTREAM/pulls?state=open&sort=created&direction=desc&per_page=100" \
  --jq ".[] | select(.created_at > \"$since\") | [.number, (.title | gsub(\"[\\t\\n]\"; \" \")), .html_url, .user.login] | @tsv")
adapter_md="" other_md="" adapter_slack="" other_slack=""
other_count=0
while IFS=$'\t' read -r number title url author; do
  [ -z "$number" ] && continue
  areas=$(gh api --paginate "repos/$UPSTREAM/pulls/$number/files?per_page=100" --jq '.[].filename' |
    grep -E "$ADAPTER_PATHS" | sed -E 's#^bots/([a-z_]*adapter).*#\1#' | sort -u | paste -sd, - || true)
  line="#$number $title ($author)"
  if [ -n "$areas" ]; then
    adapter_md+="- [#$number]($url) $title, by @$author ($areas)"$'\n'
    adapter_slack+="• <$url|#$number> $title, by $author ($areas)"$'\n'
  else
    other_md+="- [#$number]($url) $title, by @$author"$'\n'
    other_count=$((other_count + 1))
    [ "$other_count" -le "$MAX_OTHER_PRS" ] && other_slack+="• <$url|#$number> $title, by $author"$'\n'
  fi
  echo "New PR: $line${areas:+ [$areas]}"
done <<<"$prs"

if [ -n "$adapter_md$other_md" ]; then
  {
    echo "### New open $UPSTREAM PRs since $since"
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
