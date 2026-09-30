#!/usr/bin/env bash
# Run the Linux jobs of .github/workflows/ci.yml locally, in containers, on
# the Node version .node-version pins:
#
#   workflow-lint     actionlint
#   lockfile          bun install --frozen-lockfile
#   quality           typecheck, lint, npm audit
#   diff-hygiene      git diff --check against the base (below)
#   test-scope        scripts/ciTestSelection.mjs against the base
#   selected-tests    the selected tests, per shard, under a clock set 1100
#                     days ahead (libfaketime), then their timing summary
#   build-artifacts   build and check:performance, and the release version
#                     check when there is a release tag (below)
#
# Left out, since they need GitHub itself or another OS: dependency-review
# (GitHub's dependency graph API), cross-platform-smoke (Windows and macOS
# runners), the uploads of test timings and release artifacts (printed
# here instead, or left in the container), and the aggregate jobs `test`
# and `build`, whose part the summary plays.
#
# The base stands in for a pull request's base branch: CI_BASE names it
# (default origin/main, which follows upstream's main; a clone of the fork
# has no upstream remote). The containers get its merge base with HEAD and
# the working tree on top, so diff-hygiene and test-scope see what a pull
# request from this tree would change. CI_BASE= (empty) runs as a push
# does: every test, and no diff-hygiene. A missing base fails diff-hygiene
# and, as on GitHub, widens the selection to every test.
#
# The release version check runs when CI_RELEASE_TAG names a tag, by
# default a tag at HEAD that looks like a version; on GitHub it runs for tag
# pushes.
#
# It tests the working tree (tracked and untracked files, not ignored ones),
# copied into the containers: nothing is written to the checkout, and the
# checkout's node_modules is never used.
#
# The Node steps run as the image's unprivileged user `node`: as root, tests
# that expect a permission error pass through it and fail. The image is
# node's with libfaketime added, built once as claudian-ci-node:<version>.
# CPUs default to 4, as on GitHub's Linux runners; with 2, the LAN TLS tests
# (RSA key generation and node-forge signing) exceed Jest's 5-second
# timeout. Jest workers default to 3, as in CI's test jobs.
#
# Memory defaults to 8g: ESLint's type-aware lint has peaked at 4.3 GB on
# one machine and at 6.1 GB (resident, all processes) on another, where the
# kernel killed it now and then in a 6g container.
#
# Environment: CI_BASE (origin/main), CI_RELEASE_TAG, CI_MEMORY (8g),
# CI_CPUS (4), CI_JEST_WORKERS (3), CI_TIMEOUT seconds per container
# (1800), CI_KEEP_GOING=0 to stop at the first failing step, CI_SKIP a
# space-separated list of steps to leave out (actionlint lockfile typecheck
# lint audit diff-hygiene test-scope selected-tests build check:performance
# release-version).

set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
node_version=$(tr -d '[:space:]' < "$root/.node-version")
actionlint_version=$(sed -n 's#.*docker://rhysd/actionlint:\([0-9.]*\).*#\1#p' \
  "$root/.github/workflows/ci.yml" | head -1)
memory=${CI_MEMORY:-8g}
cpus=${CI_CPUS:-4}
workers=${CI_JEST_WORKERS:-3}
limit=${CI_TIMEOUT:-1800}
base=${CI_BASE-origin/main}
release_tag=${CI_RELEASE_TAG-$(git -C "$root" tag --points-at HEAD |
  grep -E '^[0-9]+[.][0-9]+[.][0-9]+([-+][0-9A-Za-z.-]+)?$' | head -1)}
keep_going=${CI_KEEP_GOING:-1}
skip=" ${CI_SKIP:-} "

results=()
failed=0

record() { # name status
  results+=("$(printf '%-18s %s' "$1" "$2")")
  case "$2" in pass|skipped) ;; *) failed=1 ;; esac
}

skipped() { # name: true when CI_SKIP lists it
  case "$skip" in *" $1 "*) record "$1" skipped; return 0 ;; esac
  return 1
}

