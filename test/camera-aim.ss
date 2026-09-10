;; expect: #t
;; What this cell is the only evidence for: camera-aim, which was
;; exported, explained in two paragraphs, and called by nothing --
;; not a library, not a cell, not an example.
;;
;; The library says of the pair it belongs to:
;;
;;     THERE ARE TWO LOOK POINTS AND THEY ARE NOT INTERCHANGEABLE ...
;;     camera-aim reads it back unchanged ... Neither mistake raises.
;;
;; Which is the whole difficulty.  A caller that streams the world
;; against the damped point instead of the goal arrives latest exactly
;; when the aim is moving fastest -- it does not raise, it does not go
;; red, it loads the world in the wrong place.
;;
;; So the rows below need their opposite as well: after a placement
;; the two points MUST agree, or a row that finds them different would
;; pass for a camera-aim that returns anything at all.
(import (rnrs) (gfx camera) (gfx mat))

(define fails '())
(define (want name got expect)
  (unless (equal? got expect)
    (set! fails (cons (list name 'got got 'want expect) fails))))
(define (near? a b)
  (let ((d (fl- a b)))
    (fl<? (if (fl<? d 0.0) (fl- 0.0 d) d) 1e-9)))

(define c (make-orbit-camera))
(camera-limits! c 0.08 1.12 4.0 15.0)
(camera-target! c (v3 0.0 1.55 0.0))
(camera-follow! c 0.016)          ; the first step places both outright

;; Now move the anchor and take one short step.  The aim is the new
;; value; the smoothed point is still on its way.
(camera-target! c (v3 10.0 1.55 0.0))
(camera-follow! c 0.016)

(want 'aim-answers-the-goal-that-was-written
      (near? (v3-x (camera-aim c)) 10.0) #t)
(want 'and-the-smoothed-point-has-not-arrived
      (if (fl<? (v3-x (camera-target c)) 10.0) #t #f) #t)
(want 'so-the-two-are-not-the-same-point
      (if (near? (v3-x (camera-aim c)) (v3-x (camera-target c))) #f #t) #t)

;; CONTROL: with no step in between they ARE the same point, so a row
;; that merely found them different would pass for the wrong reason.
(let ((k (make-orbit-camera)))
  (camera-target! k (v3 3.0 0.0 0.0))
  (camera-follow! k 0.016)
  (want 'CONTROL-after-a-placing-step-they-agree
        (near? (v3-x (camera-aim k)) (v3-x (camera-target k))) #t))

(display (if (null? fails) #t (reverse fails)))
