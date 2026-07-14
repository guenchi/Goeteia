;; expect: #t
;; a library-internal syntax-rules macro, defined and used in the same
;; library, must expand (regression for collect-macros! descending into
;; library bodies during the top-level macro pre-pass).
(import (rnrs) (tmac lib))
(display (and (= (ml-add 5) 10)
              (= (ml-sq 6) 36)
              (eq? (ml-when0 0) 'zero)
              (eq? (ml-when0 7) 'nonzero)))
(newline)
