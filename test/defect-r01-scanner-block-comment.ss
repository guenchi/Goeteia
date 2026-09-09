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
;; ⚠️ The failure is a refusal, which is the lucky half.  The same gap
;; runs the other way in the mount and top-level-span scans, where an
;; unmatched paren inside a block comment moves the depth counter and
;; the scanner then slices somewhere else entirely -- and slicing the
;; wrong span does not announce itself.
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
