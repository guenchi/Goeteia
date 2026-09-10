;; expect: introduced
;; C02, the clean observable.  Variants a and a2 display a LIST, and
;; display walks a list with car -- so once the program has defined car,
;; the printer itself is captured and every element comes out through
;; the user's car.  Those two cells therefore read (shadow shadow) even
;; when every reference resolved correctly: they test the CONJUNCTION of
;; binding identity and prelude protection, and cannot say which half
;; failed.
;;
;; This cell makes the macro yield ONE symbol and displays it alone, so
;; no list is walked and the reading is about resolution and nothing
;; else.  Chez gives `introduced'.  A compiler that resolves the
;; template's car in the library's scope gives the same; today's gives
;; `shadow'.  This is the row that says whether the representation
;; works, independently of whether the prelude is protected yet.
(import (rnrs))
(begin
  (library (orc lib)
    (export head-tag)
    (import (rnrs))
    (define-syntax head-tag
      (syntax-rules () ((_) (car '(introduced))))))
  (import (orc lib)))
(define (car x) 'shadow)
(display (head-tag))
