;; expect: 5
;; The let-shadow representative of the shadowed-primitive family, now a
;; passing regression cell.  It was found by codex during the spec-
;; shadowed-parameter review and was red on HEAD until the operator-
;; position fix; it is the same family as defect-spec-shadowed-parameter
;; -- a shadowed name taken for the thing it shadows -- but in OPERATOR
;; position rather than operand.
;;
;; fl-expr-in? decides a call argument is a flonum expression when its
;; head is a direct fl primitive of the right arity.  Before the fix
;; that test did not ask whether the head is lexically BOUND, so a
;; locally rebound fl+ was still read as the primitive.  Here fl+ is
;; shadowed by a lambda that returns the exact 5, so (fl+ 1.0 2.0) is the
;; exact 5, not a flonum -- and reading it as a flonum expression
;; specialised zq's parameter a to f64 and put that exact 5 in the slot,
;; an illegal cast.  The fix hands fl-expr-in? the lexical scope and
;; declines a head found in it.  Chez answers 5.
;;
;; The monotonicity argument for the parameter fix did not reach this:
;; it shows the subtraction introduces no unsound typing, not that a
;; classification that SURVIVES is sound, and this was a surviving-but-
;; unsound one.  The other five binding forms in the family have their
;; own cells; internal define and letrec were never broken and get none.
(import (rnrs))
(define (zq a b) (if (fl<? b 0.0) (zq (fl+ a 0.0) (fl+ b 1.0)) a))
(display (let ((fl+ (lambda (x y) 5))) (zq (fl+ 1.0 2.0) 0.0)))
