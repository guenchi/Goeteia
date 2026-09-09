;; A fixture, not a test: a library whose export list names something
;; no definition provides.  See
;; test/defect-library-export-unchecked.mjs.
;;
;; ⭐ The name comes from the macro's TEMPLATE, so it is fresh and is
;; not the `made-in-template` written in the export list above -- that
;; is hygiene working, and Chez refuses this library for the same
;; reason.  ⛔ The defect is not that the name is unreachable; it is
;; that nothing says so.
;;
;; ⚠️ Writing the name as a macro ARGUMENT instead would make this
;; library correct and the cell green, because an argument is never
;; renamed.  That is stated two files away in
;; macro-toplevel-hygiene.ss, and a first draft of this fixture used
;; that shape and tested nothing.
(library (probe exported-macro)
  (export made-in-template written-out)
  (import (rnrs))
  (define-syntax define-adder
    (syntax-rules ()
      ((_ k) (define (made-in-template y) (+ y k)))))
  (define-adder 1)
  (define (written-out y) (+ y 2)))
