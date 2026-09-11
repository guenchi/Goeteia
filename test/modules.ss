;; expect: #t
(import (rnrs) (math utils) (math base))
(and (= (double 21) 42)
     (= (triple 10) 30)
     (= (base-two) 2))
