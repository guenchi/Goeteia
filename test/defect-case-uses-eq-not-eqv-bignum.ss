;; expect: 1
;; RED ON PURPOSE: the bignum witness of defect-case-uses-eq-not-eqv.
;; case compares with eq?, so a datum outside the fixnum range never
;; matches; R6RS's eqv? compares such numbers by value.  Symbols and
;; characters match today, so this is a defect of number data only.
;; Chez answers 1.
(import (rnrs))
(display (case 100000000000 ((100000000000) 1) (else 2)))
