#!/usr/bin/env bash
# Fail when a step re-resolved dependencies instead of using the committed
# lockfile. PUB_HOSTED_URL has to be set on every step that resolves (flutter
# build/test and dart run all run an implicit `pub get`): the lockfile records
# packages as coming from the mirror, so without it pub treats those entries as
# a different source and silently upgrades them. A release built from a graph
# nobody tested is worse than a red job.
set -uo pipefail

cd "$(git rev-parse --show-toplevel)"

if git diff --quiet -- pubspec.lock; then
    echo "pubspec.lock untouched: this job built the pinned dependency set."
    exit 0
fi

echo "::error::pubspec.lock was rewritten during this job - the artifacts are not built from the committed dependency set. Fix by setting PUB_HOSTED_URL on the step that resolved, or commit the intended upgrade."
git --no-pager diff --unified=0 -- pubspec.lock | grep -E '^(\+\+\+|---|\+|-)' | grep -vE '^(\+\+\+|---) ' | head -40
exit 1
