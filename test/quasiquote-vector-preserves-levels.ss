;; expect: #t
;; A GUARD on level tracking, and it pins the STRUCTURE, not the printed
;; form.  An inner VECTOR under another quasiquote -- `#(1 `#(,(+ 1 1)))
;; -- reaches the vector clause at level 1, where the ,(+ 1 1) must NOT
;; be evaluated but preserved as an (unquote (+ 1 1)) form.  Green on the
;; unfixed expander too (there the whole vector is literal) and green on
;; a correct fix; it goes red only under a fix that walks the vector but
;; drops the level, evaluating (+ 1 1) to 2.
;;
;; The comparison is equal? against a consed expectation, deliberately
;; NOT (display ...) of an expected string.  goeteia's printer does not
;; abbreviate quasiquote/unquote and Chez's does, so a printed-form
;; oracle would encode goeteia's printer as if it were the semantics --
;; the artifact that nearly made a correct positive-level result look
;; like a defect.  A result that still holds an unevaluated quasiquote
;; form has to be checked by structure.
(import (rnrs))
(display (equal? `#(1 `#(,(+ 1 1)))
                 (vector 1 (list 'quasiquote (vector (list 'unquote (list '+ 1 1)))))))
