;; expect: (1 . 2)
;; EXPECTED FAIL, and pre-existing: RED on stage1, and that red is the
;; defect.
;;
;; After the dot, the reader calls only %skip-blanks, so it reaches
;; neither the atmosphere layer that consumes #| and #; nor the hash
;; reader.  A block comment between the tail datum and the close paren
;; is therefore counted as a second item: goeteia refuses with "more
;; than one item found after dot" where Chez answers (1 . 2).
;;
;; Lexical directives inherit it -- `(1 . 2 #!r6rs)` is refused the same
;; way -- but they did not introduce it: the comment form already fails
;; today, which is what makes this pre-existing rather than a
;; regression of the directive work.
;;
;; stage0 PASSES this, being Chez-hosted; only the self-hosted reader
;; refuses it.
(import (rnrs))
(display '(1 . 2 #|c|#))
