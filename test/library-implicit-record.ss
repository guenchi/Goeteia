;; expect: (7 11 #t #f)
;; A library whose record type uses the implicit names: (define-record-type
;; point (fields x)) binds make-point, point? and point-x without spelling
;; them.  Those names are the library's private top-level names too, so
;; the namespacing pass must derive them exactly as the record expander
;; does and rename definition and use alike -- renaming only the uses
;; leaves `cannot call: L:make-point'.  A second library with the same
;; implicit record name must not meet the first.
;; RED under the import rule, and kept as written: the program uses
;; mk1 and mk2, the exports of the two inline libraries above it, and
;; never imports them.  It cannot: an (import (t one)) written at top
;; level is resolved by the driver, which looks for a library file and
;; finds none, and moving the libraries and the import into a (begin ...)
;; -- how every other inline-library cell writes it -- loses the
;; private namespacing this cell exists to test, since namespace-library
;; does not descend into a begin and the two make-point names collide.
;; So a top-level inline library is not importable by the program that
;; defines it, which the flat splice never needed and the rule now
;; requires.  Expectation kept; the fix belongs to the driver or to
;; namespace-library, not to this file.
(import (rnrs))
(library (t one)
  (export mk1 get1 is1?)
  (import (rnrs))
  (define-record-type point (fields x))
  (define (mk1 v) (make-point v))
  (define (get1 p) (point-x p))
  (define (is1? p) (point? p)))
(library (t two)
  (export mk2 get2 is2?)
  (import (rnrs))
  (define-record-type point (fields (mutable y)))
  (define (mk2 v) (make-point v))
  (define (get2 p) (point-y p))
  (define (is2? p) (point? p)))
(define a (mk1 7))
(define b (mk2 11))
(display (list (get1 a) (get2 b) (is1? a) (is1? b)))
(newline)
