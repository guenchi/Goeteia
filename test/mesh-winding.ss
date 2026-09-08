;; expect: #t
;; Every generated triangle must face outward: the normal of the triangle
;; taken in index order has to agree with the vertex normals the generator
;; stored, because a renderer that culls back faces decides by index order
;; alone.  The normals were right and the winding was not, so a sphere and
;; a torus were inside out and a cylinder was half inside out -- visible
;; as a hole where the shape should be, and only where culling is on.
;; Reported by a consumer who had to repair winding after every generator.
(import (rnrs) (gfx mesh))

;; the triangle's own normal, dotted with the first vertex's stored normal
(define (facing m a b c)
  (let* ((vs (mesh-verts m)) (ai (* a 6)) (bi (* b 6)) (ci (* c 6))
         (ux (- (vector-ref vs bi) (vector-ref vs ai)))
         (uy (- (vector-ref vs (+ bi 1)) (vector-ref vs (+ ai 1))))
         (uz (- (vector-ref vs (+ bi 2)) (vector-ref vs (+ ai 2))))
         (vx (- (vector-ref vs ci) (vector-ref vs ai)))
         (vy (- (vector-ref vs (+ ci 1)) (vector-ref vs (+ ai 1))))
         (vz (- (vector-ref vs (+ ci 2)) (vector-ref vs (+ ai 2)))))
    (+ (* (- (* uy vz) (* uz vy)) (vector-ref vs (+ ai 3)))
       (* (- (* uz vx) (* ux vz)) (vector-ref vs (+ ai 4)))
       (* (- (* ux vy) (* uy vx)) (vector-ref vs (+ ai 5))))))

(define (inward-count m)
  (let ((ix (mesh-indices m)))
    (let loop ((i 0) (n 0))
      (if (>= i (vector-length ix))
          n
          (loop (+ i 3)
                (if (< (facing m (vector-ref ix i) (vector-ref ix (+ i 1)) (vector-ref ix (+ i 2)))
                       -0.0000001)
                    (+ n 1)
                    n))))))

(define failed 0)
(define (outward? name m)
  (let ((n (inward-count m)))
    (unless (= n 0)
      (set! failed (+ failed 1))
      (display "  FAIL ") (display name) (display " inward triangles: ") (display n) (newline))))

(outward? 'plane (mesh-plane 2.0 3.0))
(outward? 'box (mesh-box 1.0 1.0 1.0))
(outward? 'box-oblong (mesh-box 2.0 0.5 3.0))
(outward? 'sphere (mesh-sphere 1.0 16 10))
(outward? 'sphere-coarse (mesh-sphere 2.0 7 5))
(outward? 'cylinder (mesh-cylinder 1.0 1.0 12))
(outward? 'cylinder-tall (mesh-cylinder 0.5 4.0 20))
(outward? 'torus (mesh-torus 1.0 0.045 48 6))
(outward? 'torus-fat (mesh-torus 2.0 0.8 16 8))
(outward? 'torus-horn (mesh-torus 1.0 1.0 16 8))       ; radii equal: touches at the axis, still consistent
(outward? 'heightmap (mesh-heightmap 1.0 1.0 8 8 (lambda (x z) 0.0)))
(outward? 'heightmap-bumpy (mesh-heightmap 4.0 4.0 12 9 (lambda (x z) (* 0.25 x z))))

;; A tube wider than the ring intersects itself, so no winding can agree
;; with the normals everywhere; the generator refuses instead of emitting
;; a shape that is inside out in patches.
(define (refused? who thunk)
  (guard (e (#t (and (error? e) (eq? (condition-who e) who))))
    (thunk) #f))
(unless (refused? 'mesh-torus (lambda () (mesh-torus 1.0 2.0 32 16)))
  (set! failed (+ failed 1))
  (display "  FAIL spindle torus was not refused") (newline))

(= failed 0)