tree() { # [prefix]: the working tree as a tar stream
  git -C "$root" ls-files -z --cached --others --exclude-standard |
    tar -C "$root" --null -T - -c ${1:+--transform "s,^,$1,"}
}

# The Node steps' input: the merge base's tree under base/ (when there is
# one) and the working tree under head/, as concatenated tar archives.
base_commit=
if [ -n "$base" ]; then
  base_commit=$(git -C "$root" merge-base "$base" HEAD 2>/dev/null) ||
    echo "ci-docker: warning: no merge base with $base (CI_BASE); diff-hygiene" \
      "fails and test-scope selects every test"
fi
node_input() {
  if [ -n "$base_commit" ]; then git -C "$root" archive --prefix=base/ "$base_commit"; fi
  tree head/
}

available_kb=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
echo "ci-docker: Node $node_version, memory $memory, cpus $cpus, jest workers $workers;" \
  "available memory $((available_kb / 1024)) MB"
echo "ci-docker: base ${base:-none (as a push)}${base_commit:+ (merge base ${base_commit:0:10})};" \
  "release tag ${release_tag:-none}"
memory_kb=$(numfmt --from=iec "${memory^^}" 2>/dev/null) && memory_kb=$((memory_kb / 1024))
if [ -n "${memory_kb:-}" ] && [ "$available_kb" -lt "$memory_kb" ]; then
  echo "ci-docker: warning: less memory available than the container may use;" \
    "lint needs up to about 6 GB (CI_SKIP=lint leaves it out)"
fi

echo "== actionlint ${actionlint_version:-latest}"
mapfile -t workflows < <(git -C "$root" ls-files --cached --others --exclude-standard \
  '.github/workflows/*.yml' '.github/workflows/*.yaml')
# As the caller's user: the image's own (guest) cannot read files that are
# not world-readable.
if skipped actionlint; then :
elif timeout "$limit" docker run --rm --user "$(id -u):$(id -g)" \
  -v "$root:/repo:ro" -w /repo \
  "rhysd/actionlint:${actionlint_version:-latest}" -color "${workflows[@]}"; then
  record actionlint pass
else
  record actionlint fail
fi

echo "== lockfile (bun install --frozen-lockfile)"
if skipped lockfile; then :
elif tree | timeout "$limit" docker run --rm -i --memory "$memory" --cpus "$cpus" \
  oven/bun:1 sh -c 'mkdir /w && tar -x -C /w && cd /w &&
    bun install --frozen-lockfile --ignore-scripts'; then
  record lockfile pass
else
  record lockfile fail
fi

# One Node container runs npm ci once, then each step; it prints
# "step <name> pass|fail|skipped" lines that are collected below.
echo "== node $node_version: npm ci, quality, diff-hygiene, test-scope," \
  "selected-tests, build-artifacts"
steps_log=$(mktemp)
trap 'rm -f "$steps_log"' EXIT
image="claudian-ci-node:$node_version"
if ! docker image inspect "$image" >/dev/null 2>&1; then
  printf '%s\n' "FROM node:$node_version-bookworm" \
    'RUN apt-get update && apt-get install -y --no-install-recommends faketime && rm -rf /var/lib/apt/lists/*' |
    docker build -q -t "$image" - >/dev/null || record node-image fail
