#!/usr/bin/env bash
# release-inventory.sh - read-only inventory of what changes between the deployed
# version and the release candidate, for the prod-deployment-planner skill.
#
# Usage: release-inventory.sh <deployed-ref> <candidate-ref>
#
# Run from anywhere inside the repository. Prints key=value lines and
# <name>_begin / <name>_end blocks. Ends with status=ok (exit 0) or
# status=stop plus stop_reason (exit 2).
#
# Every block is a heuristic CANDIDATE list (path and regex matches). Confirm
# each item by reading the code before stating it as fact.
# Secret-like names print as file:line plus the name only; long literal strings
# that look like credentials are redacted; config files print keys, not values.
#
# Never fetches, checks out, writes files, or changes refs, index or config.
# Compatible with macOS /bin/bash 3.2.

set -euo pipefail
export GIT_OPTIONAL_LOCKS=0 GIT_PAGER=cat LC_ALL=C

emit() { printf '%s=%s\n' "$1" "$2"; }
stop() { emit status stop; emit stop_reason "$1"; exit 2; }

if [ $# -ne 2 ]; then
  echo "usage: release-inventory.sh <deployed-ref> <candidate-ref>" >&2
  exit 64
fi

root=$(git rev-parse --show-toplevel 2>/dev/null) || stop "not inside a git work tree"
cd "$root"

from=$(git rev-parse --verify -q "$1^{commit}") || stop "deployed ref '$1' does not resolve to a commit locally"
to=$(git rev-parse --verify -q "$2^{commit}") || stop "candidate ref '$2' does not resolve to a commit locally"
if [ "$from" = "$to" ]; then stop "deployed and candidate are the same commit ($to); nothing to release"; fi

emit generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
emit repo_root "$root"
origin_url=$(git remote get-url origin 2>/dev/null || true)
if [ -n "$origin_url" ]; then
  slug=$(printf '%s\n' "$origin_url" | sed -E 's#^[A-Za-z][A-Za-z0-9+.-]*://##; s#^[^@/]*@##; s#^([^/:]+):#\1/#; s#\.git$##; s#/+$##')
else
  slug=$(basename "$root")
fi
slug=$(printf '%s\n' "$slug" | sed -E 's#[^A-Za-z0-9._/-]#_#g; s#\.\.+#_#g; s#^/+##')
emit repo_slug "$slug"
emit evidence_root "$HOME/.claude/release-evidence/$slug"

# --- Identity and range -----------------------------------------------------
emit deployed_ref "$1"
emit deployed_sha "$from"
emit deployed_describe "$(git describe --tags --always "$from" 2>/dev/null || echo none)"
emit candidate_ref "$2"
emit candidate_sha "$to"
emit candidate_describe "$(git describe --tags --always "$to" 2>/dev/null || echo none)"
emit candidate_commit_date "$(git log -1 --format=%cI "$to")"
emit candidate_branches_containing "$(git for-each-ref --contains "$to" --format='%(refname:short)' refs/heads refs/remotes | awk 'NR <= 10' | tr '\n' ' ' | sed 's/ $//')"
if git merge-base --is-ancestor "$from" "$to"; then emit deployed_is_ancestor_of_candidate true; else emit deployed_is_ancestor_of_candidate false; fi
n_release=$(git rev-list --count "$from..$to")
n_missing=$(git rev-list --count "$to..$from")
emit commits_to_release "$n_release"
emit merge_commits_to_release "$(git rev-list --merges --count "$from..$to")"
emit commits_deployed_but_missing_from_candidate "$n_missing"
emit diff_shortstat "$(git diff --shortstat -M "$from" "$to" | sed 's/^ *//')"

echo "release_commits_begin"
git log -n 200 --no-decorate --date=short --format='%h %ad %s' "$from..$to"
if [ "$n_release" -gt 200 ]; then echo "... $((n_release - 200)) more"; fi
echo "release_commits_end"

if [ "$n_missing" -gt 0 ]; then
  echo "deployed_commits_missing_from_candidate_begin"
  git log -n 50 --no-decorate --date=short --format='%h %ad %s' "$to..$from"
  echo "deployed_commits_missing_from_candidate_end"
fi

# --- Changed paths by category -----------------------------------------------
diff_ns=$(git diff --name-status -M "$from" "$to")

classify_awk='
BEGIN { FS = "\t" }
NF >= 2 {
  st = substr($1, 1, 1); p = (NF >= 3 ? $3 : $2); q = "/" p; hit = 0
  if (q ~ /\/vendor\//) { print "vendored\t" st "\t" p; next }
  if (q ~ /\/(migrations?|migrate|schema|schemas|sql)\// || p ~ /\.sql$/ || q ~ /\/atlas\.(hcl|sum)$/) { print "migrations\t" st "\t" p; hit = 1 }
  if (p ~ /\.(proto|avsc|graphql|graphqls)$/ || q ~ /\/buf(\.gen|\.work)?\.ya?ml$/ || q ~ /\/(openapi|swagger|asyncapi)[^\/]*\.(ya?ml|json)$/ || p ~ /\.pb(\.gw)?\.go$/) { print "contracts\t" st "\t" p; hit = 1 }
  code_or_doc = (p ~ /\.(go|md)$/ || q ~ /\/testdata\//)
  if ((!code_or_doc && q ~ /\/(deploy|deploys|deployment|deployments|k8s|kube|kubernetes|kustomize|helm|chart|charts|manifest|manifests|infra|infrastructure|terraform|pulumi|argocd|argo|flux|ops|nomad)\//) || q ~ /\/(Chart|kustomization|skaffold|serverless|app|fly)\.(ya?ml|toml)$/ || p ~ /\.(tf|tfvars)$/ || q ~ /\/Pulumi[^\/]*\.ya?ml$/ || q ~ /\/values[^\/]*\.ya?ml$/ || q ~ /\/\.?goreleaser\.ya?ml$/ || q ~ /\/\.?ko\.ya?ml$/ || q ~ /\/Procfile$/) { print "deploy-manifests\t" st "\t" p; hit = 1 }
  if (q ~ /\/[^\/]*[Dd]ockerfile[^\/]*$/ || q ~ /\/\.dockerignore$/) { print "container-build\t" st "\t" p; hit = 1 }
  if (q ~ /\/(docker-)?compose[^\/]*\.ya?ml$/ || q ~ /\/Tiltfile$/) { print "local-dev-env\t" st "\t" p; hit = 1 }
  if (q ~ /^\/\.github\/(workflows|actions)\// || q ~ /^\/\.gitlab-ci\.ya?ml$/ || q ~ /^\/\.circleci\// || q ~ /\/Jenkinsfile[^\/]*$/ || q ~ /^\/\.buildkite\// || q ~ /^\/(azure|bitbucket)-pipelines\.ya?ml$/) { print "ci-cd\t" st "\t" p; hit = 1 }
  if (q ~ /\/\.env[^\/]*$/ || (!code_or_doc && q ~ /\/(config|configs|conf|settings|environments)\//) || q ~ /\/(config|settings|application|appsettings)[^\/]*\.(ya?ml|toml|json|ini|properties)$/) { print "config\t" st "\t" p; hit = 1 }
  if (q ~ /\/(go\.mod|go\.sum|go\.work|go\.work\.sum)$/) { print "go-deps\t" st "\t" p; hit = 1 }
  is_test = (p ~ /_test\.go$/)
  if (!is_test && q ~ /\/(worker|workers|consumer|consumers|producer|producers|cron|crons|scheduler|schedulers|job|jobs|queue|queues|outbox|subscriber|subscribers|listener|listeners|processor|processors)[^\/]*(\/|\.go$)/) { print "async-workers\t" st "\t" p; hit = 1 }
  if (!is_test && q ~ /[Pp]ayment|[Pp]ayout|[Cc]harge|[Rr]efund|[Ii]nvoice|[Bb]illing|[Ll]edger|[Ss]ettle|[Ww]allet|[Cc]heckout|[Ss]tripe|[Aa]dyen|[Bb]raintree|psp|PSP/) { print "payments-domain\t" st "\t" p; hit = 1 }
  if (p ~ /_test\.go$/ || q ~ /\/testdata\//) { print "tests\t" st "\t" p; hit = 1 }
  if (p ~ /\.md$/ || q ~ /^\/docs?\//) { print "docs\t" st "\t" p; hit = 1 }
  if (!hit && p ~ /\.go$/) { print "go-source\t" st "\t" p; hit = 1 }
  if (!hit) { print "other\t" st "\t" p }
}'
classified=""
if [ -n "$diff_ns" ]; then classified=$(printf '%s\n' "$diff_ns" | awk "$classify_awk"); fi

for cat in migrations contracts deploy-manifests container-build ci-cd config go-deps async-workers payments-domain local-dev-env; do
  CAT="$cat" awk -F'\t' '$1 == ENVIRON["CAT"] { n++; if (n <= 200) l[n] = $2 " " $3 }
    END { printf "paths_%s_begin (count=%d)\n", ENVIRON["CAT"], n + 0; for (i = 1; i <= n && i <= 200; i++) print l[i]; if (n > 200) printf "... %d more\n", n - 200; printf "paths_%s_end\n", ENVIRON["CAT"] }' <<EOF
$classified
EOF
done
for cat in go-source tests docs other vendored; do
  emit "paths_${cat}_count" "$(CAT="$cat" awk -F'\t' '$1 == ENVIRON["CAT"] { n++ } END { print n + 0 }' <<EOF
$classified
EOF
)"
done

# --- Binaries (package main) -------------------------------------------------
mains=$(git grep -l -E '^package main([[:space:]]|$)' "$to" -- ':(glob)**/*.go' \
  ':(exclude,glob)**/vendor/**' ':(exclude,glob)**/testdata/**' ':(exclude,glob)**/*_test.go' \
  ':(exclude,glob)**/test/**' ':(exclude,glob)**/tests/**' ':(exclude,glob)**/e2e/**' ':(exclude,glob)**/examples/**' 2>/dev/null \
  | sed "s#^$to:##" \
  | awk '{ n = split($0, a, "/"); if (n == 1) { print "."; next } d = a[1]; for (i = 2; i < n; i++) d = d "/" a[i]; print d }' \
  | sort -u) || true
changed_go_dirs=$(printf '%s\n' "$diff_ns" \
  | awk -F'\t' 'NF >= 2 { p = (NF >= 3 ? $3 : $2); if (p ~ /\.go$/ && p !~ /_test\.go$/) print p }' \
  | awk '{ n = split($0, a, "/"); if (n == 1) { print "."; next } d = a[1]; for (i = 2; i < n; i++) d = d "/" a[i]; print d }' \
  | sort -u) || true
echo "main_packages_begin (excludes test/, tests/, e2e/, examples/; directly-changed = files in that package dir changed; transitive impact needs go list -deps)"
if [ -n "$mains" ]; then
  CHANGED="$changed_go_dirs" awk 'BEGIN { n = split(ENVIRON["CHANGED"], c, "\n"); for (i = 1; i <= n; i++) ch[c[i]] = 1 }
    NF { printf "%s %s\n", (($0 in ch) ? "directly-changed" : "not-directly-changed"), $0 }' <<EOF | awk 'NR <= 200'
$mains
EOF
fi
echo "main_packages_end"

echo "changed_go_packages_begin"
if [ -n "$changed_go_dirs" ]; then printf '%s\n' "$changed_go_dirs" | awk '("/" $0) !~ /\/(vendor|testdata)(\/|$)/' | awk 'NR <= 300'; fi
echo "changed_go_packages_end"

# --- Shared awk helpers ------------------------------------------------------
helpers_awk='
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
function clip(s) { return length(s) > 160 ? substr(s, 1, 157) "..." : s }
function redact(s,   out, rest, lit, inner) {
  out = ""; rest = s
  while (match(rest, /"[^"]*"|`[^`]*`/)) {
    lit = substr(rest, RSTART, RLENGTH); inner = substr(lit, 2, RLENGTH - 2)
    # Credential-looking literal: long, mixed letters and digits, no spaces, and not an import/host path.
    if (length(inner) >= 20 && inner ~ /[0-9]/ && inner ~ /[A-Za-z]/ && inner !~ / / && !(inner ~ /^[a-z0-9.-]+\.[a-z][a-z]+\// && inner !~ /@/)) lit = "\"<redacted>\""
    out = out substr(rest, 1, RSTART - 1) lit; rest = substr(rest, RSTART + RLENGTH)
  }
  return out rest
}
function hunk(s,   a, b) {
  a = s; sub(/^@@ -/, "", a); b = a; sub(/[ ,].*$/, "", a); old_n = a + 0
  sub(/^[^+]*\+/, "", b); sub(/[ ,].*$/, "", b); new_n = b + 0
}'

# --- Added Go lines matching deployment-relevant patterns ---------------------
export P_ENV='os\.(Getenv|LookupEnv)\(|envconfig:"|env:"|viper\.[A-Za-z]+\(|flag\.[A-Za-z0-9]+\(|pflag\.|kingpin\.|\.Flags\(\)\.'
export P_SECRET='[A-Z0-9_]*(SECRET|TOKEN|PASSWORD|PASSWD|API_?KEY|PRIVATE_?KEY|CREDENTIAL|ACCESS_?KEY)[A-Z0-9_]*'
export P_MESSAGING='[Tt]opic|ConsumeTopics|kgo\.|sarama\.|kafka\.|amqp\.|nats\.|[Jj]et[Ss]tream|sqs\.|sns\.|pubsub\.|\.Publish\(|\.Subscribe\(|[Oo]utbox'
export P_RPC_HTTP='grpc\.(Dial|DialContext|NewClient|NewServer)|New[A-Za-z0-9]*Client\(|Register[A-Za-z0-9]*Server\(|http\.(NewRequest|NewRequestWithContext|Get|Post|Head)\(|HandleFunc\(|\.Handle\(|\.(GET|POST|PUT|PATCH|DELETE)\(|_URL|_ADDR|_HOST|_ENDPOINT'
export P_FLAGS='[Ff]eature[A-Za-z_]*|IsEnabled\(|launchdarkly|unleash|flipt|growthbook|openfeature|[Kk]ill[Ss]witch'
export P_TUNING='[Tt]imeout|[Dd]eadline|SetMaxOpenConns|SetMaxIdleConns|SetConnMaxLifetime|SetConnMaxIdleTime|MaxConns|MinConns|PoolSize|[Rr]etry|[Rr]etries|[Bb]ackoff|MaxAttempts|[Cc]oncurrency|[Ww]orkers|errgroup\.|SetLimit\(|semaphore\.|[Rr]ate[Ll]imit|time\.(Millisecond|Second|Minute|Hour)'
export P_DB='\.(Exec|Query|QueryRow|Prepare)(Context)?\(|\.Begin(Tx)?\(|(INSERT|UPDATE|DELETE|SELECT|ALTER|CREATE|DROP) '
export P_MIGRATION_RUN='AutoMigrate|migrate\.(New|Up)|goose\.(Up|Run|SetDialect)|[Rr]un[Mm]igrations|[Mm]igrator|embed.*migrations|\.Schema\.Create\('
export P_PAYMENTS='[Pp]ayment|[Pp]ayout|[Cc]harge|[Rr]efund|[Cc]apture|[Aa]uthori[sz]e|[Ii]dempoten|[Ss]tripe|[Aa]dyen|[Bb]raintree|PSP|psp\.|[Ll]edger|[Ss]ettle|[Ww]ebhook|[Rr]econcil'

git diff -U0 --no-color --no-ext-diff --no-prefix -M "$from" "$to" -- ':(glob)**/*.go' \
  ':(exclude,glob)**/*_test.go' ':(exclude,glob)**/vendor/**' ':(exclude,glob)**/testdata/**' \
  ':(exclude,glob)**/*.pb.go' ':(exclude,glob)**/*.pb.gw.go' \
  | awk "$helpers_awk"'
BEGIN {
  ncat = split("env-config secret-names messaging rpc-http feature-flags tuning db-sql migration-runner payments", cats, " ")
  pat["env-config"] = ENVIRON["P_ENV"]; pat["secret-names"] = ENVIRON["P_SECRET"]
  pat["messaging"] = ENVIRON["P_MESSAGING"]; pat["rpc-http"] = ENVIRON["P_RPC_HTTP"]
  pat["feature-flags"] = ENVIRON["P_FLAGS"]; pat["tuning"] = ENVIRON["P_TUNING"]
  pat["db-sql"] = ENVIRON["P_DB"]; pat["migration-runner"] = ENVIRON["P_MIGRATION_RUN"]
  pat["payments"] = ENVIRON["P_PAYMENTS"]
}
/^diff --git / { hdr = 1; next }
hdr && /^\+\+\+ / { f = substr($0, 5); next }
/^@@ / { hdr = 0; hunk($0); next }
hdr { next }
/^\+/ {
  line = substr($0, 2)
  if (line !~ /^[ \t]*\/\//) {
    for (i = 1; i <= ncat; i++) {
      c = cats[i]
      if (c == "secret-names") {
        if (!match(toupper(line), pat[c])) continue
        out = f ":" new_n ": " substr(line, RSTART, RLENGTH)
      } else {
        if (line !~ pat[c]) continue
        out = f ":" new_n ": " clip(redact(trim(line)))
      }
      cnt[c]++
      if (cnt[c] <= 40) buf[c] = buf[c] out "\n"
    }
  }
  new_n++
  next
}
END {
  for (i = 1; i <= ncat; i++) {
    c = cats[i]
    printf "added_go_lines_%s_begin (count=%d%s)\n", c, cnt[c] + 0, (cnt[c] > 40 ? ", first 40 shown" : "")
    printf "%s", buf[c]
    printf "added_go_lines_%s_end\n", c
  }
}'

# --- Contract files (proto/OpenAPI/Avro/GraphQL): added and removed lines -----
echo "contract_changes_begin (+ new line number, - old line number)"
git diff -U0 --no-color --no-ext-diff --no-prefix -M "$from" "$to" -- \
  ':(glob)**/*.proto' ':(glob)**/*.avsc' ':(glob)**/*.graphql' ':(glob)**/*.graphqls' \
  ':(glob)**/openapi*.yaml' ':(glob)**/openapi*.yml' ':(glob)**/openapi*.json' \
  ':(glob)**/swagger*.yaml' ':(glob)**/swagger*.yml' ':(glob)**/swagger*.json' ':(exclude,glob)**/vendor/**' \
  | awk "$helpers_awk"'
/^diff --git / { hdr = 1; next }
hdr && /^\+\+\+ / { f = substr($0, 5); next }
hdr && /^--- / { of = substr($0, 5); next }
/^@@ / { hdr = 0; hunk($0); next }
hdr { next }
/^\+/ { k++; if (k <= 200) print "+ " f ":" new_n ": " clip(redact(trim(substr($0, 2)))); new_n++; next }
/^-/ { k++; if (k <= 200) print "- " (f == "/dev/null" ? of : f) ":" old_n ": " clip(redact(trim(substr($0, 2)))); old_n++; next }
END { if (k > 200) printf "... %d more lines\n", k - 200 }'
echo "contract_changes_end"

# --- SQL / migration statements added ------------------------------------------
echo "sql_statements_added_begin (lines in migration paths and .sql files matching DDL/DML keywords)"
mig_paths=$(printf '%s\n' "$classified" | awk -F'\t' '$1 == "migrations" && $2 != "D" { print $3 }')
if [ -n "$mig_paths" ]; then
  old_ifs=$IFS; IFS='
'
  set -f
  # shellcheck disable=SC2086
  git diff -U0 --no-color --no-ext-diff --no-prefix -M "$from" "$to" -- $mig_paths \
    | awk "$helpers_awk"'
/^diff --git / { hdr = 1; next }
hdr && /^\+\+\+ / { f = substr($0, 5); next }
/^@@ / { hdr = 0; hunk($0); next }
hdr { next }
/^\+/ {
  line = substr($0, 2); low = tolower(line)
  if (low ~ /alter table|alter column|alter type|drop |rename|add column|not null|set default|drop default|create (unique )?index|concurrently|update |delete from|insert into|truncate|set data type|add constraint|foreign key|validate constraint|not valid|create table|create type|lock table|automigrate/) {
    k++; if (k <= 200) print f ":" new_n ": " clip(redact(trim(line)))
  }
  new_n++; next
}
END { if (k > 200) printf "... %d more\n", k - 200 }'
  set +f
  IFS=$old_ifs
fi
echo "sql_statements_added_end"

# --- Config, manifest, CI and container changes (keys only for config) --------
echo "config_and_manifest_changes_begin (config/.env files: keys only; secret-like keys: values withheld)"
cfg_paths=$(printf '%s\n' "$classified" | awk -F'\t' '$1 ~ /^(config|deploy-manifests|ci-cd|container-build|local-dev-env)$/ { print $3 }' | sort -u)
if [ -n "$cfg_paths" ]; then
  old_ifs=$IFS; IFS='
'
  set -f
  # shellcheck disable=SC2086
  git diff -U0 --no-color --no-ext-diff --no-prefix -M "$from" "$to" -- $cfg_paths \
    | awk "$helpers_awk"'
function keyof(s,   k) { k = trim(s); sub(/^-[ \t]*/, "", k); sub(/^export[ \t]+/, "", k); if (match(k, /[:=]/)) k = substr(k, 1, RSTART - 1); gsub(/["\047]/, "", k); return trim(k) }
/^diff --git / { hdr = 1; next }
hdr && /^\+\+\+ / { f = substr($0, 5); keys_only = (("/" f) ~ /\/(\.env[^\/]*|(config|configs|conf|settings|environments)\/.*|(config|settings|application|appsettings)[^\/]*\.(ya?ml|toml|json|ini|properties))$/); next }
hdr && /^--- / { of = substr($0, 5); next }
/^@@ / { hdr = 0; hunk($0); next }
hdr { next }
/^[+-]/ {
  sign = substr($0, 1, 1); line = substr($0, 2); file = (f == "/dev/null" ? of : f); num = (sign == "+" ? new_n : old_n)
  if (sign == "+") new_n++; else old_n++
  if (trim(line) == "" || trim(line) ~ /^#/) next
  key = keyof(line)
  if (keys_only) text = "key " key
  else if (toupper(key) ~ /SECRET|TOKEN|PASSWORD|PASSWD|API_?KEY|PRIVATE_?KEY|CREDENTIAL|ACCESS_?KEY/) text = key " <value withheld>"
  else text = clip(redact(trim(line)))
  k++; if (k <= 250) print sign " " file ":" num ": " text
}
END { if (k > 250) printf "... %d more\n", k - 250 }'
  set +f
  IFS=$old_ifs
fi
echo "config_and_manifest_changes_end"

# --- Go module dependency changes ----------------------------------------------
echo "go_mod_changes_begin"
git diff -U0 --no-color --no-ext-diff --no-prefix "$from" "$to" -- ':(glob)**/go.mod' ':(glob)**/go.work' ':(exclude,glob)**/vendor/**' \
  | awk '/^diff --git / { hdr = 1; next } hdr && /^\+\+\+ / { f = substr($0, 5); next } /^@@ / { hdr = 0; next } hdr { next }
    /^[+-]/ { k++; if (k <= 150) print substr($0, 1, 1) " " f ": " substr($0, 2) } END { if (k > 150) printf "... %d more\n", k - 150 }'
echo "go_mod_changes_end"

emit status ok
