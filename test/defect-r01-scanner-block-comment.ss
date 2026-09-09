;; expect: #t
;; RED ON PURPOSE: the dependency scanner does not know what a block
;; comment is, so an (import ...) written inside one is taken for the
;; library's real import list.
;;
;; test/lib/probe/commented-import.ss mentions `(import (nonexistent
;; lib))` inside #| |#.  The reader discards it.  The scanner in
;; rt/compile.mjs skips `;` comments, string literals and `#\` char
;; literals -- and nothing else -- so it finds that clause first,
;; returns it, and the library's real (import (rnrs)) is never seen.
;;
;; Measured directly against the scanner's own loop: it returns
;; "(import (nonexistent lib))".
;;
;; ⚠️ The failure is a refusal, which is the lucky half.
;;
;; ⭐ SIX SCANNERS, ONE GAP, AND ONE REACHABLE CASE -- the last part
;; measured, not reasoned.  rt/compile.mjs and rt/repl.mjs hold six
;; hand-written walkers (topLevelSpans, libraryImports, listDatumEnd,
;; embedBlocks, balance, topSpans) whose comment/string/char handling
;; is byte-identical in all six and knows only `;`, `"` and `#\`.
;; They did not drift apart; they were copied already incomplete.
;;
;; ⛔ But the consequences do NOT follow from the gap.  An earlier
;; draft of this comment claimed that an unmatched paren inside a block
;; comment moves the depth counter and makes a scanner slice the wrong
;; span.  Measured through the library path, one form at a time:
;;
;;     #| a ( in prose |#            compiles
;;     #| a ) in prose |#            compiles
;;     #| (import (nope lib)) |#     REFUSED   ⇐ the only one
;;     #;(import (nope lib))         compiles
;;     #| out #| in |# out |#        compiles
;;     ; (import (nope lib))         compiles  (control)
;;
;; ⇒ The reachable failure is a block comment containing a literal
;; import CLAUSE, because that is what libraryImports pattern-matches
;; for.  Stray parens shift the depth without changing which clause
;; matches.  ⚠️ A nine-cell file asserting the other forms was written
;; from reading the source, passed every cell, and was deleted: it
;; tested nothing, and would have read as coverage.
;;
;; ⭐ The six copies still matter, and they are why this is one finding
;; rather than two: patching the reported scanner leaves five, and the
;; next report names a different one.  What the tree lacks is not a
;; case in a switch, it is one scanner.
;;
;; ⭐ This is a degeneracy failure, not a parsing bug: there are two
;; readers of this source and they disagree.  The tree HAS a correct
;; reader; the scanner is a second, smaller one written to answer a
;; narrower question, and it drifted.  ⇒ The fix is not "add #| to the
;; scanner" -- that leaves #;, |symbols| and nesting for next time.
;;
;; The control is a library with an ordinary line comment mentioning an
;; import, which the scanner already handles, so a red here means the
;; block-comment case specifically.
(import (rnrs) (probe commented-import) (probe lined-import))
(define fails '())
(define (want name got expect)
  (unless (equal? got expect) (set! fails (cons (list name 'got got 'want expect) fails))))
(want 'CONTROL-line-comment (lined) 7)
(want 'r01-block-comment (answer) 42)
(if (null? fails) (display #t) (begin (display fails) (newline)))
