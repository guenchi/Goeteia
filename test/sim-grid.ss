;; expect: #t
;; Which cell a point is in, when the world extends in both directions.
;;
;; Streaming, spatial hashing and chunked worlds all need one answer to
;; "which cell owns this coordinate", and it has to hold at the two
;; places where naive versions break: at negative coordinates, where
;; truncation folds -0.5 and 0.5 into the same cell, and on a cell
;; boundary, where a closed interval gives the point two owners and an
;; object on the seam loads twice or not at all.  Cells are half-open:
;; a point on a boundary belongs to the cell it starts.
(import (rnrs) (sim grid))

(define failed 0)
(define (check name ok)
  (unless ok (set! failed (+ failed 1)) (display "  FAIL ") (display name) (newline)))
(define (refused? who thunk)
  (guard (e (#t (and (error? e) (eq? (condition-who e) who)))) (thunk) #f))

;; ---- positive side ----
(check "a point inside a cell answers that cell"
       (and (= (grid-cell 0.0 32.0) 0)
            (= (grid-cell 31.9 32.0) 0)
            (= (grid-cell 32.0 32.0) 1)
            (= (grid-cell 63.9 32.0) 1)))

;; ---- the negative side, where truncation is wrong ----
;; Truncating toward zero puts -0.5 in cell 0 alongside +0.5, so cell 0
;; is twice as wide as every other cell and cell -1 is never used.
(check "negative coordinates get their own cells"
       (and (= (grid-cell -0.5 32.0) -1)
            (= (grid-cell -32.0 32.0) -1)
            (= (grid-cell -32.1 32.0) -2)
            (= (grid-cell -0.0001 32.0) -1)))
(check "every cell is the same width"
       (let loop ((i -4) (ok #t))
         (if (= i 5)
             ok
             (let* ((lo (grid-origin i 32.0))
                    (hi (grid-origin (+ i 1) 32.0)))
               (loop (+ i 1) (and ok (= (grid-cell lo 32.0) i)
                                  (= (grid-cell (- hi 0.001) 32.0) i)
                                  (= (grid-cell hi 32.0) (+ i 1))))))))

;; ---- a boundary has exactly one owner ----
(check "a point on a seam belongs to the cell it opens"
       (and (= (grid-cell 32.0 32.0) 1)
            (= (grid-cell -32.0 32.0) -1)
            (= (grid-cell 0.0 32.0) 0)))

;; ---- origin and containment agree with each other ----
(check "the origin of a cell is inside it"
       (let loop ((i -3) (ok #t))
         (if (= i 4)
             ok
             (loop (+ i 1) (and ok (= (grid-cell (grid-origin i 32.0) 32.0) i))))))
(check "containment answers what the cell index says"
       (and (grid-in-cell? 1 2 32.0 40.0 70.0)
            (not (grid-in-cell? 1 2 32.0 40.0 63.9))
            (grid-in-cell? -1 -1 32.0 -0.5 -32.0)
            (not (grid-in-cell? 0 0 32.0 -0.5 0.5))))

;; ---- a cell size that makes no sense is refused ----
(check "a size of zero or less is refused"
       (and (refused? 'grid-cell (lambda () (grid-cell 1.0 0.0)))
            (refused? 'grid-cell (lambda () (grid-cell 1.0 -32.0)))
            (refused? 'grid-origin (lambda () (grid-origin 1 0.0)))))

;; ---- integer sizes behave like their flonum selves ----
(check "an integer cell size means the same thing"
       (and (= (grid-cell 33.0 32) 1) (= (grid-cell -1.0 32) -1)))

(display (= failed 0))
(newline)
