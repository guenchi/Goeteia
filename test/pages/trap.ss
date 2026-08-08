;; Compiles clean; the product has outgrown the i31 fixnum range and
;; the bitwise path accepts only a fixnum, so the cast traps at run
;; time with no source position anywhere in the message.
(import (rnrs) (web dom))

(define (mask x) (bitwise-and x 255))

(set-text! (get-element-by-id "app")
           (number->string (mask (* 100000 100000))))
