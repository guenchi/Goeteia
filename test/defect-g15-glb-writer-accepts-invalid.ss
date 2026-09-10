;; expect: #t
;; RED ON PURPOSE: the GLB writer accepts animation times and material
;; indices that make the file it produces invalid glTF, and says
;; nothing.
;;
;;   negative keyframe times    -- the spec requires non-negative
;;   equal adjacent times       -- the spec requires strictly increasing
;;   a material index of 99     -- with no materials in the file
;;
;; The output is a file, and a file outlives the process that wrote
;; it.  Every one of these is caught somewhere downstream -- a viewer,
;; an importer, a validator, someone else's pipeline -- at a point
;; where the information about what produced it is gone.  -> A writer
;; that accepts what it cannot represent moves the diagnosis to whoever
;; is least able to make it.
;;
;; The equal-times case is the one worth writing carefully, and this
;; cell does not test it: times that are DISTINCT in f64 can coincide
;; once quantised to f32, so a check written before the conversion
;; passes input that the file then carries as a duplicate.  Reaching
;; that needs two doubles a float cannot separate, and the cell for it
;; belongs with whoever writes the check -- placed here it would only
;; assert the check exists, which is not the same question.
;;
;; The controls are the same writer call with valid data, because a
;; writer that refused everything would satisfy every red above, and
;; zero as a first keyframe time, which is valid and is exactly what a
;; careless "times must be positive" rule would reject.
(import (rnrs) (gfx glb) (gfx mat) (gfx fx))

(define fails '())
(define (want name got expect)
  (unless (equal? got expect) (set! fails (cons (list name 'got got 'want expect) fails))))
(define (refuses? thunk) (guard (e ((error? e) #t) (else #f)) (begin (thunk) #f)))

(define vlayout '(position))
(define vstride (glb-stride vlayout))
(define vbase (fx-alloc! (* 3 vstride)))
(let fill ((i 0)) (when (< i (* 3 vstride)) (%mem-u8-set! (+ vbase i) 0) (fill (+ i 1))))
(define I (vector 0.0 0.0 0.0 1.0))
(define nodes (list (list "mesh" -1) (list "Root" -1 (v3 0.0 0.0 0.0))))

(define (write-with times material)
  (let ((prim (list vlayout vbase 3 #f material)))
    (glb-write! (list prim) 'nodes nodes 'mesh-node 0
                'anims (list (list "clip"
                                   (list (list 1 'rotation times
                                               (vector I I) 2 'linear)))))))

;; ---- controls first ----
(want 'g15-CONTROL-valid
      (refuses? (lambda () (write-with (vector 0.0 1.0) 0))) #f)
(want 'g15-CONTROL-zero-start
      (refuses? (lambda () (write-with (vector 0.0 0.5) 0))) #f)

;; ---- reds ----
(want 'g15-negative-time
      (refuses? (lambda () (write-with (vector -1.0 1.0) 0))) #t)
(want 'g15-equal-adjacent-times
      (refuses? (lambda () (write-with (vector 1.0 1.0) 0))) #t)
(want 'g15-decreasing-times
      (refuses? (lambda () (write-with (vector 1.0 0.0) 0))) #t)
(want 'g15-material-out-of-range
      (refuses? (lambda () (write-with (vector 0.0 1.0) 99))) #t)

(if (null? fails) (display #t) (begin (display fails) (newline)))
