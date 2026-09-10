;; expect: (1 2 3)
;; Green twin of defect-c02-synth-append-lexical: a lexical `car' around
;; the same splice does NOT reach the compiler's use of car, because
;; the first two binding-identity slices resolve written and introduced
;; car where they were written.  This must stay green while the
;; synthesized-reference slice is built.
(import (rnrs))
(display (let ((car (lambda (p) 'mine))) `(1 ,@'(2 3))))
