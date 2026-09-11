;; expect: (a . b)
;; EXPECTED FAIL, and the LEADING-boundary sibling of
;; test/defect-reader-dotted-tail-skips-only-blanks.ss.  Same cause,
;; opposite side of the dot: the branch that decides whether a "." is a
;; tail marker tests %delimiter? alone, so it never reaches the
;; atmosphere layer that consumes #| and #;.  Chez answers (a . b).
;;
;; IT HAS ITS OWN FILE BECAUSE IT CANNOT SHARE ONE.  A reader error is
;; a COMPILE-time error here, so a guard in the same file never runs --
;; the file does not get as far as having a program.  One cell per
;; reader boundary is forced by the mechanism, not a choice.
;;
;; WRITTEN BECAUSE THE BEHAVIOUR CHANGED, which is the reason it is not
;; simply folded into the sibling.  Measured on stage1 across the
;; delimiter fix:
;;   before  (a .;#;c#; b)   a garbage symbol, silently, nothing said
;;   after   read: a lone . is not a datum
;; Silent wrong value to loud refusal is an improvement and still not
;; right, and a changed behaviour with no row of its own is invisible.
;;
;; NOT FIXED IN THAT SLICE, deliberately.  The atmosphere handling is
;; inlined in %read-list-from's cond -- its own comment says a comment
;; inside a list has to be skipped there rather than by $read -- so
;; there is no %skip-atmosphere to call from the two dot sites.  The
;; repair is to extract one and use it at both, which is a change to a
;; load-bearing reader and earns a design pass.  Both dot cells should
;; go green together when it happens; if only one does, the extraction
;; was not the fix.
;;
;; stage0 PASSES this, being Chez-hosted, so only the self-hosted path
;; shows it.  A reading taken through bin/goeteiac says nothing about
;; goeteia's reader.
(import (rnrs))
(display '(a .#|c|# b))
