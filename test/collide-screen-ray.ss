;; expect: #t
;; What this cell is the only evidence for: screen-ray, which turns
;; normalised device coordinates and an inverse view-projection into a
;; world-space ray.  It was exported and called by nothing.
;;
;; The matrices here are ones whose answers can be worked out on paper.
;; Building a real inverse view-projection and comparing against a
;; number this code produced would be checking the code against itself,
;; and the arithmetic that would go into producing the expected value
;; is the arithmetic under test.
(import (rnrs) (gfx collide) (gfx mat))

(define fails '())
(define (want name got expect)
  (unless (equal? got expect)
    (set! fails (cons (list name 'got got 'want expect) fails))))
(define (raises? thunk)
  (guard (e ((error? e) #t) (else #f)) (begin (thunk) #f)))
;; Compared here, on whole values; only the answer is printed.  This
;; tree's printer shows twelve places, so a row reporting two flonums
;; can report a difference it cannot show.
(define (near? a b)
  (let ((d (fl- a b)))
    (fl<? (if (fl<? d 0.0) (fl- 0.0 d) d) 1e-9)))
(define (v-near? u v)
  (and (near? (v3-x u) (v3-x v))
       (near? (v3-y u) (v3-y v))
       (near? (v3-z u) (v3-z v))))

;; With the identity, unprojecting (x, y, -1) and (x, y, 1) gives those
;; points unchanged.  So the ray starts on the near plane at the pixel
;; asked for and points along +z, whatever the pixel.
(define I (m4-identity))

(let-values (((o d) (screen-ray I 0.0 0.0)))
  (want 'the-origin-is-the-near-point (v-near? o (v3 0.0 0.0 -1.0)) #t)
  (want 'and-the-direction-runs-near-to-far (v-near? d (v3 0.0 0.0 1.0)) #t))

;; The pixel is carried into the origin and does not bend the
;; direction: a formula that dropped x and y would give the same origin
;; for every pixel.
(let-values (((o d) (screen-ray I 0.5 -0.25)))
  (want 'the-pixel-moves-the-origin (v-near? o (v3 0.5 -0.25 -1.0)) #t)
  (want 'and-not-the-direction (v-near? d (v3 0.0 0.0 1.0)) #t))

;; The direction is a unit vector, which is what makes a returned
;; distance a distance.
(let-values (((o d) (screen-ray I -1.0 1.0)))
  (want 'the-direction-is-normalised
        (near? (flsqrt (v3-dot d d)) 1.0) #t))

;; A matrix that scales z turns the near-to-far span into a longer one,
;; and the direction must come back normalised anyway -- if it did not,
;; the scale would leak into every distance computed from this ray.
(define scale-z
  (let ((m (m4-identity)))
    (vector-set! m 10 4.0)
    m))
(let-values (((o d) (screen-ray scale-z 0.0 0.0)))
  (want 'a-scaled-depth-moves-the-near-point
        (v-near? o (v3 0.0 0.0 -4.0)) #t)
  (want 'and-the-direction-is-still-unit
        (near? (flsqrt (v3-dot d d)) 1.0) #t)
  (want 'and-still-points-forward (v-near? d (v3 0.0 0.0 1.0)) #t))

;; A translation moves where the ray starts without turning it.
(define shifted (m4-translate 3.0 -2.0 0.0))
(let-values (((o d) (screen-ray shifted 0.0 0.0)))
  (want 'a-translated-matrix-moves-the-origin
        (v-near? o (v3 3.0 -2.0 -1.0)) #t)
  (want 'and-leaves-the-direction-alone (v-near? d (v3 0.0 0.0 1.0)) #t))

;; REFUSAL.  A matrix that collapses near and far onto the same point
;; gives no direction at all, and the caller is told rather than handed
;; a NaN or an arbitrary axis.  A ray whose direction is nonsense is
;; the kind of value that travels a long way before it is noticed.
(define flat-z
  (let ((m (m4-identity)))
    (vector-set! m 10 0.0)
    m))
(want 'a-matrix-with-no-depth-is-refused
      (raises? (lambda () (screen-ray flat-z 0.0 0.0))) #t)

;; And its control: the SAME matrix one entry away must still work, so
;; the row above is not satisfied by a screen-ray that refuses matrices
;; it does not recognise.
(define barely
  (let ((m (m4-identity)))
    (vector-set! m 10 0.001)
    m))
(want 'CONTROL-a-nearly-flat-matrix-still-gives-a-ray
      (raises? (lambda () (screen-ray barely 0.0 0.0))) #f)

(display (if (null? fails) #t (reverse fails)))
