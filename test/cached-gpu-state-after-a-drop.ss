;; expect: #t
;; After a frame is dropped, every cached GPU record whose words were
;; dropped is established again where it is next used -- and only those
;; (R40: archive/goeteia-r40-design-2026-11-09.md, 1.3 census and 3.3;
;; rows V1, V2, CV, M1, CM, G1, CG, I1, I2, CI, F1, CF, Mo1, Mo2, P1, CP
;; of section 4, and CMo).
;;
;; THE DEFECT.  Each site below keeps a record "the GPU now holds X" and
;; wrote it when the command making it so was ENCODED.  A command takes
;; effect when a flush replays it; one encoded and then dropped by
;; cmd-begin! never does, and the record kept answering "already there":
;;   V  fx-use!'s VAO cache: the VAO bound with no attribute enabled
;;   M  fx-mesh-use!: the mesh's buffers stay empty
;;   G  a scene node's geometry: the same
;;   I  a scene instance group: the instance buffer stays empty, on the
;;      fast path and on the path that keeps the packed records
;;   F  a glTF primitive: its buffers stay empty
;;   Mo a glTF morph: the GPU keeps the previous morph
;;   P  a particle pool: the GPU keeps the previous pool
;; THE RULE.  A record carries the segment it was written in
;; ((cmd-stamp), taken after its words) and is believed only while
;; (cmd-stamp-holds? stamp).  A dropped segment never holds, so its
;; subjects are established again, once; a flushed one holds, so the
;; same use in a later frame costs nothing.
;;
;; Each drop row is red on the tree before the change; each C row (two
;; flushed frames: established once) rejects a design that drops the
;; caches or invalidates every record at every cmd-begin!.  V1 also
;; rejects a re-emitted setup on a NEW vertex array, V2 one missing the
;; instance part, I2 a stamp checked on the fast path only, Mo2 a morph
;; upload that leaves the record naming the earlier, replayed segment,
;; CMo one that leaves the record cleared after a delivered morph, and P2
;; a pool upload encoded while the encoder is stale that keeps the old
;; record instead of storing what (cmd-stamp) answers then, #f (R0a).
;;
;; Mock: test/lib/glstate.ss.  A draw is judged by what it READS -- the
;; uniform values, the attribute and element buffers' lengths and
;; contents -- against the same draw in a frame where nothing was
;; dropped, made from fresh, identical objects.
(import (rnrs) (web js) (gfx gl) (gfx fx) (gfx mat) (gfx mesh) (gfx scene)
        (gfx gltf) (gfx glb) (gfx particles) (web reactive) (glstate))

(define fails '())
(define (want name got expect)
  (unless (equal? got expect) (set! fails (cons (list name 'got got 'want expect) fails))))

(fx-init! (glstate-canvas 64 64))

;; frames.  (complete thunk): one flushed frame, answering the draws it
;; read.  A row that reads the mock's log binds what it read BEFORE it
;; runs a reference frame: the reference resets the log, and the order in
;; which a call's arguments are evaluated is not fixed.  (after-drop thunk): the same frame encoded and dropped, then
;; encoded again and flushed, answering the draws of the second.
(define (complete thunk)
  (cmd-begin!) (thunk) (glstate-reset!) (cmd-flush!) (glstate-draws))
(define (after-drop thunk)
  (cmd-begin!) (thunk)
  (cmd-begin!) (thunk) (glstate-reset!) (cmd-flush!) (glstate-draws))
;; vertex and index uploads of one flushed frame
(define (uploads-of thunk)
  (cmd-begin!) (thunk) (glstate-reset!) (cmd-flush!) (length (glstate-uploads)))
(define (D) (cmd-draw-arrays! GL-TRIANGLES 0 3))

;; ---- V: the VAO cache ----
(define (vprog)
  (fx-program! '((attribute vec2 a_pos) (attribute vec2 a_uv)
                 (define (main) void (set! gl_Position (vec4 (+ a_pos a_uv) (fl 0) (fl 1)))))
               '((precision mediump float)
                 (define (main) void (set! gl_FragColor (vec4 (fl 1) (fl 0) (fl 0) (fl 1)))))))
(define (iprog)
  (fx-program! '((attribute vec2 a_pos) (attribute vec2 i_offset)
                 (define (main) void (set! gl_Position (vec4 (+ a_pos i_offset) (fl 0) (fl 1)))))
               '((precision mediump float)
                 (define (main) void (set! gl_FragColor (vec4 (fl 1) (fl 0) (fl 0) (fl 1)))))))
