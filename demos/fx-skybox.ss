;; A skybox and a mirror ball.  The cube map is procedural: six faces
;; of sky gradient with a baked sun, computed as RGBA bytes in a
;; Scheme loop and handed to gl-cubemap!.  The box draws first with
;; the depth test off (translation dies in the w=0 multiply, so the
;; sky never moves); the sphere samples the same cube map along the
;; reflected eye ray.  Needs WebGL 2.
(import (rnrs) (web sx) (web js) (web dom) (web gl) (web glsl)
        (web fx) (web mat) (web mesh))

;; the demo mounts its own canvas where the hero usually lives
(sx-mount (get-element-by-id "live")
  (sx (div (@ (class "hero"))
        (canvas (@ (id "c") (width "720") (height "400")
                   (style "display:block;width:100%;max-width:40em;border-radius:12px"))))))

(fx-init! (get-element-by-id "c"))

;; ---- the sky, baked: gradient + sun, six 64x64 faces ----
(define DIM 64)
(define sun (v3-normalize (v3 0.55 0.45 0.35)))
(define sky-base (fx-alloc! (* 6 DIM DIM 4)))

(define (clamp01 v) (if (fl<? v 0.0) 0.0 (if (fl<? 1.0 v) 1.0 v)))
(define (byte! at v) (%mem-u8-set! at (%fl->fx (fl* (clamp01 v) 255.0))))
(define (mix a b k) (fl+ a (fl* (fl- b a) k)))

;; face i, pixel (s,t) in [0,1] -> the direction it shows
(define (face-dir i a b)                ; a,b in [-1,1]
  (case i
    ((0) (v3 1.0 (fl- 0.0 b) (fl- 0.0 a)))
    ((1) (v3 -1.0 (fl- 0.0 b) a))
    ((2) (v3 a 1.0 b))
    ((3) (v3 a -1.0 (fl- 0.0 b)))
    ((4) (v3 a (fl- 0.0 b) 1.0))
    (else (v3 (fl- 0.0 a) (fl- 0.0 b) -1.0))))

(let face ((i 0))
  (when (< i 6)
    (let pixel ((p 0))
      (when (< p (* DIM DIM))
        (let* ((s (fl/ (fl+ (fixnum->flonum (remainder p DIM)) 0.5) 64.0))
               (t (fl/ (fl+ (fixnum->flonum (quotient p DIM)) 0.5) 64.0))
               (d (v3-normalize
                   (face-dir i (fl- (fl* 2.0 s) 1.0)
                             (fl- (fl* 2.0 t) 1.0))))
               (y (v3-y d))
               (glow (clamp01 (fl/ (fl- (v3-dot d sun) 0.95) 0.05)))
               (k (fl* glow glow))
               (at (+ sky-base (* (+ (* i (* DIM DIM)) p) 4))))
          (if (fl<? y 0.0)              ; below the horizon: ground haze
              (begin
                (byte! at (mix 0.42 0.20 (fl- 0.0 y)))
                (byte! (+ at 1) (mix 0.38 0.17 (fl- 0.0 y)))
                (byte! (+ at 2) (mix 0.33 0.14 (fl- 0.0 y))))
              (begin                    ; sky: horizon up to zenith
                (byte! at (fl+ (mix 0.72 0.16 y) k))
                (byte! (+ at 1) (fl+ (mix 0.80 0.32 y) (fl* k 0.9)))
                (byte! (+ at 2) (fl+ (mix 0.90 0.60 y) (fl* k 0.6)))))
          (%mem-u8-set! (+ at 3) 255))
        (pixel (+ p 1))))
    (face (+ i 1))))

(define sky-map (fx-slot!))
(gl-cubemap! sky-map sky-base DIM)

;; ---- the skybox program: a cube that never moves ----
(define sky-p
  (fx-program!
   '((attribute vec3 a_pos)
     (attribute vec3 a_normal)
     (uniform mat4 u_vp)
     (varying vec3 v_dir)
     (define (main) void
       (set! v_dir a_pos)
       (local vec4 p (* u_vp (vec4 a_pos (fl 0))))
       (set! gl_Position p.xyww)))
   '((precision mediump float)
     (uniform samplerCube u_sky)
     (varying vec3 v_dir)
     (define (main) void
       (set! gl_FragColor (textureCube u_sky v_dir))))))

