;; expect: 1
;; Fixture for test/defect-spec-candidate-by-name.mjs.  foo is a top-level
;; function that nothing calls; the only other mention of its NAME is a
;; lexical binder in an unrelated let.  Today that binder enrols foo as a
;; float-specialisation candidate, and with no visible call to demote the
;; optimistic seed it is published as taking an f64 second parameter.
(import (rnrs))
(define (foo a b) (fl+ a b))
(display (let ((foo 5)) 1))
