;; expect: 1
;; The interpret-mode half of exactly-once, which is the half that can
;; regress.  In EMIT mode (a top-level quasiquote) the active operation
;; is called once and the resulting form is built once, so once-ness is
;; structural; but in INTERPRET mode -- a quasiquote in a transformer
;; body -- that call IS the evaluation, so a walker that touches an
;; operand twice evaluates its effect twice, and nothing but a count
;; reveals it.
;;
;; The transformer builds a vector whose single element is an effectful
;; unquote that increments n, then returns n as its expansion.  n is the
;; number of times the walker evaluated the operand: 1 on a correct
;; walker, 0 on the unfixed meta-qq (which never processes the vector,
;; so the effect never fires -- the red witness), and 2 on a walker that
;; evaluates an active expression twice, which is the regression this
;; cell exists to catch and the only arm the base and the fix cannot
;; produce.  Pinned by the count, not the value.  Chez: 1.
(import (rnrs))
(define-syntax mk
  (lambda (stx)
    (syntax-case stx ()
      ((k)
       (let ((n 0))
         (let ((v `#(,(begin (set! n (+ n 1)) 'x))))
           (datum->syntax #'k n)))))))
(display (mk))
