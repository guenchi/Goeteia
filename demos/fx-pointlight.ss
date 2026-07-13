;; Point-light shadows: a light in the middle of the room casts in
;; every direction at once, so the shadow map is a cube -- six
;; half-float faces (fx-cube-target!) each holding the distance from
;; the light to whatever it sees.  The lit pass samples the cube
;; with the fragment-to-light direction and compares distances.
;; Watch the pillar shadows sweep the floor as the light wanders.
;; Needs WebGL 2.
(import (rnrs) (web sx) (web js) (web dom) (web gl) (web glsl)
        (web fx) (web mat) (web mesh))

;; the demo mounts its own canvas where the hero usually lives
(sx-mount (get-element-by-id "live")
  (sx (div (@ (class "hero"))
        (canvas (@ (id "c") (width "720") (height "480")
                   (style "display:block;width:100%;max-width:40em;border-radius:12px"))))))

(fx-init! (get-element-by-id "c"))

(define FAR 40.0)

;; pass 1 (x6): distance from the light, into a cube face
(define dist-p
  (fx-program!
   '((attribute vec3 a_pos)
     (attribute vec3 a_normal)
     (uniform mat4 u_mvp)
     (uniform mat4 u_model)
     (varying vec3 v_wp)
     (define (main) void
       (set! gl_Position (* u_mvp (vec4 a_pos (fl 1))))
       (set! v_wp (vec3 (* u_model (vec4 a_pos (fl 1)))))))
   '((precision mediump float)
     (uniform vec3 u_lpos)
     (uniform float u_far)
     (varying vec3 v_wp)
     (define (main) void
       (set! gl_FragColor
             (vec4 (/ (distance v_wp u_lpos) u_far)
                   (fl 0) (fl 0) (fl 1)))))))

;; pass 2: point light with attenuation, shadowed by the cube
(define lit-p
  (fx-program!
   '((attribute vec3 a_pos)
     (attribute vec3 a_normal)
     (uniform mat4 u_mvp)
     (uniform mat4 u_model)
     (varying vec3 v_wp)
     (varying vec3 v_n)
     (define (main) void
       (set! gl_Position (* u_mvp (vec4 a_pos (fl 1))))
       (set! v_wp (vec3 (* u_model (vec4 a_pos (fl 1)))))
       (set! v_n (* (mat3 u_model) a_normal))))
   '((precision mediump float)
     (uniform samplerCube u_shadow)
     (uniform vec3 u_lpos)
     (uniform float u_far)
     (uniform vec4 u_color)
     (varying vec3 v_wp)
     (varying vec3 v_n)
     (define (main) void
       (local vec3 dv (- v_wp u_lpos))
       (local float dist (length dv))
       (local float dn (/ dist u_far))
       (local vec4 sv (textureCube u_shadow dv))
       (local float lit (step (- dn "0.01") sv.r))
       (local vec3 l (normalize (- dv)))   ; toward the light
       (local float diff (max (dot (normalize v_n) l) (fl 0)))
       (local float atten (/ (fl 1) (+ (fl 1) (* "0.015"
                                                  (* dist dist)))))
       (local vec3 base (pow u_color.rgb (vec3 "2.2" "2.2" "2.2")))
       (local vec3 c (* base (+ "0.06"
                                (* (* (* diff lit) atten) "2.4"))))
       (set! gl_FragColor
             (vec4 (pow c (vec3 "0.4545" "0.4545" "0.4545"))
                   u_color.a))))))

;; the bulb itself: unlit, it IS the light
(define glow-p
  (fx-program!
   '((attribute vec3 a_pos)
     (attribute vec3 a_normal)
     (uniform mat4 u_mvp)
     (define (main) void
       (set! gl_Position (* u_mvp (vec4 a_pos (fl 1))))))
   '((precision mediump float)
     (define (main) void
       (set! gl_FragColor (vec4 (fl 1) "0.95" "0.8" (fl 1)))))))

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

(define floor-obj (upload (mesh-plane 70.0 70.0)))
(define pillar (upload (mesh-box 1.4 7.0 1.4)))
(define bulb (upload (mesh-sphere 0.5 16 8)))

