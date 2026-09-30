#!/usr/bin/env bash
# Run the Linux jobs of .github/workflows/ci.yml locally, in containers, on
# the Node version .node-version pins: actionlint, the bun lockfile check,
# typecheck, lint, test, build and check:performance.
#
# It tests the working tree (tracked and untracked files, not ignored ones),
# copied into the containers: nothing is written to the checkout, and the
# checkout's node_modules is never used.
#
# The Node steps run as the image's unprivileged user `node`: as root, tests
# that expect a permission error pass through it and fail. CPUs default to
# 4, as on GitHub's Linux runners; with 2, the LAN TLS tests (RSA key
# generation and node-forge signing) exceed Jest's 5-second timeout.
#
# Memory defaults to 6g: ESLint's type-aware lint peaks at about 4.3 GB,
# and the kernel kills it in a smaller container.
#
# Environment: CI_MEMORY (default 6g), CI_CPUS (4), CI_JEST_WORKERS (2),
# CI_TIMEOUT seconds per container (1800), CI_KEEP_GOING=0 to stop at the
# first failing step, CI_SKIP a space-separated list of steps to leave out
# (actionlint lockfile typecheck lint test build check:performance).

set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
node_version=$(tr -d '[:space:]' < "$root/.node-version")
actionlint_version=$(sed -n 's#.*docker://rhysd/actionlint:\([0-9.]*\).*#\1#p' \
  "$root/.github/workflows/ci.yml" | head -1)
memory=${CI_MEMORY:-6g}
cpus=${CI_CPUS:-4}
workers=${CI_JEST_WORKERS:-2}
limit=${CI_TIMEOUT:-1800}
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

tree() { # the working tree as a tar stream
  git -C "$root" ls-files -z --cached --others --exclude-standard |
    tar -C "$root" --null -T - -c
}

available_kb=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
echo "ci-docker: Node $node_version, memory $memory, cpus $cpus, jest workers $workers;" \
  "available memory $((available_kb / 1024)) MB"
memory_kb=$(numfmt --from=iec "${memory^^}" 2>/dev/null) && memory_kb=$((memory_kb / 1024))
if [ -n "${memory_kb:-}" ] && [ "$available_kb" -lt "$memory_kb" ]; then
  echo "ci-docker: warning: less memory available than the container may use;" \
    "lint needs about 4.3 GB (CI_SKIP=lint leaves it out)"
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
# "step <name> pass|fail" lines that are collected below.
echo "== node $node_version: npm ci, typecheck, lint, test, build, check:performance"
steps_log=$(mktemp)
trap 'rm -f "$steps_log"' EXIT
# npm's cache persists in a volume, owned by the node user (uid 1000).
docker run --rm -v claudian-ci-npm-cache:/cache "node:$node_version-bookworm" \
  chown -R 1000:1000 /cache
tree | timeout "$limit" docker run --rm -i --user node --memory "$memory" --cpus "$cpus" \
  -e KEEP_GOING="$keep_going" -e WORKERS="$workers" -e SKIP="$skip" \
  -v claudian-ci-npm-cache:/home/node/.npm \
  "node:$node_version-bookworm" bash -c '
    set -u
    mkdir ~/w && tar -x -C ~/w && cd ~/w || exit 1
    git init -q && git add -A &&
      git -c user.name=ci -c user.email=ci@localhost commit -qm ci || exit 1
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
    run typecheck npm run typecheck
    run lint npm run lint
    run test npm run test -- --maxWorkers="$WORKERS"
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
