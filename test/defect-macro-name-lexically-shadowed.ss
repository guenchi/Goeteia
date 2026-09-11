;; expect: 99
;; RED ON PURPOSE, and no import rule is involved: the expander has no
;; lexical environment, so a let or lambda binding a name that is also
;; a macro does not shadow the macro -- the use still expands.  d2 is a
;; syntax-rules macro; (let ((d2 ...)) (d2 4)) must call the lambda, 99,
;; and answers 8 (the macro (+ 4 4)) instead.  This is older and wider
;; than the import work -- it holds for any macro, program or library,
;; renamed or not -- and it is what three rows of
;; defect-renamed-syntax-and-literals are really about.  The fix is a
;; bound-set the binding forms push and pop, consulted before macro
;; lookup; it lands before the pre-expansion import table, which must
;; not call a shadowed name a keyword.
(import (rnrs))
(define-syntax d2 (syntax-rules () ((_ x) (+ x x))))
(display (let ((d2 (lambda (x) 99))) (d2 4)))
