;; expect: #t
;; An inactive unquote-splicing still has to decrement depth for its
;; OPERAND.  In `#(1 `#(,@(list ,(+ 1 1)))) the ,@ is at level 1 and
;; stays a splice form, but the ,(+ 1 1) inside its operand drops to
;; level 0 and IS evaluated, to 2.  Merely leaving the splice unspliced
;; is not enough; the operand's own unquote must fire.  Pinned by
;; STRUCTURE, not printed form: the result still holds quasiquote and
;; unquote-splicing forms, which goeteia prints in full and Chez
;; abbreviates, so a printed oracle would encode the printer.  Chez
;; agrees structurally.
(import (rnrs))
(display (equal? `#(1 `#(,@(list ,(+ 1 1))))
                 (vector 1 (list 'quasiquote
                                 (vector (list 'unquote-splicing (list 'list 2)))))))