;; a buffer holding distinct bytes, so a draw names it by what it holds
(define (filled-buffer seed)
  (let ((b (fx-buffer!)) (at (fx-alloc! 64)))
    (let fill ((i 0))
      (when (< i 16)
        (%mem-f32-set! (+ at (* 4 i)) (+ seed (* 0.5 (fixnum->flonum i))))
        (fill (+ i 1))))
    (cmd-begin!) (cmd-bind-buffer! b) (cmd-buffer-data! at 64) (cmd-flush!)
    b))
(define vbuf (filled-buffer 1.0))
(define ibuf (filled-buffer 100.0))

;; V1: setup encoded after a completed flush and dropped; then a frame
(let* ((p (vprog))
       (ref (complete (lambda () (fx-use! (vprog) vbuf) (D)))))
  (cmd-begin!) (cmd-flush!)
  (let ((vaos (glstate-vaos)))
    (fx-use! p vbuf)
    (cmd-begin!) (fx-use! p vbuf) (D) (glstate-reset!) (cmd-flush!)
    (want "V1 the draw reads its attributes from the buffer" (glstate-draws) ref)
    (want "V1 on the one vertex array made for it" (- (glstate-vaos) vaos) 1)))

;; V2: the same, instanced
(let* ((p (iprog))
       (ref (complete (lambda () (fx-use-instanced! (iprog) vbuf ibuf) (D)))))
  (cmd-begin!) (cmd-flush!)
  (fx-use-instanced! p vbuf ibuf)
  (cmd-begin!) (fx-use-instanced! p vbuf ibuf) (D) (glstate-reset!) (cmd-flush!)
  (want "V2 the draw reads the per-vertex and the per-instance attributes"
        (glstate-draws) ref))

;; CV: two flushed frames
(let ((p (vprog)))
  (complete (lambda () (fx-use! p vbuf) (D)))
  (want "CV the attribute pointers are set in the first frame"
        (glstate-pointers) 2)
  (complete (lambda () (fx-use! p vbuf) (D)))
  (want "CV and not in the second" (glstate-pointers) 0))

;; ---- M: fx-mesh-use! ----
(define lit (fx-program! mesh-lit-vs mesh-lit-fs))
(define (box) (fx-mesh! (mesh-box 1.0 1.0 1.0)))
(define (mesh-frame m) (lambda () (fx-mesh-use! lit m) (fx-mesh-draw! m)))

(let ((m (box)))
  (want "M1 a dropped first use is uploaded in the next frame"
        (after-drop (mesh-frame m)) (complete (mesh-frame (box)))))
(let ((m (box)))
  (want "CM the first flushed frame uploads the mesh" (uploads-of (mesh-frame m)) 2)
  (want "CM the second uploads nothing" (uploads-of (mesh-frame m)) 0))

;; ---- G and I: the scene ----
(define (one-node)
  (sgl (camera (@ (fov 0.9) (position 0.0 0.0 10.0) (look-at 0.0 0.0 0.0)))
       (light (@ (direction 0.0 1.0 0.0) (ambient 0.25)))
       (mesh (@ (geometry (box 1 1 1)) (position 0.0 0.0 0.0) (color 1.0 0.0 0.0)))))
(define (two-nodes fov)
  (sgl (camera (@ (fov ,(signal-ref fov)) (position 0.0 0.0 10.0) (look-at 0.0 0.0 0.0)))
       (light (@ (direction 0.0 1.0 0.0) (ambient 0.25)))
       (mesh (@ (geometry (box 2 2 2)) (position -2.0 0.0 0.0) (color 0.0 1.0 0.0)))
       (mesh (@ (geometry (box 2 2 2)) (position 2.0 0.0 0.0) (color 0.0 1.0 0.0)))))
(define (scene-frame s) (lambda () (sgl-draw! s)))

(let ((s (one-node)))
  (want "G1 a node whose first frame was dropped has its geometry"
        (after-drop (scene-frame s)) (complete (scene-frame (one-node)))))
(let ((s (one-node)))
  (want "CG the first flushed frame uploads the geometry" (uploads-of (scene-frame s)) 2)
  (want "CG the second uploads nothing" (uploads-of (scene-frame s)) 0))

;; I1: the group's first frame dropped; the next frame takes the fast
;; path (nothing moved)
(let ((s (two-nodes (signal 0.9))))
  (want "I1 the instance buffer holds both records on the fast path"
        (after-drop (scene-frame s)) (complete (scene-frame (two-nodes (signal 0.9))))))
