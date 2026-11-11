;; expect: #t
;; A full region at ANY word of a frame, the error caught, the words
;; before it dropped or flushed, and the frame encoded again: the frame
;; draws exactly what it draws when nothing stopped it (R40: archive/
;; goeteia-r40-design-2026-11-09.md, R0b in 3.1 and 3.3; row SW of
;; section 4).
;;
;; THE DEFECT.  Some sites changed their record, or the state their
;; check reads, BEFORE encoding the words the record describes: the VAO
;; cache recorded a new entry before its attribute setup; a scene
;; instance group recorded its camera key, generation and count before
;; the upload; a glTF morph cleared its dirty flag before its upload.  A
;; full region between the change and the words left a changed record
;; whose words never ran -- and a flush of the whole commands before the
;; stop makes that record's old stamp look delivered.  Measured on the
;; tree before the change: 75 of 91 stop points of a scene frame drew
;; wrong (archive/goeteia-r40-2026-11-09/probe/region-limit-series.ss).
;; THE RULE (R0b).  A site that changes a record before its words first
;; stores #f in the record's stamp, and stamps it after the words.
;;
;; The frame uses every site: a program's uniform and its VAO (one
;; buffer used before, one new to the frame), a mesh used before and one
;; new to the frame, a scene with a single node and an instance group of
;; two and a scene new to the frame, a glTF primitive with a morph and
;; one new to the frame, a particle pool.  The subjects new to the frame
;; are established inside it, so a site that stamps its record before
;; its words (against R0a) is caught as well.  A complete first
;; frame comes before it; then the camera moves, a group node changes
;; colour (so the group's packed records change), the morph weights
;; change and a particle is emitted.  For every word position k of the
;; frame, twice -- (a) the words before k dropped by cmd-begin!, (b) the
;; whole commands before k flushed -- on a fresh world each time: the
;; limit k set before the frame's cmd-begin!, the error caught, the limit
;; restored, (a) or (b), then the frame again, flushed.  Each draw of
;; that last frame must read what the same frame reads in a world whose
;; region fits it: the same uniform values, and attribute and element
;; buffers of the same length and contents (test/lib/glstate.ss hashes
;; them at bufferData).
;;
;; Rejects the tree before the change, and a site that changes its
;; record before its words without storing #f first (the VAO entry, the
;; instance group, the morph).
(import (rnrs) (web js) (gfx gl) (gfx fx) (gfx mat) (gfx mesh) (gfx scene)
        (gfx gltf) (gfx glb) (gfx particles) (web reactive) (glstate))

