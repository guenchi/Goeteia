;; expect: ((1 2) mine)
;; REGRESSION GUARD (written as a red witness at 7cab94e; green since),
;; silent: a library body's WRITTEN reference to a prelude name binds to
;; the PROGRAM's redefinition of that name. The program excludes append
;; and defines its own; the library (u) uses the prelude's append and
;; must keep it, but item 2 core only rewrote the prelude's own
;; references and the tokens the compiler/templates introduce -- a
;; plainly written `append' in a library body is neither, so it follows
;; the program's. Same family as defect-prelude-procedure-excluded's
;; macro row, with a direct reference instead of a template. Chez ((1 2)
;; mine); goeteia gives (mine mine). The keyed-exports redesign fixes it
;; by construction: the library's reference resolves to the origin's
;; key.
(import (except (rnrs) append))
(begin
  (library (u) (export lst) (import (rnrs)) (define (lst a b) (append a b)))
  (import (u)))
(define (append . xs) (quote mine))
(display (list (lst (list 1) (list 2)) (append)))
