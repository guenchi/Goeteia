;; expect: #t
;; RED ON PURPOSE: decimating a clip past the sample limit never picks
;; the last key, and the wrong duration then leaks into a resample the
;; caller asked for explicitly.
;;
;; The grid is picked as k = (i * n) / limit for i in [0, limit).  With
;; n = 4097 and limit = 4096 the largest k is (4095 * 4097) / 4096 =
;; 4095, so index 4096 -- the last key -- is unreachable.  The
;; endpoint is not lost to rounding; it is outside the range the
;; formula can produce, for every n greater than the limit.
;;
;; And the damage does not stop at the grid.  The clip's duration is
;; taken as the maximum of the sampled times, so it becomes the
;; second-to-last key's time.  Ask for `samples 2` -- two keys spanning
;; the clip, as explicit as a caller can be -- and the last one still
;; lands at 4095 instead of 4096.  -> A caller who never wanted
;; decimation, and said so, inherits its error.
;;
;; The cells report the time they read, not whether it was right.
;; 4095.0 says the endpoint was dropped; any other number says
;; something else is happening and this file should be re-read rather
;; than believed.
;;
;; The controls are a clip exactly at the limit, which needs no
;; decimation and already ends correctly, and the start of the grid --
;; a fix that forced the last index in while losing the first would
;; satisfy the reds and be just as wrong at the other end.
(import (rnrs) (gfx retarget) (gfx glb) (gfx gltf) (gfx fx) (gfx mat))

(define fails '())
(define (want name got expect)
  (unless (equal? got expect) (set! fails (cons (list name 'got got 'want expect) fails))))

(define vlayout '(position joints weights))
(define vstride (glb-stride vlayout))
(define vbase (fx-alloc! vstride))
(let fill ((i 0)) (when (< i vstride) (%mem-u8-set! (+ vbase i) 0) (fill (+ i 1))))
(%mem-f32-set! (+ vbase 28) 1.0)
(define prim (list vlayout vbase 1 #f 0))
(define I (vector 0.0 0.0 0.0 1.0))
(define nodes (list (list "mesh" -1)
                    (list "Root" -1 (v3 0.0 0.0 0.0))
                    (list "Tip" 1 (v3 0.0 1.0 0.0))))

;; a clip of n keys at t = 0 .. n-1
(define (sampled n opt)
  (let* ((ts (make-vector n)) (vs (make-vector n)))
    (let f ((i 0)) (when (< i n)
                     (vector-set! ts i (exact->inexact i))
                     (vector-set! vs i I) (f (+ i 1))))
    (let* ((anims (list (list "clip" (list (list 2 'rotation ts vs n 'linear)))))
           (loc (glb-write! (list prim) 'nodes nodes 'mesh-node 0
                            'skin (list '(1 2) #f) 'anims anims))
           (g (gltf-parse (car loc) (cdr loc)))
           (names (retarget-glb-node-names loc))
           (clip (apply retarget-clip! g 0 g
                        'src-names names 'dst-names names opt))
           (out (list-ref (car (cadr clip)) 2)))
      out)))
(define (last-of v) (vector-ref v (- (vector-length v) 1)))

;; ---- control: at the limit, no decimation, already correct ----
(let ((v (sampled 4096 '())))
  (want 'g20-CONTROL-at-limit-last (last-of v) 4095.0)
  (want 'g20-CONTROL-at-limit-first (vector-ref v 0) 0.0))

;; ---- red: one key past the limit and the endpoint is unreachable ----
(let ((v (sampled 4097 '())))
  (want 'g20-past-limit-last (last-of v) 4096.0)
  (want 'g20-CONTROL-past-limit-first (vector-ref v 0) 0.0))

;; ---- red: an explicit resample inherits the truncated duration ----
(let ((v (sampled 4097 '(samples 2))))
  (want 'g20-explicit-samples-last (last-of v) 4096.0)
  (want 'g20-CONTROL-explicit-samples-count (vector-length v) 2)
  (want 'g20-CONTROL-explicit-samples-first (vector-ref v 0) 0.0))

(if (null? fails) (display #t) (begin (display fails) (newline)))
