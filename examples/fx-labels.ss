;; 3D text labels: (web typeset) lays the text out (canvas-measurer
;; widths, CJK-aware wrapping), a hidden 2d canvas rasterizes each
;; label once, (gfx sdf) turns the raster into a signed distance
;; field, and the GL side draws camera-facing quads -- the
;; billboard's corners are u_center +/- the camera's right and up,
;; so the quad turns with the view while its anchor stays in the
;; world.  The fragment shader smoothsteps the field around 0.5, so
;; the glyph edges re-sharpen at ANY distance: lean the camera in
;; and the text stays crisp, because the texture stores geometry,
;; not pixels.
(import (rnrs) (web js) (web dom) (gfx gl) (gfx glsl) (gfx fx)
        (gfx mat) (gfx mesh) (gfx sdf) (web typeset)
        (web typeset canvas))

(fx-init! (get-element-by-id "c"))

;; ---- rasterize a label: typeset, paint, upload; world-sized ----
(define FONT "28px system-ui")
(define LINE-H 36.0)
(define measure (canvas-measurer FONT))

(define (make-label! text wrap-px)
  (let* ((p (prepare text measure))
         (lay (layout p wrap-px LINE-H))
         (w (let widest ((ls (layout-lines lay)) (m 1.0))
              (if (null? ls)
                  (fixnum->flonum (%fl->fx (fl+ m 1.0)))
                  (widest (cdr ls) (if (fl<? m (line-width (car ls)))
                                       (line-width (car ls))
                                       m)))))
         (h (layout-height lay))
         (cv (js-method (js-get (js-global) "document")
                        "createElement" "canvas"))
         (tex (fx-texture!)))
    (js-set! cv "width" (%fl->fx (fl+ w 2.0)))
    (js-set! cv "height" (%fl->fx (fl+ h 2.0)))
    (let ((ctx (js-method cv "getContext" "2d")))
      (js-set! ctx "font" FONT)
      (js-set! ctx "textBaseline" "top")
      (js-set! ctx "fillStyle" "#fff")
      (for-each (lambda (ln)                    ; centre each line
                  (js-method ctx "fillText" (line-text ln)
                             (fl/ (fl- w (line-width ln)) 2.0)
                             (fl+ (line-y ln) 1.0)))
                (layout-lines lay)))
    ;; raster -> signed distance field -> texture, all in staging
    (let* ((base (fx-alloc! (* (%fl->fx (fl+ w 2.0))
                               (%fl->fx (fl+ h 2.0)) 4)))
           (wh (sdf-from-canvas! cv base 6.0)))
      (gl-texture-data! tex base (car wh) (cdr wh)))
    ;; 64 canvas px = one world unit
    (vector tex (fl/ (fl+ w 2.0) 64.0) (fl/ (fl+ h 2.0) 64.0))))

;; ---- the billboard program: a unit quad aimed by uniforms ----
(define bill-p
  (fx-program!
   '((attribute vec2 a_pos)                     ; -0.5 .. 0.5
     (uniform mat4 u_vp)
     (uniform vec3 u_center)
     (uniform vec3 u_right)
     (uniform vec3 u_up)
     (uniform vec2 u_size)
     (varying vec2 v_uv)
     (define (main) void
       (local vec3 w (+ u_center
                        (+ (* u_right (* a_pos.x u_size.x))
                           (* u_up (* a_pos.y u_size.y)))))
       (set! v_uv (vec2 (+ a_pos.x (fl 0 50)) (- (fl 0 50) a_pos.y)))
       (set! gl_Position (* u_vp (vec4 w (fl 1))))))
   '((precision mediump float)
     (uniform sampler2D u_tex)
     (uniform vec4 u_color)
     (varying vec2 v_uv)
     (define (main) void
       (local vec4 t (texture2D u_tex v_uv))
       ;; the distance field re-sharpens under magnification
       (local float a (smoothstep (fl 0 44) (fl 0 56) t.a))
       (set! gl_FragColor (vec4 u_color.rgb (* u_color.a a)))))))

