;; expect: 5
;; RED ON PURPOSE, and PRE-EXISTING: measured red on HEAD before any of
;; the binding-form work; found by codex during the spec-shadowed-
;; parameter review.  It is the same family as
;; defect-spec-shadowed-parameter -- a shadowed name taken for the thing
;; it shadows -- but in OPERATOR position rather than operand.
;;
;; fl-expr-in? decides a call argument is a flonum expression when its
;; head is a direct fl primitive of the right arity.  That test does not
;; ask whether the head is lexically BOUND, so a locally rebound fl+ is
;; still read as the primitive.  Here fl+ is shadowed by a lambda that
;; returns the exact 5, so (fl+ 1.0 2.0) is the exact 5, not a flonum --
;; but the analysis classifies it as a flonum expression, specialises
;; zq's parameter a to f64, and the exact 5 lands in an f64 slot: an
;; illegal cast at run time.  Chez answers 5.
;;
;; The monotonicity argument for the parameter fix does not reach this:
;; that argument shows the subtraction introduces no unsound typing, it
;; says nothing about whether a classification that SURVIVES is sound,
;; and this is a surviving-but-unsound one.  The fix is a separate piece
;; of work -- fl-expr-in?'s primitive recognition has to decline a head
;; that is lexically bound at the point of use -- so this cell is placed
;; red and named, not fixed here.
;;
;; The js target answers 5: f64 specialisation is a wasm matter, so this
;; file is red on stage0 and stage1 only, and its two lines in a gate
;; are the expected count, not a third host that happened to pass.
(import (rnrs))
(define (zq a b) (if (fl<? b 0.0) (zq (fl+ a 0.0) (fl+ b 1.0)) a))
(display (let ((fl+ (lambda (x y) 5))) (zq (fl+ 1.0 2.0) 0.0)))
