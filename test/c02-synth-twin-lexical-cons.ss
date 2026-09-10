;; expect: lex
;; GREEN TWIN of defect-c02-synth-quasiquote-cons and the internal-define
;; cells: a lexical cons written by the program stays the program's.
(import (rnrs))
(display (let ((cons (lambda (a b) (quote lex)))) (cons 1 2)))
