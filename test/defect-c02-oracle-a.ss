;; expect: (substituted introduced)
;; C02, the binding-identity defect, stated as the reviewer's falsification
;; fixture: expansion must preserve enough context per identifier that a
;; `car' written inside a library macro resolves to the library's `car'
;; while a `car' the caller wrote resolves to the caller's.  Chez is the
;; oracle for the expect line; the design that has to make this green is
;; archive/goeteia-c02-binding-identity-design.md (see its section 0h).
;;
;; Variant a: the template introduces car twice; the user shadows car after the import.  Both must be the library's car.
