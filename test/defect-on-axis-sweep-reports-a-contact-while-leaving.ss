;; expect: #t
;; A sweep that starts exactly on a capsule's axis segment -- a sphere's
;; centre is the case where the segment is a point -- has nothing to
;; enter, and is not a contact, whichever way it moves.
;;
;; The direction filter keeps only contacts ENTERING along the normal,
;; and the normal is the vector from the nearest point on the axis to
;; the contact point.  A query starting on the axis makes that vector
;; zero; $obs-narrow used to fall back to the reverse of the motion, and
;; the filter, asking whether the motion opposes the normal, always said
;; yes.  A character standing exactly at a pillar's centre could not walk
;; out of it: every step away reported a blocker at fraction zero.  The
;; fallback used to cover every start within about 3.2e-5 of the axis
;; (|delta|^2 <= 1e-9); only an exact zero has no direction now, and
;; every other start is judged by its real geometry.
;;
;; THE ROWS COME IN PAIRS.  A repair that refused every contact near the
;; axis would pass the leaving rows and fail the entering ones: a start
;; a hair off the axis moving TOWARD it goes deeper, and is a contact at
;; fraction zero, as everywhere else inside an obstacle.  A sweep from
;; outside never reaches the fallback (its vector is the sum of the
;; radii), and stays a contact.
;;
;; "Exactly zero" is judged on the largest component, not on the squared
;; length: 1e-200 squared underflows to zero, and a squared length of
;; about 1e-323 normalizes to a vector shorter than one.  A start 1e-200
;; or 5e-324 off the axis moving toward it is a contact with a unit
;; normal, and its surface point lies one query radius out.  Ordinary
;; contacts, from outside or over a cap, keep the normals they had to the
;; last bit.
;;
;; Not judged here: a box's exact centre, where two faces are equally
;; near and the first in a fixed order is taken as the way out, so
;; leaving through the other one reads as a contact.  That normal is not
;; zero; it is a ledger item of its own, and no row pins it either way.
(import (rnrs) (gfx mat) (gfx obstacles))
(define pillar (obstacle-capsule "pillar" 'solid 0.0 0.0 1.0 0.0 2.0))
(define ball (obstacle-capsule "ball" 'solid 0.0 0.0 1.0 1.0 1.0))
(define cube (obstacle-box "cube" 'solid 0.0 1.0 0.0 2.0 2.0 2.0 0.0))
(define (sweep o p q r) (obstacle-sweep (make-obstacle-index (list o) 4.0) p q r))
(define fails '())
(define (want name got expect)
  (unless (equal? got expect) (set! fails (cons (list name 'got got 'want expect) fails))))
(define (near? a b) (< (abs (- a b)) 1e-9))
;; a contact at fraction zero whose normal is (nx ny nz)
(define (contact-at-zero? h nx ny nz)
  (and (vector? h)
       (near? (vector-ref h 0) 0.0)
       (let ((n (vector-ref h 2)))
         (and (near? (vector-ref n 0) nx) (near? (vector-ref n 1) ny)
              (near? (vector-ref n 2) nz)))))

;; ---- THE DEFECT: on the axis segment, nothing to enter ----
(want "leaving from exactly on the axis is not an entering contact"
      (sweep pillar '#(0.0 1.0 0.0) '#(2.0 1.0 0.0) 0.1) #f)
(want "on the axis, leaving along -z"
      (sweep pillar '#(0.0 1.0 0.0) '#(0.0 1.0 -2.0) 0.1) #f)
(want "on the axis, moving along it inside the segment"
      (sweep pillar '#(0.0 1.0 0.0) '#(0.0 1.5 0.0) 0.1) #f)
(want "on the axis, moving along it out through the top"
      (sweep pillar '#(0.0 1.0 0.0) '#(0.0 5.0 0.0) 0.1) #f)
(want "on the axis with a query radius of zero"
      (sweep pillar '#(0.0 1.0 0.0) '#(2.0 1.0 0.0) 0.0) #f)
(want "at the top end of the axis, leaving sideways"
      (sweep pillar '#(0.0 2.0 0.0) '#(2.0 2.0 0.0) 0.1) #f)
(want "at the top end of the axis, leaving upward"
      (sweep pillar '#(0.0 2.0 0.0) '#(0.0 5.0 0.0) 0.1) #f)
(want "at the bottom end of the axis, leaving downward"
      (sweep pillar '#(0.0 0.0 0.0) '#(0.0 -5.0 0.0) 0.1) #f)
(want "at a sphere's centre, leaving along +x"
      (sweep ball '#(0.0 1.0 0.0) '#(2.0 1.0 0.0) 0.1) #f)
(want "at a sphere's centre, leaving along +y"
      (sweep ball '#(0.0 1.0 0.0) '#(0.0 3.0 0.0) 0.1) #f)

;; ---- near the axis: the real geometry, both ways ----
(want "1e-12 off the axis, leaving, is not a contact"
      (sweep pillar '#(1e-12 1.0 0.0) '#(2.0 1.0 0.0) 0.1) #f)
(want "1e-6 off the axis, leaving, is not a contact"
      (sweep pillar '#(1e-6 1.0 0.0) '#(2.0 1.0 0.0) 0.1) #f)
(want "1e-12 off the axis, moving across it, goes deeper: a contact, normal +x"
      (contact-at-zero? (sweep pillar '#(1e-12 1.0 0.0) '#(-2.0 1.0 0.0) 0.1) 1.0 0.0 0.0) #t)
(want "1e-6 off the axis, moving toward it, goes deeper: a contact, normal +x"
      (contact-at-zero? (sweep pillar '#(1e-6 1.0 0.0) '#(-2.0 1.0 0.0) 0.1) 1.0 0.0 0.0) #t)

;; ---- far below the square root of the smallest float ----
(define offset (obstacle-capsule "offset" 'solid 0.3 -0.2 0.75 0.0 2.0))
;; a contact at fraction zero, unit normal (nx ny nz), surface point
;; the start minus 0.1 along the normal
(define (deep-contact? h nx ny nz px py pz)
  (and (contact-at-zero? h nx ny nz)
       (let ((pt (vector-ref h 1)))
         (and (near? (vector-ref pt 0) px) (near? (vector-ref pt 1) py)
              (near? (vector-ref pt 2) pz)))))
(want "1e-200 off the axis, moving toward it: a contact, unit normal"
      (deep-contact? (sweep pillar '#(1e-200 1.0 0.0) '#(-1.0 1.0 0.0) 0.1) 1.0 0.0 0.0 -0.1 1.0 0.0) #t)
(want "5e-324 off the axis, moving toward it: a contact, unit normal"
      (deep-contact? (sweep pillar '#(5e-324 1.0 0.0) '#(-1.0 1.0 0.0) 0.1) 1.0 0.0 0.0 -0.1 1.0 0.0) #t)
(want "2e-162 off the axis, moving toward it: the normal has length one"
      (deep-contact? (sweep pillar '#(2e-162 1.0 0.0) '#(-1.0 1.0 0.0) 0.1) 1.0 0.0 0.0 -0.1 1.0 0.0) #t)
(want "1e-160 off the axis, moving toward it: the normal has length one"
      (deep-contact? (sweep pillar '#(1e-160 1.0 0.0) '#(-1.0 1.0 0.0) 0.1) 1.0 0.0 0.0 -0.1 1.0 0.0) #t)
(want "1e-200 off the axis along z, moving toward it: normal +z"
      (deep-contact? (sweep pillar '#(0.0 1.0 1e-200) '#(0.0 1.0 -1.0) 0.1) 0.0 0.0 1.0 0.0 1.0 -0.1) #t)
(want "1e-200 off the axis, leaving, is not a contact"
      (sweep pillar '#(1e-200 1.0 0.0) '#(1.0 1.0 0.0) 0.1) #f)
(want "1e-16 off an offset capsule's axis on a diagonal: the real direction"
      (contact-at-zero? (sweep offset '#(0.3000000000000001 1.0 -0.2000000000000001) '#(-1.0 1.0 -1.5) 0.1) 0.8 0.0 -0.6) #t)

;; ---- CONTROLS: these answered the same before the repair ----
;; ordinary contacts keep their normals to the last bit
(define (normal-is? h n)
  (and (vector? h)
       (let ((m (vector-ref h 2)))
         (and (= (vector-ref m 0) (vector-ref n 0)) (= (vector-ref m 1) (vector-ref n 1))
              (= (vector-ref m 2) (vector-ref n 2))))))
(want "CONTROL a diagonal sweep from outside keeps its normal exactly"
      (normal-is? (sweep offset '#(-3.0 1.0 -2.5) '#(3.0 1.3 2.0) 0.1)
                  '#(-0.8878977098813433 0.0 -0.4600409294698307)) #t)
(want "CONTROL an oblique sweep from outside keeps its normal exactly"
      (normal-is? (sweep offset '#(-2.0 0.7 1.9) '#(1.5 0.9 -1.7) 0.25)
                  '#(-0.8178208600255011 0.0 0.5754728845976582)) #t)
(want "CONTROL a sweep over the top cap keeps its normal exactly"
      (normal-is? (sweep offset '#(-2.0 3.2 0.1) '#(2.0 2.1 -0.3) 0.1)
                  '#(-0.5550788744090496 0.8202937492860184 0.1378608286173756)) #t)
(want "CONTROL a sweep under the bottom cap keeps its normal exactly"
      (normal-is? (sweep offset '#(1.9 -1.0 -0.6) '#(-1.1 0.4 0.3) 0.2)
                  '#(0.7671370277967521 -0.6246639463051511 -0.1459305820232361)) #t)
(want "CONTROL leaving from just off the axis is not a contact"
      (sweep pillar '#(0.5 1.0 0.0) '#(2.0 1.0 0.0) 0.1) #f)
(want "CONTROL just off the axis, moving deeper, is a contact, normal +x"
      (contact-at-zero? (sweep pillar '#(0.5 1.0 0.0) '#(-2.0 1.0 0.0) 0.1) 1.0 0.0 0.0) #t)
(let ((hit (sweep pillar '#(-3.0 1.0 0.0) '#(3.0 1.0 0.0) 0.1)))
  (want "CONTROL arriving from outside is still a contact, normal -x"
        (and (vector? hit) (> (vector-ref hit 0) 0.0)
             (near? (vector-ref (vector-ref hit 2) 0) -1.0))
        #t))
(want "CONTROL in a cap, on the axis line but past the segment, leaving"
      (sweep pillar '#(0.0 2.5 0.0) '#(0.0 5.0 0.0) 0.1) #f)
(want "CONTROL in a cap, past the segment, moving toward it, normal +y"
      (contact-at-zero? (sweep pillar '#(0.0 2.5 0.0) '#(0.0 1.0 0.0) 0.1) 0.0 1.0 0.0) #t)
(want "CONTROL a zero-length motion on the axis"
      (sweep pillar '#(0.0 1.0 0.0) '#(0.0 1.0 0.0) 0.1) #f)
(want "CONTROL a zero-length motion at a sphere's centre"
      (sweep ball '#(0.0 1.0 0.0) '#(0.0 1.0 0.0) 0.1) #f)
(want "CONTROL off a sphere's centre, leaving"
      (sweep ball '#(0.3 1.0 0.0) '#(2.0 1.0 0.0) 0.1) #f)
(want "CONTROL off a sphere's centre, moving deeper, normal +x"
      (contact-at-zero? (sweep ball '#(0.3 1.0 0.0) '#(-2.0 1.0 0.0) 0.1) 1.0 0.0 0.0) #t)
(want "CONTROL inside a box near a face, leaving through it"
      (sweep cube '#(-0.5 1.0 0.0) '#(-3.0 1.0 0.0) 0.1) #f)
(let ((hit (sweep cube '#(-3.0 1.0 0.0) '#(3.0 1.0 0.0) 0.1)))
  (want "CONTROL a box from outside is a contact"
        (and (vector? hit) (> (vector-ref hit 0) 0.0)) #t))

(display (if (null? fails) #t (reverse fails)))
