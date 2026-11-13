;; expect: #t
;; R6RS names goeteia did not bind (ledger R20, batch R20b):
;; an endianness that is neither big nor little raises, and the integer list
;; conversions raise when the length is not a multiple of the size (both were
;; accepted silently when the names first arrived).
;;
;; Each row is an expression and the answer Chez 10 gives for it in (rnrs),
;; compared as a value.  A row that raises here answers `raised'.  A row
;; with a comment above it pins goeteia's own answer where its domain is
;; narrower than R6RS's.
;;
;; ON THE TREE BEFORE THE CHANGE this file does not compile: the names are
;; unbound.
(import (rnrs))

(define fails '())
(define (want row got expect)
  (unless (equal? got expect)
    (set! fails (cons (list row 'got got 'want expect) fails))))

(want 1
      (guard (c (#t 'raised))
        (guard (c (#t 'raised)) (bytevector-u16-ref (u8-list->bytevector '(1 2)) 0 'bgi)))
      'raised)
(want 2
      (guard (c (#t 'raised))
        (guard (c (#t 'raised)) (let ((b (make-bytevector 2 0))) (bytevector-u16-set! b 0 1 'middle) (bytevector->u8-list b))))
      'raised)
(want 3
      (guard (c (#t 'raised))
        (guard (c (#t 'raised)) (bytevector-uint-ref (u8-list->bytevector '(1 2 3)) 0 'network 3)))
      'raised)
(want 4
      (guard (c (#t 'raised))
        (guard (c (#t 'raised)) (bytevector->uint-list (u8-list->bytevector '(1 2 3)) (endianness big) 2)))
      'raised)
(want 5
      (guard (c (#t 'raised))
        (guard (c (#t 'raised)) (bytevector->sint-list (u8-list->bytevector '(1 2 3 4 5)) (endianness little) 4)))
      'raised)
(want 6
      (guard (c (#t 'raised))
        (list (bytevector->uint-list (u8-list->bytevector '(1 2 3 4)) (endianness big) 2) (bytevector->uint-list (u8-list->bytevector '()) (endianness big) 2) (bytevector-u16-ref (u8-list->bytevector '(1 2)) 0 (endianness little)) (bytevector-u16-ref (u8-list->bytevector '(1 2)) 0 'big)))
      '((258 772) () 513 258))

(display (if (null? fails) #t (reverse fails)))
