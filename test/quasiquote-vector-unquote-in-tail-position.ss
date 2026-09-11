;; expect: #(0 unquote (+ 1 1))
;; A vector's elements never form an improper "a . ,b" tail the way a
;; list's do, so a trailing unquote symbol is a literal element.  The
;; delegation turns this into the list (0 unquote (+ 1 1)), reads it as
;; the dotted unquote (0 . ,(+ 1 1)), and errors.  Chez: the vector
;; unchanged.
(import (rnrs))
(display `#(0 unquote (+ 1 1)))
