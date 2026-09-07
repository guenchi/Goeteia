;; expect: #t
;; The three-argument twin of primitive-value-arity-1: vector-set! is
;; taken as a value and never called, and nothing else here takes three
;; arguments, so the wrapper's closure type must exist on the strength
;; of the reference alone.
(import (rnrs))
(define f vector-set!)
(procedure? f)
