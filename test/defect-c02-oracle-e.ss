;; expect: mine
;; C02, variant e, the negative twin of variant d: a library that
;; DEFINES its own car must mean its own, not the primitive.  This is
;; what stands between "protect the import" and "steal the library's
;; own name", and it is green today and must stay green.
;;
;; The import excludes car on purpose.  A first version imported (rnrs)
;; whole and defined car anyway; goeteia accepts that and answers
;; `mine', but Chez rejects it -- a library may not redefine a name it
;; imports -- so the expectation had no source outside the thing being
;; tested.  With the exclusion both hosts answer `mine'.
;;
;; The except is for Chez's benefit only.  In this compiler's flat-splice
;; model only/except are advisory (chez-driver.ss, spec-target): the whole
;; library is spliced and dead code elimination prunes the rest, so this
;; cell does NOT test that except is honoured -- an import list here
;; constrains nothing, which is why scope-close resolution is the
;; mechanism and an import-list-driven design would have had nothing to
;; read.
(import (rnrs))
(begin
  (library (orc lib5)
    (export mine)
    (import (except (rnrs) car))
    (define (car x) 'mine)
    (define (mine p) (car p)))
  (import (orc lib5)))
(display (mine '(1)))
