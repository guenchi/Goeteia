;; expect: #t
;; A variable names ONE object.  Two references to the same top-level
;; procedure binding must be eq?, whatever form defined it -- R6RS, and
;; what Chez and the JS target already do.  The wasm target wrapped a
;; `(define (f ...) ...)' function in a fresh closure at every reference,
;; so `(eq? f f)' was #f, memq could not find a procedure in a list that
;; held it, and a hashtable could not key on one.  Bindings made with
;; `(define f (lambda ...))', internal defines and let-bound copies
;; were already stable; every shape is pinned here so that fixing one
;; does not unfix another.
(import (rnrs))
(define (top? x) #t)
(define held (lambda (x) #t))
(define (local-test) (define (in? x) #t) (eq? in? in?))
(define (rest . xs) (length xs))          ; variadic: a different closure type
(define (other x) x)
(define table (make-eq-hashtable))
(hashtable-set! table top? 'found)
(and (eq? top? top?)                          ; the same binding, twice
     (eq? held held)
     (let ((f top?)) (eq? f top?))            ; a copy in a variable is the same object
     (let ((f top?) (g top?)) (eq? f g))
     (and (memq top? (list top?)) #t)         ; membership by identity
     (eq? (hashtable-ref table top? 'missing) 'found)   ; keys by identity
     (local-test)
     (eq? rest rest)                          ; the variadic wrapper is one object too
     (let ((r rest)) (and (eq? r rest) (procedure? r)))
     (not (eq? top? held))                    ; distinct bindings stay distinct
     (not (eq? top? other)))                  ; two top-level functions never share
