;; expect: #t
;; RED ON PURPOSE: a top-level value definition introduced by a macro
;; cannot be read by the macro's OWN expansion.
;;
;; The definition and the reference below both come out of the same
;; template, so they carry the same marks and must denote the same
;; thing.  They do not: *vars* is keyed by the definition's marked name
;; while the lookup strips the mark, so the two never meet, and the
;; expansion fails on a name nobody wrote:
;;
;;   set! of unbound variable: #{mv <mark>}
;;
;; THIS CELL WAS WRONG UNTIL 2026-09-09 and its earlier shape must
;; not come back.  It used to write the reference OUTSIDE the macro --
;; `(m)` and then a bare `mv` -- and demand that it resolve.  That is
;; a demand to BREAK HYGIENE: a name a macro introduces is fresh, and a
;; reference the user wrote must not see it.  Chez refuses that program
;; and so does this compiler, correctly.  The old cell would have been
;; satisfied by exactly the change that makes the compiler worse.
;;
;; Which is why test/macro-toplevel-hygiene.mjs exists: it fails if
;; the fix reaches one inch further than this file's shape.
;;
;; The procedure case is NOT broken -- *fns* agrees with its lookup --
;; and is a green control in test/macro-toplevel-hygiene.ss, not a
;; defect file.  Measured 2026-09-09; three shapes were assumed broken
;; and only these two are.
(import (rnrs))
(define-syntax m
  (syntax-rules ()
    ((_) (begin (define mv (car (list 7)))
                (display (= 7 mv))))))
(m)
