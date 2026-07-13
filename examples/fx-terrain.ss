;; Terrain from a pure height function: mesh-heightmap samples
;; layered sines into a 180x180 grid (normals are the function's own
;; central differences), the shader ramps grass/rock/snow by
;; altitude, and exponential fog folds the far hills into the sky.
;; One mesh, one draw call, no assets.
(import (rnrs) (web js) (web dom) (web gl) (web glsl) (web fx)
        (web mat) (web mesh))

(fx-init! (get-element-by-id "c"))

(define (hills x z)
  (fl+ (fl* 6.0 (fl* (flsin (fl* 0.05 x)) (flcos (fl* 0.04 z))))
       (fl+ (fl* 2.4 (fl* (flsin (fl+ (fl* 0.13 x) 1.7))
                          (flsin (fl* 0.11 z))))
            (fl* 0.9 (fl* (flsin (fl* 0.31 x))
                          (flcos (fl+ (fl* 0.27 z) 0.6)))))))

(define terrain (mesh-heightmap 240.0 240.0 180 180 hills))

(define p
  (fx-program!
   '((attribute vec3 a_pos)
     (attribute vec3 a_normal)
     (uniform mat4 u_mvp)
     (uniform vec3 u_eye)
     (varying vec3 v_n)
     (varying float v_h)
     (varying float v_dist)
     (define (main) void
       (set! gl_Position (* u_mvp (vec4 a_pos (fl 1))))
       (set! v_n a_normal)
       (set! v_h a_pos.y)
       (set! v_dist (distance a_pos u_eye))))
   '((precision mediump float)
     (uniform vec3 u_light)
     (varying vec3 v_n)
     (varying float v_h)
     (varying float v_dist)
     (define (main) void
       ;; altitude ramp: grass, rock, snow
       (local vec3 base (mix (vec3 "0.13" "0.30" "0.11")
                             (vec3 "0.30" "0.26" "0.23")
                             (smoothstep (fl 1) (fl 4) v_h)))
       (set! base (mix base (vec3 "0.85" "0.88" "0.92")
                       (smoothstep (fl 5) (fl 7) v_h)))
       (local float d (max (dot (normalize v_n) u_light) (fl 0)))
       (local vec3 c (* base (+ (fl 0 30) (* (fl 0 70) d))))
       ;; exponential fog toward the sky color
       (local float f (- (fl 1) (exp (- (* v_dist "0.011")))))
       (set! c (mix c (vec3 "0.35" "0.46" "0.62") f))
       (set! gl_FragColor
             (vec4 (pow c (vec3 "0.4545" "0.4545" "0.4545"))
                   (fl 1)))))))

(define vbuf (fx-buffer!))
(define ibuf (fx-buffer!))
(define vbase (fx-alloc! (mesh-vertex-bytes terrain)))
(define ibase (fx-alloc! (mesh-index-bytes terrain)))
(mesh-write! terrain vbase ibase)

(define proj (m4-perspective 0.9 (/ 800.0 600.0) 0.5 400.0))
(define light (v3-normalize (v3 0.5 0.7 0.4)))
(define uploaded #f)

(fx-loop!
 (lambda (t dt)
   ;; clear to the fog color so the horizon dissolves cleanly
   (cmd-clear! 0.63 0.71 0.81 1.0)
   (cmd-depth! #t)
   (let* ((a (fl* 0.05 t))
          (eye (v3 (fl* 70.0 (flsin a)) 24.0 (fl* 70.0 (flcos a))))
          (ahead (v3 (fl* 55.0 (flsin (fl+ a 0.5))) 8.0
                     (fl* 55.0 (flcos (fl+ a 0.5)))))
          (vp (m4-mul proj (m4-look-at eye ahead (v3 0.0 1.0 0.0)))))
     (fx-use! p vbuf)
     (cmd-bind-index! ibuf)
     (unless uploaded
       (cmd-buffer-data! vbase (mesh-vertex-bytes terrain))
       (cmd-index-data! ibase (mesh-index-bytes terrain))
       (set! uploaded #t))
     (fx-uniform! p 'u_mvp vp)
     (fx-uniform! p 'u_eye (v3-x eye) (v3-y eye) (v3-z eye))
     (fx-uniform! p 'u_light (v3-x light) (v3-y light) (v3-z light))
     (cmd-draw-elements! GL-TRIANGLES (mesh-index-count terrain)))))
