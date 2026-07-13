;; Eight thousand trees, ONE draw call.  The trunk-and-canopy mesh
;; uploads once; each tree is three per-instance attributes (i_offset,
;; i_tint, i_scale) advancing once per instance -- the whole forest
;; is a single drawElementsInstanced through the command buffer.
;; Needs WebGL 2.
(import (rnrs) (web js) (web dom) (web gl) (web glsl) (web fx)
        (web mat) (web mesh))

(fx-init! (get-element-by-id "c"))

(define N 8000)

;; per-vertex lighting is plenty for flat-shaded boxes; instances
;; only translate and scale, so normals pass through untouched
(define p
  (fx-program!
   '((attribute vec3 a_pos)
     (attribute vec3 a_normal)
     (attribute vec3 i_offset)
     (attribute vec3 i_tint)
     (attribute float i_scale)
     (uniform mat4 u_vp)
     (uniform vec3 u_light)
     (uniform float u_ambient)
     (varying vec3 v_color)
     (define (main) void
       (local vec3 wp (+ (* a_pos i_scale) i_offset))
       (set! gl_Position (* u_vp (vec4 wp (fl 1))))
       (local float d (max (dot a_normal u_light) (fl 0)))
       (set! v_color (* i_tint (+ u_ambient (* d (- (fl 1) u_ambient)))))))
   '((precision mediump float)
     (varying vec3 v_color)
     (define (main) void
       (set! gl_FragColor (vec4 v_color (fl 1)))))))

;; one shared mesh: a tall box reads as a stylized tree
(define tree (mesh-box 0.4 2.0 0.4))
(define vbuf (fx-buffer!))
(define ibuf (fx-buffer!))
(define instbuf (fx-buffer!))
(define vbase (fx-alloc! (mesh-vertex-bytes tree)))
(define ibase (fx-alloc! (mesh-index-bytes tree)))
(mesh-write! tree vbase ibase)

;; the instance stream: offset3 tint3 scale1 = 28 bytes each
(define instbase (fx-alloc! (* N 28)))
(define seed 42)
(define (rnd!)                           ; [0,1)
  (set! seed (remainder (+ (* seed 1103515245) 12345) 2147483648))
  (fl/ (fixnum->flonum (remainder seed 100000)) 100000.0))
(let fill ((i 0))
  (when (< i N)
    (let ((at (+ instbase (* i 28)))
          (g (fl+ 0.35 (fl* 0.5 (rnd!)))))
      (%mem-f32-set! at (fl* 90.0 (fl- (rnd!) 0.5)))       ; x
      (%mem-f32-set! (+ at 4) 0.0)
      (%mem-f32-set! (+ at 8) (fl* 90.0 (fl- (rnd!) 0.5))) ; z
      (%mem-f32-set! (+ at 12) (fl* 0.35 g))               ; tint: greens
      (%mem-f32-set! (+ at 16) g)
      (%mem-f32-set! (+ at 20) (fl* 0.3 g))
      (%mem-f32-set! (+ at 24) (fl+ 0.5 (fl* 1.6 (rnd!))))) ; scale
    (fill (+ i 1))))

;; the ground, drawn plainly under the forest
(define lit (fx-program! mesh-lit-vs mesh-lit-fs))
(define ground (mesh-plane 100.0 100.0))
(define gvbuf (fx-buffer!))
(define gibuf (fx-buffer!))
(define gvbase (fx-alloc! (mesh-vertex-bytes ground)))
(define gibase (fx-alloc! (mesh-index-bytes ground)))
(mesh-write! ground gvbase gibase)

(define proj (m4-perspective 1.0 (/ 800.0 600.0) 0.1 200.0))
(define light (v3-normalize (v3 0.4 0.9 0.3)))
(define uploaded #f)

(fx-loop!
 (lambda (t dt)
   (cmd-clear! 0.07 0.09 0.14 1.0)
   (cmd-depth! #t)
   ;; a slow orbit over the treetops
   (let* ((a (fl* 0.15 t))
          (eye (v3 (fl* 34.0 (flsin a)) 14.0 (fl* 34.0 (flcos a))))
          (vp (m4-mul proj (m4-look-at eye (v3 0.0 0.0 0.0)
                                       (v3 0.0 1.0 0.0)))))
     ;; the ground
     (fx-use! lit gvbuf)
     (cmd-bind-index! gibuf)
     (unless uploaded
       (cmd-buffer-data! gvbase (mesh-vertex-bytes ground))
       (cmd-index-data! gibase (mesh-index-bytes ground)))
     (fx-uniform! lit 'u_mvp vp)
     (fx-uniform! lit 'u_model (m4-identity))
     (fx-uniform! lit 'u_light (v3-x light) (v3-y light) (v3-z light))
     (fx-uniform! lit 'u_ambient 0.3)
     (fx-uniform! lit 'u_color 0.16 0.22 0.18 1.0)
     (cmd-draw-elements! GL-TRIANGLES (mesh-index-count ground))
     ;; the forest: one instanced draw
     (fx-use-instanced! p vbuf instbuf)
     (cmd-bind-index! ibuf)
     (unless uploaded                    ; attribs already captured
       (cmd-bind-buffer! vbuf)           ; their buffers; rebind only
       (cmd-buffer-data! vbase (mesh-vertex-bytes tree))  ; to upload
       (cmd-index-data! ibase (mesh-index-bytes tree))
       (cmd-bind-buffer! instbuf)
       (cmd-buffer-data! instbase (* N 28))
       (set! uploaded #t))
     (fx-uniform! p 'u_vp vp)
     (fx-uniform! p 'u_light (v3-x light) (v3-y light) (v3-z light))
     (fx-uniform! p 'u_ambient 0.35)
     (cmd-draw-elements-instanced! GL-TRIANGLES
                                   (mesh-index-count tree) N))))
