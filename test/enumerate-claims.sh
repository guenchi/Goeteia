#!/bin/sh
# The strong-claim enumerator: every assertion whose NAME makes a
# universal or negative claim about the thing it checks.
#
# WHY THIS FILE EXISTS.  Two rounds of this survey reported different
# denominators -- 49 and 48 -- and neither could be reconciled, because
# the first enumerator was a shell one-liner nobody kept.  A count with
# no author cannot be argued with, only re-guessed; the earlier 49 is
# now unrecoverable and the disagreement was settled by discarding it.
# So the rule lives here, and a dispute about the denominator is a
# dispute about THIS file.
#
# Run it:   sh test/enumerate-claims.sh          # the claims, one per line
#           sh test/enumerate-claims.sh -c       # just the count
#
# It is not a test.  run-tests.sh globs test/*.ss and names its .mjs
# suites explicitly, so a .sh here is never picked up -- the same
# reason test/mutate.sh is a .sh.
#
# ---- the rule, version 1 (2026-08-28) -------------------------------
#
# KEY: the assertion's NAME as written -- the string after `test('`,
# `test("` or `check "`.  Not the line number: line numbers move when
# the file above them is edited, and one reconciliation in this survey
# was thrown off by exactly that.  Claims are compared as text.
#
# WORDS: a name qualifies when it contains one of
#
#     only every all no never cannot always unique exactly none any
#     both full
#
# as a whole word, in either case.  These are the words that make a
# name expensive to be wrong about: each asserts something about a
# WHOLE set, so a cell that holds less than its name says is a cell
# nobody knows is weak.
#
# KNOWN IMPRECISION, recorded rather than fixed: the extractor cuts a
# name at the first quote it meets, so two spellings of one claim
# ("...to the authority bytes" and "...to the authority's bytes")
# arrive as two entries, and a name containing an apostrophe is
# truncated.  That is a property OF THIS RULE and it moves the count;
# it is written down so the next disagreement starts from the rule
# rather than from the number.
#
# The count this produced when B12 closed: 48.
WORDS='only|every|all|no|never|cannot|always|unique|exactly|none|any|both|full'

cd "$(dirname "$0")/.."
claims=$(grep -rhoE "(test\('|test\(\"|check \")[^\"')]{6,110}" test/*.mjs test/*.ss 2>/dev/null \
    | sed "s/^test('//; s/^test(\"//; s/^check \"//" \
    | grep -iE "\b($WORDS)\b" \
    | sort -u)

if [ "$1" = "-c" ]; then
    printf '%s\n' "$claims" | grep -c .
else
    printf '%s\n' "$claims"
fi
