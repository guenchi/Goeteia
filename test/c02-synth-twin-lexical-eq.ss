;; expect: lex
;; GREEN TWIN of defect-c02-synth-case-eq: a lexical eq? written by the
;; program is the program's, and a fix that resolves the compiler's own
;; eq? to the prelude must leave this one alone.
(import (rnrs))
(display (let ((eq? (lambda (a b) (quote lex)))) (eq? 1 1)))
