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
    # A COMPILE failure must be recorded and skipped, not fatal. Under `set -e` a bare g++ here
    # aborted the whole script on the first broken file, so the remaining tests never ran and the
    # log just stopped. That was survivable while this was one file run by hand; it is not now
    # that there are eight and CI invokes this script, where a truncated log reads as "the suite
    # is smaller than I thought" rather than "it died early". A failing test RUN already used
    # `|| fail=1` and continued, so this only makes the two paths behave the same way.
    g++ -std=c++17 -Wall -I"$CORE" -Istubs -o "/tmp/$(basename "$t" .cpp)" "$t" "$src" \
        || { echo "!! COMPILE FAILED: $t"; fail=1; continue; }
    "/tmp/$(basename "$t" .cpp)" || fail=1
done
exit $fail
