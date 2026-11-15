#!/usr/bin/env bash
# Stands in for the chaos peer: turns on one random fault flag in prod, commits it with an
# innocuous message and pushes it, without printing which flag it chose. Run it where git can
# push to this repository; the cluster's deploy keys are read-only.
set -euo pipefail

cd "$(dirname "$0")/.."
values=envs/prod/values.yaml
flags=(
  's/^    latencyMs: 0$/    latencyMs: 1500/'
  's/^    errorRate: 0$/    errorRate: 0.2/'
  's/^    memoryLeak: false$/    memoryLeak: true/'
  's/^    slowDb: false$/    slowDb: true/'
)

git switch -q main
git pull -q --ff-only
sed -i "${flags[RANDOM % ${#flags[@]}]}" "$values"
if git diff --quiet "$values"; then
  echo "the chosen flag is already on: revert the last chaos commit first" >&2
  exit 1
fi
git commit -q -m "chore: tune prod settings" "$values"
git push -q
echo "one fault is planted in prod: sync shoplite-prod, then find it with Grafana alone"
