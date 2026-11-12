;; expect: (a c)
;; An import may give one keyword another keyword's name, both ways at once:
;; here `when' is if and `if' is when.  The expander resolves a head to the
;; keyword it names once; it used to rewrite the head to the origin's name
;; and resolve that name through the same renaming again, so the swap ended
;; in "cannot call: when".
(import (rename (rnrs) (when if) (if when)))
(display (list (when #t 'a 'b) (if #t 'b 'c)))
