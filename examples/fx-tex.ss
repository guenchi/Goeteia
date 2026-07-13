;; Textured, lit meshes: the same parametric geometry, now with the
;; texture coordinates every generator carries, drawn through
;; mesh-tex-vs/-fs (sample * tint * one directional light).  The
;; checkerboard is painted onto a 2d canvas right here -- no asset
;; files -- and uploaded once.
(import (rnrs) (web js) (web dom) (gfx gl) (gfx glsl) (gfx fx)
        (gfx mat) (gfx mesh))

(fx-init! (get-element-by-id "c"))

(define p (fx-program! mesh-tex-vs mesh-tex-fs))

;; an 8x8 checkerboard on a 64px canvas
(define tex (fx-texture!))
(let* ((cv (js-method (js-get (js-global) "document")
                      "createElement" "canvas"))
       (ctx (begin (js-set! cv "width" 64)
                   (js-set! cv "height" 64)
                   (js-method cv "getContext" "2d"))))
  (js-set! ctx "fillStyle" "#e8e4da")
  (js-method ctx "fillRect" 0 0 64 64)
  (js-set! ctx "fillStyle" "#3a5a8c")
  (let cell ((k 0))
    (when (< k 64)
      (let ((cx (remainder k 8)) (cy (quotient k 8)))
        (when (= 1 (remainder (+ cx cy) 2))
          (js-method ctx "fillRect" (* cx 8) (* cy 8) 8 8)))
      (cell (+ k 1))))
  (gl-texture-upload! tex cv))

;; upload once with uvs (stride 32); keep what each draw needs
(define (tex-mesh m)
  (let* ((vbuf (fx-buffer!))
         (ibuf (fx-buffer!))
         (vbase (fx-alloc! (mesh-vertex-bytes-uv m)))
         (ibase (fx-alloc! (mesh-index-bytes m))))
    (mesh-write-uv! m vbase ibase)
    (vector vbuf ibuf vbase ibase
            (mesh-vertex-bytes-uv m) (mesh-index-bytes m)
            (mesh-index-count m))))

(define ground (tex-mesh (mesh-plane 14.0 14.0)))
(define crate (tex-mesh (mesh-box 2.0 2.0 2.0)))
(define ball (tex-mesh (mesh-sphere 1.2 32 24)))

(define (draw! obj model r g b)
  (fx-use! p (vector-ref obj 0))
  (cmd-buffer-data! (vector-ref obj 2) (vector-ref obj 4))
  (cmd-bind-index! (vector-ref obj 1))
  (cmd-index-data! (vector-ref obj 3) (vector-ref obj 5))
  (fx-uniform! p 'u_mvp (m4-mul vp model))
  (fx-uniform! p 'u_model model)
  (fx-uniform! p 'u_color r g b 1.0)
  (cmd-draw-elements! GL-TRIANGLES (vector-ref obj 6)))

(define proj (m4-perspective 0.9 (/ 800.0 600.0) 0.1 100.0))
(define view (m4-look-at (v3 0.0 3.5 9.0) (v3 0.0 0.5 0.0) (v3 0 1 0)))
(define vp (m4-mul proj view))
(define light (v3-normalize (v3 0.5 0.8 0.4)))

(fx-loop!
 (lambda (t dt)
   (cmd-clear! 0.05 0.06 0.10 1.0)
   (cmd-depth! #t)
   (cmd-use-program! (fx-program-slot p))
   (cmd-bind-texture! 0 tex)
   (fx-uniform! p 'u_tex 0)
   (fx-uniform! p 'u_light (v3-x light) (v3-y light) (v3-z light))
   (fx-uniform! p 'u_ambient 0.25)
   (draw! ground (m4-translate 0.0 -1.6 0.0) 0.8 0.85 0.9)
   (draw! crate
          (m4-mul (m4-translate -1.9 0.4 0.0)
                  (m4-rotate-y (fl* 0.7 t)))
          1.0 0.9 0.8)
   (draw! ball
          (m4-mul (m4-translate 2.1 0.4 0.0)
                  (m4-rotate-y (fl- 0.0 t)))
          0.9 1.0 0.9)))
