#!/usr/bin/env bash
# Host regression tests for the detection classifiers.
#
# WHY THIS EXISTS: the classifiers are pure functions over an advert buffer, so they can be tested
# on a laptop in under a second, with no board and no drive. That matters because a classifier
# regression COMPILES FINE and only shows up in the field as "it stopped detecting things" - which
# is the one failure this product cannot afford and the one you are least likely to notice.
#
# Added 2026-07-31 after glassesClassifyBLE was restructured from return-on-first-match to
# score-and-keep. That change was invisible to the compiler and to five rounds of code review.
#
#   ./run.sh          # build + run every test
set -euo pipefail
cd "$(dirname "$0")"
CORE="../../lib/acab_core"
fail=0
for t in test_*.cpp; do
    src="${t#test_}"; src="${CORE}/${src%.cpp}_detect.cpp"
    [ -f "$src" ] || { echo "!! no source for $t (looked for $src)"; fail=1; continue; }
    echo ">> $t"
    g++ -std=c++17 -Wall -I"$CORE" -Istubs -o "/tmp/$(basename "$t" .cpp)" "$t" "$src"
    "/tmp/$(basename "$t" .cpp)" || fail=1
done
exit $fail
