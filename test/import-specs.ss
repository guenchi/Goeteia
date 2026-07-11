;; expect: #t
(import (only (math utils) double)
        (rename (math base) (base-two b2)))
(and (= (double 21) 42)
     (= (b2) 2)
     ;; only is advisory in the flat model: triple is still reachable
     (= (triple 5) 15))
