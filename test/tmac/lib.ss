;; support library for test/macro-lib.ss -- a syntax-rules macro
;; defined and used within the same library (regression: the use
;; once expanded before the macro was registered; see collect-macros!)
(library (tmac lib)
  (export ml-add ml-sq ml-when0)
  (import (rnrs))
  (define-syntax twice
    (syntax-rules () ((_ e) (+ e e))))
  (define-syntax sqm
    (syntax-rules () ((_ e) (* e e))))
  (define-syntax unless0
    (syntax-rules () ((_ c a b) (if (= c 0) b a))))
  (define (ml-add x) (twice x))
  ;; use in an arithmetic/bitwise context (the shape that surfaced
  ;; as "illegal cast" when the macro stayed unexpanded)
  (define (ml-sq x) (bitwise-and (sqm x) 255))
  (define (ml-when0 x) (unless0 x 'nonzero 'zero)))
