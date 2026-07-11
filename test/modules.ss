;; expect: #t
(import (math utils))
(and (= (double 21) 42)
     (= (triple 10) 30)
     (= (base-two) 2))
