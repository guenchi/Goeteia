;; Uniform buffers: three shapes, three different ESSL 3.00 shaders,
;; ONE block of per-frame state.  The Env uniform block (camera,
;; light, eye, time) uploads once per frame with cmd-ubo-data!; all
;; three programs read it from binding point 0 -- no per-program
;; u_vp/u_light/u_time plumbing at all.  Only u_model stays a
;; classic uniform, because it changes per object.  Needs WebGL 2.
(import (rnrs) (web js) (web dom) (web gl) (web glsl) (web fx)
        (web mat) (web mesh))

(fx-init! (get-element-by-id "c"))

;; the shared block: mat4 + 3 vec4s = 112 bytes of std140
(define env-block
  '(uniform-block Env
                  (mat4 u_vp)
                  (vec4 u_light)          ; xyz = toward the light
                  (vec4 u_eye)
                  (vec4 u_misc)))         ; x = time

(define (make-vs)
  `((attribute vec3 a_pos)
    (attribute vec3 a_normal)
    ,env-block
    (uniform mat4 u_model)
    (varying vec3 v_n)
    (varying vec3 v_wp)
    (define (main) void
      (local vec4 wp (* u_model (vec4 a_pos (fl 1))))
      (set! gl_Position (* u_vp wp))
      (set! v_wp (vec3 wp))
      (set! v_n (vec3 (* u_model (vec4 a_normal (fl 0))))))))

;; three fragment shaders, all reading the same block
(define lit-p
  (fx-program3!
   (make-vs)
   `((precision mediump float)
     ,env-block
     (varying vec3 v_n)
     (varying vec3 v_wp)
     (define (main) void
       (local float d (max (dot (normalize v_n) u_light.xyz) (fl 0)))
       (set! gl_FragColor
             (vec4 (* (vec3 "0.75" "0.45" "0.30")
                      (+ (fl 0 25) (* (fl 0 75) d)))
                   (fl 1)))))))

(define stripe-p
  (fx-program3!
   (make-vs)
   `((precision mediump float)
     ,env-block
     (varying vec3 v_n)
     (varying vec3 v_wp)
     (define (main) void
       (local float d (max (dot (normalize v_n) u_light.xyz) (fl 0)))
       (local float band (+ (fl 0 50)
                            (* (fl 0 50)
                               (sin (+ (* v_wp.y (fl 8)) u_misc.x)))))
       (local vec3 c (mix (vec3 "0.15" "0.30" "0.55")
                          (vec3 "0.80" "0.85" "0.90")
                          (smoothstep (fl 0 35) (fl 0 65) band)))
       (set! gl_FragColor
             (vec4 (* c (+ (fl 0 30) (* (fl 0 70) d))) (fl 1)))))))

(define rim-p
  (fx-program3!
   (make-vs)
   `((precision mediump float)
     ,env-block
     (varying vec3 v_n)
     (varying vec3 v_wp)
     (define (main) void
       (local vec3 v (normalize (- u_eye.xyz v_wp)))
       (local vec3 n (normalize v_n))
       (local float rim (pow (- (fl 1) (max (dot n v) (fl 0)))
                             (fl 2)))
       (local float pulse (+ (fl 0 60)
                             (* (fl 0 40) (sin (* u_misc.x (fl 2))))))
       (local float d (max (dot n u_light.xyz) (fl 0)))
       (set! gl_FragColor
             (vec4 (+ (* (vec3 "0.20" "0.22" "0.28")
                         (+ (fl 0 25) (* (fl 0 55) d)))
                      (* (vec3 "0.30" "0.80" "1.0") (* rim pulse)))
                   (fl 1)))))))

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

(define torus (upload (mesh-torus 1.5 0.55 40 20)))
(define ball (upload (mesh-sphere 1.3 40 20)))
(define box (upload (mesh-box 2.0 2.0 2.0)))

;; the buffer behind the block, and its staging mirror
(define env-ubo (fx-ubo! 112))
(define env-base (fx-alloc! 112))
(for-each (lambda (p)
            (gl-uniform-block! (fx-program-slot p) "Env" 0))
          (list lit-p stripe-p rim-p))

(define (env! vp light eye t)
  (let m4 ((i 0))
    (when (< i 16)
      (%mem-f32-set! (+ env-base (* 4 i)) (vector-ref vp i))
      (m4 (+ i 1))))
  (%mem-f32-set! (+ env-base 64) (v3-x light))
  (%mem-f32-set! (+ env-base 68) (v3-y light))
  (%mem-f32-set! (+ env-base 72) (v3-z light))
  (%mem-f32-set! (+ env-base 76) 0.0)
  (%mem-f32-set! (+ env-base 80) (v3-x eye))
  (%mem-f32-set! (+ env-base 84) (v3-y eye))
  (%mem-f32-set! (+ env-base 88) (v3-z eye))
  (%mem-f32-set! (+ env-base 92) 0.0)
  (%mem-f32-set! (+ env-base 96) t)
  (%mem-f32-set! (+ env-base 100) 0.0)
  (%mem-f32-set! (+ env-base 104) 0.0)
  (%mem-f32-set! (+ env-base 108) 0.0)
  (cmd-ubo-data! env-ubo env-base 112)
  (cmd-bind-ubo! 0 env-ubo))

(define proj (m4-perspective 0.9 (/ 800.0 600.0) 0.1 100.0))
(define light (v3-normalize (v3 0.5 0.8 0.4)))

(fx-loop!
 (lambda (t dt)
   (cmd-clear! 0.07 0.08 0.12 1.0)
   (cmd-depth! #t)
   (let* ((a (fl* 0.25 t))
          (eye (v3 (fl* 9.0 (flsin a)) 3.5 (fl* 9.0 (flcos a))))
          (vp (m4-mul proj (m4-look-at eye (v3 0.0 0.0 0.0)
                                       (v3 0.0 1.0 0.0)))))
     ;; the whole frame's shared state: one upload, one binding
     (env! vp light eye t)
     (let ((spin (m4-rotate-y (fl* 0.6 t))))
       (bind-upload! lit-p torus)
       (fx-uniform! lit-p 'u_model
                    (m4-mul (m4-translate -3.4 0.0 0.0) spin))
       (cmd-draw-elements! GL-TRIANGLES (vector-ref torus 6))
       (bind-upload! stripe-p ball)
       (fx-uniform! stripe-p 'u_model (m4-translate 0.0 0.0 0.0))
       (cmd-draw-elements! GL-TRIANGLES (vector-ref ball 6))
       (bind-upload! rim-p box)
       (fx-uniform! rim-p 'u_model
                    (m4-mul (m4-translate 3.4 0.0 0.0) spin))
       (cmd-draw-elements! GL-TRIANGLES (vector-ref box 6))))))
