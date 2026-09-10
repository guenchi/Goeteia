;; expect: (lexical substituted)
;; C02, the binding-identity defect, stated as the reviewer's falsification
;; fixture: expansion must preserve enough context per identifier that a
;; `car' written inside a library macro resolves to the library's `car'
;; while a `car' the caller wrote resolves to the caller's.  Chez is the
;; oracle for the expect line; the design that has to make this green is
;; archive/goeteia-c02-binding-identity-design.md (see its section 0h).
;;
;; A first version of this file was committed with no program in it: a
;; shell edit failed silently, the cell read as red, and the red was
;; taken for the defect.  An empty cell is red for every reason at once.
;;
;; Variant b, the GREEN TWIN: the template introduces a lexical car
;; binder around the substituted expression.  Right today; a repair
;; must not disturb it.
(import (rnrs))
(begin
  (library (orc lib2)
    (export with-my-car)
    (import (rnrs))
    (define-syntax with-my-car
      (syntax-rules ()
        ((_ e) (let ((car (lambda (p) 'lexical))) (list (car '(introduced)) e))))))
  (import (orc lib2)))
(display (with-my-car (car '(substituted))))