(define pillar-models
  (let ring ((k 0) (acc '()))
    (if (= k 10)
        acc
        (let ((a (fl* 0.6283185307179586 (fixnum->flonum k))))
          (ring (+ k 1)
                (cons (m4-translate (fl* 13.0 (flsin a)) 3.5
                                    (fl* 13.0 (flcos a)))
                      acc))))))

(define cube-t (fx-cube-target! 512))

;; the six views out of the light, GL cube-face conventions
(define face-proj (m4-perspective 1.5707963267948966 1.0 0.1 FAR))
(define (face-vp p i)
  (define (look dx dy dz ux uy uz)
    (m4-mul face-proj
            (m4-look-at p (v3-add p (v3 dx dy dz)) (v3 ux uy uz))))
  (case i
    ((0) (look 1.0 0.0 0.0   0.0 -1.0 0.0))
    ((1) (look -1.0 0.0 0.0  0.0 -1.0 0.0))
    ((2) (look 0.0 1.0 0.0   0.0 0.0 1.0))
    ((3) (look 0.0 -1.0 0.0  0.0 0.0 -1.0))
    ((4) (look 0.0 0.0 1.0   0.0 -1.0 0.0))
    (else (look 0.0 0.0 -1.0 0.0 -1.0 0.0))))

(define proj (m4-perspective 0.9 (/ 720.0 480.0) 0.5 200.0))

(define (draw-pillars! prog each)
  (bind-upload! prog pillar)
  (for-each (lambda (m)
              (each m)
              (cmd-draw-elements! GL-TRIANGLES (vector-ref pillar 6)))
            pillar-models))

(fx-loop!
 (lambda (t dt)
   (cmd-depth! #t)
   (let* ((lp (v3 (fl* 5.0 (flsin (fl* 0.7 t)))
                  (fl+ 4.5 (fl* 2.0 (flsin (fl* 1.3 t))))
                  (fl* 5.0 (flcos (fl* 0.7 t)))))
          (a (fl* 0.1 t))
          (eye (v3 (fl* 26.0 (flsin a)) 12.0 (fl* 26.0 (flcos a))))
          (vp (m4-mul proj (m4-look-at eye (v3 0.0 2.0 0.0)
                                       (v3 0.0 1.0 0.0)))))
     ;; unbind the cube first: rendering into faces still bound for
     ;; sampling is a feedback loop Chrome rejects on every draw
     (cmd-unbind-cubemap! 0)
     ;; six distance passes out of the light
     (let face ((i 0))
       (when (< i 6)
         (fx-bind-cube-face! cube-t i)
         (cmd-clear! 1.0 1.0 1.0 1.0)
         (let ((fvp (face-vp lp i)))
           (draw-pillars! dist-p
                          (lambda (m)
                            (fx-uniform! dist-p 'u_mvp (m4-mul fvp m))
                            (fx-uniform! dist-p 'u_model m)
                            (fx-uniform! dist-p 'u_lpos (v3-x lp)
                                         (v3-y lp) (v3-z lp))
                            (fx-uniform! dist-p 'u_far FAR))))
         (face (+ i 1))))
     ;; the room, asking the cube who sees the light
     (fx-bind-canvas!)
     (cmd-clear! 0.03 0.03 0.05 1.0)
     (let ((unis! (lambda (m r g b)
                    (fx-uniform! lit-p 'u_mvp (m4-mul vp m))
                    (fx-uniform! lit-p 'u_model m)
                    (fx-uniform! lit-p 'u_color r g b 1.0))))
       (bind-upload! lit-p floor-obj)
       (cmd-bind-cubemap! 0 (fx-target-texture cube-t))
       (fx-uniform! lit-p 'u_shadow 0)
       (fx-uniform! lit-p 'u_lpos (v3-x lp) (v3-y lp) (v3-z lp))
       (fx-uniform! lit-p 'u_far FAR)
       (unis! (m4-identity) 0.55 0.53 0.5)
       (cmd-draw-elements! GL-TRIANGLES (vector-ref floor-obj 6))
       (draw-pillars! lit-p (lambda (m) (unis! m 0.7 0.55 0.4)))
       ;; the bulb, small and hot
       (bind-upload! glow-p bulb)
       (fx-uniform! glow-p 'u_mvp
                    (m4-mul vp (m4-translate (v3-x lp) (v3-y lp)
                                             (v3-z lp))))
       (cmd-draw-elements! GL-TRIANGLES (vector-ref bulb 6))))))