(define wide 65536)
(define (try thunk) (guard (e (#t 'raised)) (thunk) 'returned))

;; ---- the world, made anew for every run ----
(define (fill-verts! base vcount stride)
  (let vert ((v 0))
    (when (< v vcount)
      (let slot ((c 0))
        (when (< c (quotient stride 4))
          (%mem-f32-set! (+ base (* v stride) (* 4 c))
                         (+ (* 8.0 (fixnum->flonum v)) (* 0.25 (fixnum->flonum c))))
          (slot (+ c 1))))
      (vert (+ v 1)))))
(define (u16-indices! base is)
  (let loop ((l is) (k 0))
    (unless (null? l)
      (%mem-u8-set! (+ base (* 2 k)) (remainder (car l) 256))
      (%mem-u8-set! (+ base (* 2 k) 1) (quotient (car l) 256))
      (loop (cdr l) (+ k 1)))))
(define (filled-buffer seed)
  (let ((b (fx-buffer!)) (at (fx-alloc! 64)))
    (let fill ((i 0))
      (when (< i 16)
        (%mem-f32-set! (+ at (* 4 i)) (+ seed (* 0.5 (fixnum->flonum i))))
        (fill (+ i 1))))
    (cmd-begin!) (cmd-bind-buffer! b) (cmd-buffer-data! at 64) (cmd-flush!)
    b))

;; #(program buffer-a buffer-b lit mesh-a mesh-b scene fov red asset pool
;;   scene-b asset-b)
(define (world)
  (fx-init! (glstate-canvas 64 64))
  (let* ((p (fx-program! '((attribute vec2 a_pos) (attribute vec2 a_uv)
                           (define (main) void
                             (set! gl_Position (vec4 (+ a_pos a_uv) (fl 0) (fl 1)))))
                         '((precision mediump float) (uniform float u_k)
                           (define (main) void
                             (set! gl_FragColor (vec4 u_k (fl 0) (fl 0) (fl 1)))))))
         (ba (filled-buffer 1.0))
         (bb (filled-buffer 50.0))
         (lit (fx-program! mesh-lit-vs mesh-lit-fs))
         (ma (fx-mesh! (mesh-box 1.0 1.0 1.0)))
         (mb (fx-mesh! (mesh-box 0.5 1.5 0.5)))
         (fov (signal 0.9))
         (red (signal 0.0))
         (sc (sgl (camera (@ (fov ,(signal-ref fov)) (position 0.0 0.0 10.0)
                             (look-at 0.0 0.0 0.0)))
                  (light (@ (direction 0.0 1.0 0.0) (ambient 0.25)))
                  (mesh (@ (geometry (box 1 1 1)) (position 0.0 2.0 0.0)
                           (color 1.0 0.0 0.0)))
                  (mesh (@ (geometry (box 2 2 2)) (position -2.0 0.0 0.0)
                           (color-r ,(signal-ref red)) (color-g 1.0) (color-b 0.0)))
                  (mesh (@ (geometry (box 2 2 2)) (position 2.0 0.0 0.0)
                           (color-r 0.0) (color-g 1.0) (color-b 0.0)))))
         (vb (fx-alloc! (* 4 24)))
         (ib (fx-alloc! 12)))
    (fill-verts! vb 4 24)
    (u16-indices! ib '(0 1 2 2 1 3))
    (let* ((loc (glb-write!
                 (list (list '(position normal) vb 4 ib 6
                             'targets (list (list (vector 1.0 0.0 0.0 1.0 0.0 0.0
                                                          1.0 0.0 0.0 1.0 0.0 0.0) #f #f))
                             'weights '(0.0)))))
           (asset (gltf-parse (car loc) (cdr loc)))
           (pool (make-particles 64))
           (sc2 (sgl (camera (@ (fov 0.8) (position 0.0 1.0 8.0) (look-at 0.0 0.0 0.0)))
                     (light (@ (direction 0.0 1.0 0.0) (ambient 0.25)))
                     (mesh (@ (geometry (box 1 2 1)) (position 0.0 0.0 0.0)
                              (color 0.0 0.0 1.0)))))
           (loc2 (glb-write! (list (list '(position normal) vb 4 ib 6))))
           (asset2 (gltf-parse (car loc2) (cdr loc2))))
      (vector p ba bb lit ma mb sc fov red asset pool sc2 asset2))))

;; the frame.  first? = the complete first frame, which uses only what
;; the swept frame finds already established
(define (frame! w first?)
  (let ((p (vector-ref w 0)) (lit (vector-ref w 3)))
    (fx-use! p (vector-ref w 1))
    (fx-uniform! p 'u_k (if first? 0.25 0.5))
    (cmd-draw-arrays! GL-TRIANGLES 0 3)
    (unless first?
      (fx-use! p (vector-ref w 2))
      (fx-uniform! p 'u_k 0.5)
      (cmd-draw-arrays! GL-TRIANGLES 0 3))
    (fx-mesh-use! lit (vector-ref w 4)) (fx-mesh-draw! (vector-ref w 4))
    (unless first?
      (fx-mesh-use! lit (vector-ref w 5)) (fx-mesh-draw! (vector-ref w 5)))
    (sgl-draw! (vector-ref w 6))
    (unless first? (sgl-draw! (vector-ref w 11)))
    (gltf-draw! (vector-ref w 9) lit (m4-identity))
    (unless first? (gltf-draw! (vector-ref w 12) lit (m4-identity)))
    (particles-draw! (vector-ref w 10) (m4-identity))))

(define (changes! w)
  (signal-set! (vector-ref w 7) 0.95)
  (signal-set! (vector-ref w 8) 0.5)
  (gltf-weights! (car (gltf-prims (vector-ref w 9))) '(1.0))
  (particle-emit! (vector-ref w 10) 0.0 0.0 0.0 0.0 1.0 0.0 1.0 1.0 1.0 2.0 4.0 0.0))

;; a world after its complete first frame and the changes
(define (prepared)
  (let ((w (world)))
    (cmd-begin!) (frame! w #t) (cmd-flush!)
    (changes! w)
    w))

;; the frame in a world whose region fits it: its size, and its draws
(define reference
  (let ((w (prepared)))
    (cmd-begin!) (frame! w #f)
    (let ((size (cmd-pos)))
      (glstate-reset!) (cmd-flush!)
      (cons size (glstate-draws)))))
(define size (car reference))
(define want-draws (cdr reference))

(define wrong '())
(define tried 0)
;; a replay that raises (the tree before the change replays half
;; commands) is a wrong run, counted, and the sweep goes on
(define (flush) (glstate-attempt (lambda () (cmd-flush!))))
(define (run k flush?)
  (let ((w (prepared)))
    (cmd-region! 0 k)
    (cmd-begin!)
    (let* ((r (try (lambda () (frame! w #f))))
           (r2 (begin (cmd-region! 0 wide)
                      (if flush? (flush) (begin (cmd-begin!) "ok"))))
           (r3 (begin (cmd-begin!) (frame! w #f) (glstate-reset!) (flush))))
      (set! tried (+ tried 1))
      (unless (and (eq? r 'raised) (equal? r2 "ok") (equal? r3 "ok")
                   (equal? (glstate-draws) want-draws))
        (set! wrong (cons (list k (if flush? 'flushed 'dropped) r2 r3) wrong))))))

(let sweep ((k 0))
  (when (< k size)
    (run k #f)
    (run k #t)
    (sweep (+ k 4))))

(display (if (and (null? wrong) (= tried (* 2 (quotient size 4))) (> size 400)
                  (> (length want-draws) 9))
             #t
             (list 'size size 'draws (length want-draws) 'tried tried
                   'wrong (length wrong) (list-tail (reverse wrong)
                                                    (max 0 (- (length wrong) 12))))))