;; I2: the camera moves between the dropped frame and the next, both
;; nodes stay visible: the path that keeps the packed records
(let* ((fov (signal 0.9)) (s (two-nodes fov)))
  (cmd-begin!) (sgl-draw! s)
  (signal-set! fov 0.95)
  (cmd-begin!) (sgl-draw! s) (glstate-reset!) (cmd-flush!)
  (let* ((got (glstate-draws))
         (ref (complete (scene-frame (two-nodes (signal 0.95))))))
    (want "I2 the instance buffer holds both records on the path that keeps them"
          got ref)))
(let ((s (two-nodes (signal 0.9))))
  (want "CI the first flushed frame uploads the geometry and the instances"
        (uploads-of (scene-frame s)) 3)
  (want "CI the second uploads nothing" (uploads-of (scene-frame s)) 0))

;; ---- F and Mo: glTF ----
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
(define gvb (fx-alloc! (* 4 24)))
(fill-verts! gvb 4 24)
(define gib (fx-alloc! 12))
(u16-indices! gib '(0 1 2 2 1 3))
(define (asset morph?)
  (let ((loc (glb-write!
              (list (if morph?
                        (list '(position normal) gvb 4 gib 6
                              'targets (list (list (vector 1.0 0.0 0.0 1.0 0.0 0.0
                                                           1.0 0.0 0.0 1.0 0.0 0.0) #f #f))
                              'weights '(0.0))
                        (list '(position normal) gvb 4 gib 6))))))
    (gltf-parse (car loc) (cdr loc))))
(define (gltf-frame g) (lambda () (gltf-draw! g lit (m4-identity))))
(define (morphed weights)
  (let ((g (asset #t)))
    (gltf-weights! (car (gltf-prims g)) weights)
    g))

(let ((g (asset #f)))
  (want "F1 a primitive whose first frame was dropped has its buffers"
        (after-drop (gltf-frame g)) (complete (gltf-frame (asset #f)))))
(let ((g (asset #f)))
  (want "CF the first flushed frame uploads the primitive" (uploads-of (gltf-frame g)) 2)
  (want "CF the second uploads nothing" (uploads-of (gltf-frame g)) 0))

;; Mo1: the weights set before the first frame, which is dropped
(let ((g (morphed '(1.0))))
  (want "Mo1 the morphed vertices are uploaded after the drop"
        (after-drop (gltf-frame g)) (complete (gltf-frame (morphed '(1.0))))))
;; Mo2: drawn once; the weights change and that frame is dropped
(let ((g (asset #t)))
  (complete (gltf-frame g))
  (gltf-weights! (car (gltf-prims g)) '(1.0))
  (want "Mo2 the new morph is uploaded after the drop"
        (after-drop (gltf-frame g)) (complete (gltf-frame (morphed '(1.0))))))
;; CMo: drawn once; the weights change; two flushed frames
(let ((g (asset #t)))
  (complete (gltf-frame g))
  (gltf-weights! (car (gltf-prims g)) '(1.0))
  (want "CMo a changed morph uploads its vertices once" (uploads-of (gltf-frame g)) 1)
  (want "CMo and the next frame uploads nothing" (uploads-of (gltf-frame g)) 0))

;; ---- P: particles ----
(define (emit! f) (particle-emit! f 0.0 0.0 0.0 0.0 1.0 0.0 1.0 1.0 1.0 2.0 4.0 0.0))
(define (pool-frame f) (lambda () (particles-draw! f (m4-identity))))
(define (emitted)
  (let ((f (make-particles 64)))
    (complete (pool-frame f))
    (emit! f)
    f))

(let ((f (emitted)))
  (want "P1 an emit whose frame was dropped is uploaded in the next"
        (after-drop (pool-frame f)) (complete (pool-frame (emitted)))))
;; P2: an emit drawn while the encoder is stale (a region change with the
;; same base), those words dropped, then a frame with no new emit
(let ((f (emitted)))
  (cmd-begin!) (cmd-region! 0 65536)
  (particles-draw! f (m4-identity))
  (cmd-begin!) (particles-draw! f (m4-identity)) (glstate-reset!) (cmd-flush!)
  (let* ((uploads (length (glstate-uploads)))
         (got (glstate-draws))
         (ref (complete (pool-frame (emitted)))))
    (want "P2 a pool drawn while stale and dropped is uploaded in the next frame"
          uploads 1)
    (want "P2 and the draw reads the emit" got ref)))
(let ((f (emitted)))
  (want "CP the first flushed frame after an emit uploads the pool" (uploads-of (pool-frame f)) 1)
  (want "CP the second uploads nothing" (uploads-of (pool-frame f)) 0))

(display (if (null? fails) #t (reverse fails)))
