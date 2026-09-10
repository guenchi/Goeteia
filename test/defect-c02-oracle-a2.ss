;; expect: (shadow introduced)
;; C02, the binding-identity defect, stated as the reviewer's falsification
;; fixture: expansion must preserve enough context per identifier that a
;; `car' written inside a library macro resolves to the library's `car'
;; while a `car' the caller wrote resolves to the caller's.  Chez is the
;; oracle for the expect line; the design that has to make this green is
;; archive/goeteia-c02-binding-identity-design.md (see its section 0h).
;;
;; Variant a2 -- THE ONE THE REPRESENTATION IS JUDGED ON: the caller's own (car ...) is substituted beside the template's introduced car, in one form, and the two must resolve differently.
