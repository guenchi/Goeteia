;; expect: #t
;; A primitive used as a value is one object too.  `car' names the same
;; procedure everywhere it is referenced, so `(eq? car car)' is #t in
;; Chez and in R6RS.  Both targets synthesised a fresh eta-expansion at
;; every reference site instead, so two references were never eq?,
;; memq could not find a primitive in a list holding it and an
;; eq-hashtable could not key on one.  Each shape is pinned separately
;; so that fixing one target or one shape does not hide the others.
(import (rnrs))
(define table (make-eq-hashtable))
(hashtable-set! table car 'found)
(define (uses-prim) (eq? vector-ref vector-ref))
(and (eq? car car)                                  ; the same primitive, twice
     (let ((f car)) (eq? f car))                    ; a copy is the same object
     (let ((f cdr) (g cdr)) (eq? f g))
     (and (memq car (list car cdr)) #t)             ; membership by identity
     (eq? (hashtable-ref table car 'missing) 'found)  ; keys by identity
     (uses-prim)                                    ; inside a function body
     (eq? (let ((f +)) f) +)                        ; a variadic primitive
     (not (eq? car cdr))                            ; distinct primitives stay distinct
     (eq? (car (list car)) car))                    ; through a call
