;; expect: (7 11 #t #f)
;; A library whose record type uses the implicit names: (define-record-type
;; point (fields x)) binds make-point, point? and point-x without spelling
;; them.  Those names are the library's private top-level names too, so
;; the namespacing pass must derive them exactly as the record expander
;; does and rename definition and use alike -- renaming only the uses
;; leaves `cannot call: L:make-point'.  A second library with the same
;; implicit record name must not meet the first.
;; The two inline libraries below are defined at top level -- their
;; private record names must not meet, which is what this cell tests
;; -- and the program imports them by name after defining them.  A
;; library defined in the program being compiled is not looked for on
;; disk; until the drivers knew that, an import of an inline library
;; reported it not found, and the only way to import one was to wrap
;; it in a begin, which lost the namespacing this cell exists for.
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
(import (rnrs) (t one) (t two))
(define a (mk1 7))
(define b (mk2 11))
(display (list (get1 a) (get2 b) (is1? a) (is1? b)))
(newline)
