;; expect: #(1 2)
;; The acceptance-critical cell: a vector quasiquote in a MACRO BODY.
;; It reaches meta-qq, the transformer-level expander, not xpand-qq, so
;; a fix that adds the vector case to only one of the two passes every
;; other quasiquote-vector cell and fails this one.  On the unfixed
;; meta-qq the transformer yields #(1 (unquote (+ 1 1))).
;;
;; The transformer uses syntax-case and datum->syntax, so the quoted
;; vector it returns carries lexical context and a standard R6RS macro
;; expander accepts it -- the oracle is external (Chez answers #(1 2)),
;; not goeteia judging itself.  The value under test is only whether the
;; vector's unquote is processed at transformer level.
(import (rnrs))
(define-syntax mk
  (lambda (stx)
    (syntax-case stx ()
      ((k) (datum->syntax #'k `(quote #(1 ,(+ 1 1))))))))
(display (mk))