fi
# npm's cache persists in a volume, owned by the node user (uid 1000).
docker run --rm -v claudian-ci-npm-cache:/cache "$image" chown -R 1000:1000 /cache
node_input | timeout "$limit" docker run --rm -i --user node --memory "$memory" --cpus "$cpus" \
  -e KEEP_GOING="$keep_going" -e WORKERS="$workers" -e SKIP="$skip" \
  -e BASE="$base_commit" -e BASE_MISSING="${base:+${base_commit:-1}}" \
  -e RELEASE_TAG="$release_tag" \
  -v claudian-ci-npm-cache:/home/node/.npm \
  "$image" bash -c '
    set -u
    mkdir ~/in && tar -xi -C ~/in && mv ~/in/head ~/w && cd ~/w || exit 1
    # History for the diffs: the merge base, then the working tree.
    commit() { git -c user.name=ci -c user.email=ci@localhost commit -q --allow-empty -m "$1"; }
    git init -q || exit 1
    if [ -n "$BASE" ]; then
      (cd ~/in/base && git --git-dir ~/w/.git --work-tree . add -A -f) && commit base || exit 1
    fi
    git add -A -f && commit head && rm -rf ~/in || exit 1
    run() { # name command...
      local name=$1; shift
      case "$SKIP" in *" $name "*) echo "step $name skipped"; return 0 ;; esac
      echo "-- $name"
      if "$@"; then echo "step $name pass"; return 0; fi
      echo "step $name fail"
      [ "$KEEP_GOING" = 1 ] || exit 1
      return 1
    }
    run npm-ci npm ci --no-audit --no-fund || exit 1

    # quality
    run typecheck npm run typecheck
    run lint npm run lint
    run audit npm audit --audit-level=moderate

    # diff-hygiene, which CI runs on pull requests only
    if [ -n "$BASE" ]; then
      run diff-hygiene git diff --check HEAD~1 HEAD
    elif [ "$BASE_MISSING" = 1 ]; then
      echo "-- diff-hygiene: no merge base with the base CI_BASE names"
      echo "step diff-hygiene fail"
    fi

    # test-scope: what a pull request from the base would select, or, with
    # no base, everything (as for a push without a usable base).
    scope() {
      if [ -n "$BASE" ]; then
        GITHUB_EVENT_NAME=pull_request BASE_SHA=HEAD~1 HEAD_SHA=HEAD \
          node scripts/ciTestSelection.mjs
      else
        node scripts/ciTestSelection.mjs
      fi > ~/scope.txt && cat ~/scope.txt
    }
    get() { sed -n "s/^$1=//p" ~/scope.txt; }
    if run test-scope scope; then
      test_files=$(get test-files)
      script_tests=$(get script-tests)
      # selected-tests, one run per shard, as CI runs its matrix
      case "$SKIP" in *" selected-tests "*) echo "step selected-tests skipped" ;; *)
        if [ "$(get has-tests)" != true ]; then
          echo "-- selected-tests: no tests selected"
          echo "step selected-tests skipped"
        else
          mkdir -p test-results
          for shard in $(get test-shards | node -e "
              JSON.parse(require(\"fs\").readFileSync(0, \"utf8\")).forEach(s => console.log(s))"); do
            n=${shard%/*}
            if [ "$shard" = 2/2 ]; then scripts="[]"; else scripts=$script_tests; fi
            # About three years ahead, so a test that depends on the date
            # fails here, not on the day its fixture expires.
            run "selected-tests:$shard" env FAKETIME_DONT_FAKE_MONOTONIC=1 \
              faketime -f +1100d npm run test -- --selection "$test_files" \
              --script-selection "$scripts" --shard="$shard" --maxWorkers="$WORKERS" \
              --json --outputFile="test-results/jest-$n.json"
            # The timing summary CI uploads is printed here instead.
            if [ "$test_files" != "[]" ]; then
              run "test-timings:$shard" node scripts/summarize-jest-results.mjs \
                "test-results/jest-$n.json" "test-results/timings-$n" &&
                cat "test-results/timings-$n/slowest-tests.md"
            fi
          done
        fi ;;
      esac
    else
      echo "step selected-tests fail"
    fi

    # build-artifacts
    if [ -n "$RELEASE_TAG" ]; then
      run release-version node scripts/check-release-version.mjs "$RELEASE_TAG"
    fi
    run build npm run build && run check:performance npm run check:performance
    exit 0
  ' 2>&1 | tee "$steps_log"
node_status=${PIPESTATUS[1]}
while read -r _ name status; do
  record "$name" "$status"
done < <(grep -E '^step [^ ]+ (pass|fail|skipped)$' "$steps_log")
if [ "$node_status" -eq 124 ]; then
  record node-container "fail (timed out after ${limit}s)"
elif [ "$node_status" -ne 0 ]; then
  record node-container "fail (exit $node_status)"
fi

echo
echo "== summary"
printf '%s\n' "${results[@]}"
exit "$failed"
