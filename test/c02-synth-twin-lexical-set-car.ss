;; expect: lex
;; GREEN TWIN of defect-c02-synth-internal-define-set-car: a lexical
;; set-car! written by the program stays the program's.
(import (rnrs))
(display (let ((set-car! (lambda (p v) (quote lex)))) (set-car! (list 1) 2)))
