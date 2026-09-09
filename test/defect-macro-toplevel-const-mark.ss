;; expect: #t
;; RED ON PURPOSE: a constant initialiser, deleted without a word.
;; A macro that expands to a top-level definition produces a name the
;; program cannot use.  *vars* (and *fns*) are keyed by the definition's
;; ORIGINAL name, which carries the mark an expansion puts on it, while
;; every later lookup strips the mark -- so the two never meet.
;;
;; ⚠️ Three symptoms, three files, because each fails at compile time
;; and would otherwise hide the others.  All three are the same
;; mismatch; only the downstream consequence differs.
;;
;;   value with a non-pure initialiser   set! of unbound variable:
;;                                       #{mv <mark>}  -- names a
;;                                       variable nobody wrote
;;   value with a constant initialiser   unbound variable: mc
;;                                       -- pure-init? lets dead-code
;;                                       elimination delete the whole
;;                                       definition, and nothing says so
;;   function definition                 cannot call: mf, the same way
;;
;; ⭐ The two "constant" and "function" cases were reported as WORKING.
;; They compile -- as long as nothing uses the name.  ⇒ "it compiles"
;; and "it works" are different questions, and the mildest-looking case
;; is the one that is hardest to notice: the definition is simply not
;; there.
;;
;; The one shape that does work is a name handed in as a macro ARGUMENT:
;; it was never renamed, so both sides agree.  That is
;; test/macro-toplevel-var-argument.ss, and it is green for a reason
;; that cannot quietly change -- unlike these three.
(import (rnrs))
(define-syntax m (syntax-rules () ((_) (define mc 1))))
(m)
(display (= 1 mc))
