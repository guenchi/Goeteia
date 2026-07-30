;; expect: #t
(import (only (math ; comments are whitespace inside import specs
                    utils)
              double)
        (rename ; comments may also precede the nested library name
                (math base)
                (base-two b2)))
(and (= (double 21) 42)
     (= (b2) 2)
     ;; only is advisory in the flat model: triple is still reachable
     (= (triple 5) 15))
