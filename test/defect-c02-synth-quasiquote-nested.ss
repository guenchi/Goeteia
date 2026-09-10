;; expect: #t
;; A nested quasiquote rebuilds the inner template with cons at every
;; level, and a program's top-level cons used to build it (see
;; defect-c02-synth-quasiquote-cons).  The value is compared with
;; equal? against the written-out form rather than displayed, because
;; this writer does not abbreviate quasiquote and unquote when printing
;; -- (1 (quasiquote (2 (unquote (3 4))))) where Chez prints
;; (1 `(2 ,(3 4))) -- and that abbreviation is a printer's choice, not
;; a value.  Chez answers #t.
(import (except (rnrs) cons))
(define (cons a b) (quote mine))
(display (equal? `(1 `(2 ,(3 ,(+ 1 3)))) (quote (1 (quasiquote (2 (unquote (3 4))))))))
