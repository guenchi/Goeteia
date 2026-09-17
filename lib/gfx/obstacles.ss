;; Copyright 2026 guenchi
;; SPDX-License-Identifier: Apache-2.0
;;
;; Continuous sphere queries against static yawed boxes and upright
;; capsules.  Response and the rules for applying it are not part of
;; this library.
(library (gfx obstacles)
  (export obstacle-box obstacle-capsule obstacle-id obstacle-material make-obstacle-index obstacle-sweep
          segment-capsule-entry)
  (import (rnrs) (gfx mat) (prefix (gfx collide) col:))
  ;; Static collision proxies.  The spatial grid comes from
  ;; (gfx collide); the metadata is the caller's to interpret.
  (define ($obs-clamp x lo hi) (max lo (min hi x)))
  ;; #(id material center cos-yaw sin-yaw shape dimensions bounds)
  (define (obstacle-id o) (vector-ref o 0))
  (define (obstacle-material o) (vector-ref o 1))
  (define ($obs-finite? x) (and (real? x) (= (- x x) 0.0)))
  (define ($obs-identity id material)
    (unless (and (string? id) (> (string-length id) 0) (symbol? material)) (error 'obstacle "invalid identity or material")))
  (define ($obs-numbers xs)
    (unless (let loop ((xs xs)) (or (null? xs) (and ($obs-finite? (car xs)) (loop (cdr xs)))))
      (error 'obstacle "non-finite geometry")))
  (define (obstacle-box id material x y z sx sy sz yaw)
    ($obs-identity id material) ($obs-numbers (list x y z sx sy sz yaw))
    (unless (and (> sx 0.0) (> sy 0.0) (> sz 0.0)) (error 'obstacle-box "positive dimensions required"))
    (let* ((c (cos yaw)) (s (sin yaw)) (hx (/ sx 2.0)) (hy (/ sy 2.0)) (hz (/ sz 2.0))
           (rx (+ (* (abs c) hx) (* (abs s) hz))) (rz (+ (* (abs s) hx) (* (abs c) hz))))
      (vector id material (v3 x y z) c s 'box (vector hx hy hz)
        (cons (vector (- x rx) (- y hy) (- z rz)) (vector (+ x rx) (+ y hy) (+ z rz))))))
  ;; bottom and top are the capsule AXIS endpoints, not the outer
  ;; surface.  A sphere is the case where the two are equal.
  (define (obstacle-capsule id material x z radius bottom top)
    ($obs-identity id material) ($obs-numbers (list x z radius bottom top))
    (unless (and (> radius 0.0) (<= bottom top)) (error 'obstacle-capsule "invalid capsule"))
    (vector id material (v3 x 0.0 z) 1.0 0.0 'capsule (v3 radius bottom top)
      (cons (vector (- x radius) (- bottom radius) (- z radius))
            (vector (+ x radius) (+ top radius) (+ z radius)))))
  (define ($obs-first-root a b c)
    (and (> a 0.000000001)
      (let ((d (- (* b b) (* a c))))
        (and (>= d 0.0) (let ((t (/ (- (- b) (sqrt d)) a))) (and (<= 0.0 t) (<= t 1.0) t))))))
  (define ($obs-entry p q radius bottom top)
    (let* ((d (v3-sub q p)) (x (vector-ref p 0)) (y (vector-ref p 1)) (z (vector-ref p 2))
           (dx (vector-ref d 0)) (dy (vector-ref d 1)) (dz (vector-ref d 2))
           (nearest ($obs-clamp y bottom top)) (rr (* radius radius)) (best #f))
      (if (<= (+ (* x x) (* z z) (* (- y nearest) (- y nearest))) rr) 0.0
        (begin
          (let ((t ($obs-first-root (+ (* dx dx) (* dz dz)) (+ (* x dx) (* z dz)) (- (+ (* x x) (* z z)) rr))))
            (when (and t (<= bottom (+ y (* dy t))) (<= (+ y (* dy t)) top)) (set! best t)))
          (for-each (lambda (height)
            (let* ((r (vector x (- y height) z)) (t ($obs-first-root (v3-dot d d) (v3-dot r d) (- (v3-dot r r) rr))))
              (when (and t (or (not best) (< t best))) (set! best t)))) (list bottom top)) best))))
  (define ($obs-point p)
    (unless (and (vector? p) (= (vector-length p) 3))
      (error 'obstacle "a three-component point is required"))
    ($obs-numbers (vector->list p))
    (let ((out (v3 (vector-ref p 0) (vector-ref p 1) (vector-ref p 2))))
      ($obs-numbers (vector->list out)) out))
  (define (segment-capsule-entry p q radius bottom top)
    ($obs-numbers (list radius bottom top))
    (unless (and (>= radius 0.0) (<= bottom top))
      (error 'segment-capsule-entry "invalid capsule"))
    ($obs-entry ($obs-point p) ($obs-point q) radius bottom top))
  (define (make-obstacle-index objects cell)
    ($obs-numbers (list cell))
    (unless (> cell 0.0) (error 'make-obstacle-index "positive cell size required"))
    (let ((by-bounds (make-eq-hashtable)) (ids (make-hashtable string-hash string=?)))
      (for-each (lambda (o)
        (when (hashtable-contains? ids (obstacle-id o)) (error 'make-obstacle-index "duplicate obstacle identity" (obstacle-id o)))
        (hashtable-set! ids (obstacle-id o) #t)
        (hashtable-set! by-bounds (vector-ref o 7) o)) objects)
      (vector (col:make-aabb-grid (map (lambda (o) (vector-ref o 7)) objects) cell) by-bounds)))
  (define ($obs-rotate o p inverse?)
    (let ((c (vector-ref o 3)) (s (* (if inverse? -1.0 1.0) (vector-ref o 4))))
      (vector (- (* c (vector-ref p 0)) (* s (vector-ref p 2))) (vector-ref p 1)
              (+ (* s (vector-ref p 0)) (* c (vector-ref p 2))))))
  (define ($obs-narrow o p q radius)
    (let* ((a ($obs-rotate o (v3-sub p (vector-ref o 2)) #t))
           (b ($obs-rotate o (v3-sub q (vector-ref o 2)) #t))
           (d (v3-sub b a)) (shape (vector-ref o 6))
           (hit (if (eq? (vector-ref o 5) 'box)
             (col:sweep-sphere-aabb a radius d (v3-scale shape -1.0) shape)
             (let ((t ($obs-entry a b (+ radius (vector-ref shape 0)) (vector-ref shape 1) (vector-ref shape 2))))
               (and t (let* ((at (v3-add a (v3-scale d t)))
                            (nearest (vector 0.0 ($obs-clamp (vector-ref at 1) (vector-ref shape 1) (vector-ref shape 2)) 0.0))
                            (delta (v3-sub at nearest)))
                 (cons t (if (> (v3-dot delta delta) 0.000000001) (v3-normalize delta) (v3-normalize (v3-scale d -1.0))))))))))
      ;; Only contacts ENTERING along the normal are reported.
      ;; Leaving, grazing and resting produce no new blocker.
      ;;
      ;; ONE CASE ESCAPES THAT RULE.  A query starting exactly on a
      ;; capsule's axis has no direction to take a normal from, so the
      ;; fallback just above is the reverse of the motion -- which this
      ;; test then always accepts.  Such a sweep reports a contact at
      ;; fraction zero while it is moving OUT: measured on all three
      ;; stages, a sweep from #(0.0 1.0 0.0) to #(2.0 1.0 0.0) with
      ;; radius 0.1 against a capsule on the y axis answers fraction 0.0
      ;; with normal #(-1.0 -0.0 -0.0).  Starting off the axis, inside or
      ;; outside, behaves as stated.
      (and hit (< (v3-dot d (cdr hit)) -0.000000001)
        (let* ((n ($obs-rotate o (cdr hit) #f)) (center (v3-add p (v3-scale (v3-sub q p) (car hit)))))
          (vector (car hit) (v3-sub center (v3-scale n radius)) n o)))))
  ;; #(segment-fraction surface-point outward-normal obstacle).  Hits at
  ;; the same fraction are ordered by the stable id.
  (define (obstacle-sweep index p q radius)
    ($obs-numbers (list radius))
    (unless (>= radius 0.0) (error 'obstacle-sweep "negative query radius"))
    (let* ((p ($obs-point p)) (q ($obs-point q)) (delta (v3-sub q p)) (center (v3-add p (v3-scale delta 0.5)))
           (reach (+ radius (* 0.5 (sqrt (v3-dot delta delta))))) (best #f))
      (for-each (lambda (bounds)
        (let* ((o (hashtable-ref (vector-ref index 1) bounds #f)) (hit ($obs-narrow o p q radius)))
          (when (and hit (or (not best) (< (vector-ref hit 0) (vector-ref best 0))
              (and (= (vector-ref hit 0) (vector-ref best 0))
                   (string<? (obstacle-id o) (obstacle-id (vector-ref best 3)))))) (set! best hit))))
        (col:grid-near (vector-ref index 0) center reach)) best)))
