;; expect: 7
;; C02, the compiler's own synthesized references: call/cc compiles to a
;; call to the prelude procedure `$escape', by bare symbol, and a lexical
;; `$escape' in scope captures it.  Chez: 7.  Today: mine.
(import (rnrs))
(display (let (($escape (lambda (k) 'mine))) (call/cc (lambda (k) (k 7)))))
