;; expect: 42
;; RED ON PURPOSE: a list tail that starts with a variable named quote
;; is skipped by dead-code elimination as if it were a quotation, and
;; the reference after it is lost.
;;
;; form-refs takes lists apart car and cdr, so its worklist holds tails
;; as well as expressions; the tail of (vector quote foo) is
;; (quote foo).  The arm that skips quotations tests the head alone, so
;; that tail is skipped, foo is never seen, and its definition is
;; pruned while this program still needs it: the compile stops with
;; foo unbound.  Chez answers 42.  Present before the binding-form
;; work on this walk, which guarded its own three arms on "is an
;; expression" and left the older quote arm as it found it; a
;; reviewer's fixture reached it.
(import (rnrs))
(define foo 42)
(let ((quote 0)) (display (vector-ref (vector quote foo) 1)))
