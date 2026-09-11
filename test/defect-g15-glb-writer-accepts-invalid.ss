;; expect: #t
;; REGRESSION GUARD (written as a red witness at 14b8083; green since).
;; The defect as it then was: the GLB writer accepts animation times and
;; material indices that make the file it produces invalid glTF, and
;; says nothing.
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

;; The caller's primitive is (layout vbase vcount ibase icount . options),
;; so the fifth position is icount and NOT the material -- a material is
;; an option key.  This procedure names the fifth position for what it
;; is; the row that used to be called `material-out-of-range' was
;; putting 99 here and testing something else entirely, which is a
;; defect in this file rather than in the writer, and the name is the
;; only thing that was wrong: an index count for an index array that is
;; not there is also invalid, and nothing else was checking it.
(define (write-with times icount)
  (let ((prim (list vlayout vbase 3 #f icount)))
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
(want 'g15-icount-without-an-index-array
      (refuses? (lambda () (write-with (vector 0.0 1.0) 99))) #t)

;; The material really out of range, through the option key it actually
;; travels in.  Written as its own primitive rather than through
;; write-with, because write-with's fifth argument is not this.
(want 'g15-material-out-of-range
      (refuses?
        (lambda ()
          (glb-write! (list (list vlayout vbase 3 #f 0 'material 99))
                      'nodes nodes 'mesh-node 0))) #t)

;; And the control it needs: a material index that DOES name a material
;; must go through, or the row above is satisfied by refusing every
;; material there is.
(want 'g15-CONTROL-material-in-range
      (refuses?
        (lambda ()
          (glb-write! (list (list vlayout vbase 3 #f 0 'material 0))
                      'nodes nodes 'mesh-node 0
                      'materials
                      (list (list #f (cons 1.0 1.0) (vector 0.0 0.0 0.0)
                                  #f #f #f #f #f))))) #f)

;; TWO TIMES THAT ARE DISTINCT IN F64 AND THE SAME IN F32.
;; 1.0 and 1.0 + 2^-30 differ as doubles and collide once rounded to
;; the four bytes an animation input is stored in, so the file would
;; carry two keys at the same instant while the descriptor that
;; produced them looks strictly increasing.
;;
;; This is the row that says WHERE the comparison happens.  A check
;; written on the values as given accepts this pair; the file is what
;; has to be valid, so the check belongs on the side the file sees.
;; Nothing else in this cell can tell the two implementations apart --
;; every other pair here is wrong in f64 as well.
(want 'g15-times-colliding-only-after-quantisation
      (refuses? (lambda () (write-with (vector 1.0 1.0000000009313226) 0))) #t)

;; And its control, which is the same shape one ulp of f32 further out:
;; a pair that survives the rounding must still go through, or the row
;; above is satisfied by a check that refuses everything close.
(want 'g15-CONTROL-times-that-survive-quantisation
      (refuses? (lambda () (write-with (vector 1.0 1.0001) 0))) #f)

(if (null? fails) (display #t) (begin (display fails) (newline)))
