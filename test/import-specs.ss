;; expect: #t
(import (rnrs) (only (math ; comments are whitespace inside import specs
                    utils)
              double triple)
        (rename ; comments may also precede the nested library name
                (math base)
                (base-two b2)))
(and (= (double 21) 42)
     (= (b2) 2)
     ;; only is binding: triple is reachable because it is listed.  This
     ;; line used to document the opposite -- "only is advisory in the
     ;; flat model" -- and the import rule made that documentation false.
     (= (triple 5) 15))
