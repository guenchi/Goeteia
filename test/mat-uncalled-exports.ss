;; expect: #t
;; What this cell is the only evidence for: five exports of (gfx mat)
;; that had no caller anywhere -- not a library, not a cell -- and the
;; rounding-up in (gfx uastc) that a length gate is built on top of.
;;
;; They were found by the session that wrote them, running mutants
;; against its own commits after doing the same for everyone else's.
;; Its own survivor count came out three times worse than the ones it
;; had been auditing, and it put that in its report rather than only
;; in a message.
;;
;; Every one of these is the same shape: exported, documented, and
;; never executed.  fl-length2 could return the SQUARE and nothing
;; would notice; fl-tau could equal pi; fl-heading could lose the -Z
;; convention the file is written around.
;;
;; The uastc row is not an unused export -- it is a branch.  Block
;; counts round UP, which is the whole reason uastc-level-bytes
;; exists, and every image in the suite is already a multiple of four.
;; A five-pixel image would report sixteen bytes for a level the file
;; stores in sixty-four, and the length gate built on that number
;; would pass a level three quarters short.
(import (rnrs) (gfx mat) (gfx uastc))

(define fails '())
(define (want name got expect)
  (unless (equal? got expect)
    (set! fails (cons (list name 'got got 'want expect) fails))))
(define (near? a b)
  (let ((d (fl- a b)))
    (fl<? (if (fl<? d 0.0) (fl- 0.0 d) d) 1e-9)))

;; The constants, and the relation between them.
(want 'pi-is-pi (near? fl-pi 3.14159265358979) #t)
(want 'tau-is-two-pi (near? fl-tau (fl* 2.0 fl-pi)) #t)

;; A LENGTH, not a squared length.  The name counts components, not
;; powers, and the doc line says "the length of a two-component
;; vector"; 3-4-5 is the pair that tells the two readings apart.
(want 'length2-of-three-four-is-five (near? (fl-length2 3.0 4.0) 5.0) #t)
(want 'dist2-is-the-same-length-between-two-points
      (near? (fl-dist2 1.0 2.0 4.0 6.0) 5.0) #t)

;; The heading convention: zero toward -Z, positive turning toward +X.
;; Both halves are needed -- a sign error passes a test that only looks
;; at -Z, and an axis swap passes one that only looks at the magnitude.
(want 'heading-of-minus-z-is-zero (near? (fl-heading 0.0 -1.0) 0.0) #t)
(want 'heading-of-plus-x-is-a-quarter-turn
      (near? (fl-heading 1.0 0.0) (fl* 0.5 fl-pi)) #t)
(want 'heading-of-plus-z-is-half-a-turn
      (near? (if (fl<? (fl-heading 0.0 1.0) 0.0)
                 (fl- 0.0 (fl-heading 0.0 1.0))
                 (fl-heading 0.0 1.0))
             fl-pi) #t)
(want 'the-origin-answers-zero (near? (fl-heading 0.0 0.0) 0.0) #t)

;; THE ROUNDING IS THE POINT.  A five-by-five image is two blocks by
;; two blocks, not one by one: a size that truncated would say 16 bytes
;; where the file holds 64, and the check built on it would pass a
;; level that is three quarters short.
(want 'a-five-pixel-image-is-two-blocks-square
      (uastc-level-bytes 5 5) 64)
;; CONTROL: an exact multiple is the case where the two readings agree,
;; so a row using only this one would say nothing about the rounding.
(want 'CONTROL-an-exact-multiple-agrees-either-way
      (uastc-level-bytes 8 8) 64)

(display (if (null? fails) #t (reverse fails)))