(define quad-buf (fx-buffer!))
(define quad-base (fx-alloc! 32))
(let fill ((k 0) (vs '(-0.5 -0.5  0.5 -0.5  -0.5 0.5  0.5 0.5)))
  (unless (null? vs)
    (%mem-f32-set! (+ quad-base (* k 4)) (car vs))
    (fill (+ k 1) (cdr vs))))
(define quad-up #f)

(define (draw-label! lab vp center right up r g b)
  (fx-use! bill-p quad-buf)
  (unless quad-up
    (cmd-buffer-data! quad-base 32)
    (set! quad-up #t))
  (cmd-bind-texture! 0 (vector-ref lab 0))
  (fx-uniform! bill-p 'u_tex 0)
  (fx-uniform! bill-p 'u_vp vp)
  (fx-uniform! bill-p 'u_center (v3-x center) (v3-y center) (v3-z center))
  (fx-uniform! bill-p 'u_right (v3-x right) (v3-y right) (v3-z right))
  (fx-uniform! bill-p 'u_up (v3-x up) (v3-y up) (v3-z up))
  (fx-uniform! bill-p 'u_size (vector-ref lab 1) (vector-ref lab 2))
  (fx-uniform! bill-p 'u_color r g b 1.0)
  (cmd-draw-arrays! GL-TRIANGLE-STRIP 0 4))

;; ---- the scene under the labels ----
(define lit-p (fx-program! mesh-lit-vs mesh-lit-fs))
(define (upload m)
  (let* ((vbuf (fx-buffer!)) (ibuf (fx-buffer!))
         (vbase (fx-alloc! (mesh-vertex-bytes m)))
         (ibase (fx-alloc! (mesh-index-bytes m))))
    (mesh-write! m vbase ibase)
    (vector vbuf ibuf vbase ibase (mesh-vertex-bytes m)
            (mesh-index-bytes m) (mesh-index-count m) #f)))
(define (bind-upload! prog obj)
  (fx-use! prog (vector-ref obj 0))
  (cmd-bind-index! (vector-ref obj 1))
  (unless (vector-ref obj 7)
    (cmd-buffer-data! (vector-ref obj 2) (vector-ref obj 4))
    (cmd-index-data! (vector-ref obj 3) (vector-ref obj 5))
    (vector-set! obj 7 #t)))

(define ground (upload (mesh-plane 18.0 18.0)))
(define ball (upload (mesh-sphere 0.9 32 16)))

;; three markers, each wearing a name; one wrapped paragraph floats
;; over the middle -- typeset breaks it, CJK and all
(define markers
  (list (vector (v3 -3.5 0.9 0.0) (make-label! "阿尔法 Alpha" 400.0)
                (vector 0.95 0.45 0.35))
        (vector (v3 0.0 0.9 -2.0) (make-label! "贝塔 Beta" 400.0)
                (vector 0.40 0.70 0.95))
        (vector (v3 3.5 0.9 0.5) (make-label! "伽马 Gamma" 400.0)
                (vector 0.55 0.85 0.45))))
(define blurb
  (make-label!
   "Every label is typeset in Scheme, rasterized once, and drawn as a camera-facing quad."
   300.0))

(define proj (m4-perspective 0.9 (/ 800.0 600.0) 0.1 100.0))
(define light (v3-normalize (v3 0.5 0.8 0.4)))

(fx-loop!
 (lambda (t dt)
   (cmd-clear! 0.05 0.06 0.10 1.0)
   (cmd-depth! #t)
   (cmd-unbind-texture! 0)
   (let* ((a (fl* 0.25 t))
          (eye (v3 (fl* 9.0 (flsin a)) 4.0 (fl* 9.0 (flcos a))))
          (fwd (v3-normalize (v3-sub (v3 0.0 0.8 0.0) eye)))
          (right (v3-normalize (v3-cross fwd (v3 0.0 1.0 0.0))))
          (up (v3-cross right fwd))
          (vp (m4-mul proj (m4-look-at eye (v3 0.0 0.8 0.0)
                                       (v3 0.0 1.0 0.0)))))
     ;; the solid world
     (bind-upload! lit-p ground)
     (fx-uniform! lit-p 'u_light (v3-x light) (v3-y light) (v3-z light))
     (fx-uniform! lit-p 'u_ambient 0.3)
     (fx-uniform! lit-p 'u_mvp (m4-mul vp (m4-translate 0.0 -0.0 0.0)))
     (fx-uniform! lit-p 'u_model (m4-identity))
     (fx-uniform! lit-p 'u_color 0.32 0.36 0.45 1.0)
     (cmd-draw-elements! GL-TRIANGLES (vector-ref ground 6))
     (for-each
      (lambda (mk)
        (let* ((c (vector-ref mk 0))
               (col (vector-ref mk 2))
               (m (m4-translate (v3-x c) (v3-y c) (v3-z c))))
          (bind-upload! lit-p ball)
          (fx-uniform! lit-p 'u_mvp (m4-mul vp m))
          (fx-uniform! lit-p 'u_model m)
          (fx-uniform! lit-p 'u_color (vector-ref col 0)
                       (vector-ref col 1) (vector-ref col 2) 1.0)
          (cmd-draw-elements! GL-TRIANGLES (vector-ref ball 6))))
      markers)
     ;; the words, over everything solid
     (cmd-blend! 'alpha)
     (for-each
      (lambda (mk)
        (let* ((c (vector-ref mk 0))
               (col (vector-ref mk 2))
               (at (v3 (v3-x c) (fl+ (v3-y c) 1.6) (v3-z c))))
          (draw-label! (vector-ref mk 1) vp at right up
                       (vector-ref col 0) (vector-ref col 1)
                       (vector-ref col 2))))
      markers)
     (draw-label! blurb vp (v3 0.0 4.2 -0.5) right up 0.92 0.94 0.98)
     (cmd-blend! 'off))))