;; ---- the mirror ball: reflect the eye ray into the sky ----
(define env-p
  (fx-program!
   '((attribute vec3 a_pos)
     (attribute vec3 a_normal)
     (uniform mat4 u_mvp)
     (uniform mat4 u_model)
     (varying vec3 v_n)
     (varying vec3 v_wp)
     (define (main) void
       (set! gl_Position (* u_mvp (vec4 a_pos (fl 1))))
       (set! v_wp (vec3 (* u_model (vec4 a_pos (fl 1)))))
       (set! v_n (vec3 (* u_model (vec4 a_normal (fl 0)))))))
   '((precision mediump float)
     (uniform samplerCube u_sky)
     (uniform vec3 u_eye)
     (varying vec3 v_n)
     (varying vec3 v_wp)
     (define (main) void
       (local vec3 n (normalize v_n))
       (local vec3 e (normalize (- u_eye v_wp)))
       (local vec3 r (reflect (- e) n))
       (local vec4 sky (textureCube u_sky r))
       ;; a hint of fresnel: grazing angles reflect harder
       (local float f (- (fl 1) (max (dot n e) (fl 0))))
       (set! gl_FragColor
             (vec4 (* sky.rgb (+ (fl 0 70) (* (fl 0 45) f)))
                   (fl 1)))))))

(define lit-p (fx-program! mesh-lit-vs mesh-lit-fs))

;; ---- geometry ----
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

(define cube (upload (mesh-box 2.0 2.0 2.0)))
(define ball (upload (mesh-sphere 1.4 48 24)))
(define ground (upload (mesh-plane 40.0 40.0)))

(define proj (m4-perspective 0.9 (/ 720.0 400.0) 0.1 100.0))

(fx-loop!
 (lambda (t dt)
   (cmd-clear! 0.0 0.0 0.0 1.0)
   (let* ((a (fl* 0.15 t))
          (eye (v3 (fl* 9.0 (flsin a)) 2.5 (fl* 9.0 (flcos a))))
          (vp (m4-mul proj (m4-look-at eye (v3 0.0 1.0 0.0)
                                       (v3 0.0 1.0 0.0)))))
     ;; the sky first, depth off; w=0 already erased the translation
     (cmd-depth! #f)
     (bind-upload! sky-p cube)
     (cmd-bind-cubemap! 0 sky-map)
     (fx-uniform! sky-p 'u_sky 0)
     (fx-uniform! sky-p 'u_vp vp)
     (cmd-draw-elements! GL-TRIANGLES (vector-ref cube 6))
     ;; the world on top
     (cmd-depth! #t)
     (bind-upload! lit-p ground)
     (fx-uniform! lit-p 'u_mvp (m4-mul vp (m4-translate 0.0 -0.4 0.0)))
     (fx-uniform! lit-p 'u_model (m4-translate 0.0 -0.4 0.0))
     (fx-uniform! lit-p 'u_light (v3-x sun) (v3-y sun) (v3-z sun))
     (fx-uniform! lit-p 'u_ambient 0.35)
     (fx-uniform! lit-p 'u_color 0.34 0.38 0.33 1.0)
     (cmd-draw-elements! GL-TRIANGLES (vector-ref ground 6))
     (bind-upload! env-p ball)
     (cmd-bind-cubemap! 0 sky-map)
     (fx-uniform! env-p 'u_sky 0)
     (fx-uniform! env-p 'u_mvp (m4-mul vp (m4-translate 0.0 1.0 0.0)))
     (fx-uniform! env-p 'u_model (m4-translate 0.0 1.0 0.0))
     (fx-uniform! env-p 'u_eye (v3-x eye) (v3-y eye) (v3-z eye))
     (cmd-draw-elements! GL-TRIANGLES (vector-ref ball 6)))))
