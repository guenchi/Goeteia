;; One hundred thousand sparks and the CPU never touches one: the
;; particle state lives in two GPU buffers, and a transform-feedback
;; program (fx-tf-program!) integrates A into B each frame -- the
;; vertex shader IS the physics, rasterizer discard keeps it
;; invisible -- then a point-sprite pass draws B and the buffers
;; swap.  Scheme's whole frame is a handful of command words.
;; Needs WebGL 2.
(import (rnrs) (web js) (web dom) (web gl) (web glsl) (web fx)
        (web mat))

(fx-init! (get-element-by-id "c"))

(define N 100000)

;; the update step: eight floats in, eight floats out, on the GPU
(define update-p
  (fx-tf-program!
   '((attribute vec3 a_pos)
     (attribute vec3 a_vel)
     (attribute float a_life)
     (attribute float a_seed)
     (uniform float u_dt)
     (varying vec3 v_pos)
     (varying vec3 v_vel)
     (varying float v_life)
     (varying float v_seed)
     (define (main) void
       (local float life (- a_life (* u_dt (fl 0 35))))
       (if-else (< life (fl 0))
                ;; dead: respawn at the nozzle, hash the seed onward
                ((local float s (fract (* (sin (* a_seed "78.233"))
                                          "43758.5453")))
                 (local float s2 (fract (* s "17.13")))
                 (local float s3 (fract (* s "39.71")))
                 (set! v_pos (vec3 (fl 0) (fl 0) (fl 0)))
                 (set! v_vel (vec3 (* (- s (fl 0 50)) (fl 4))
                                   (+ (fl 5) (* s2 (fl 3)))
                                   (* (- s3 (fl 0 50)) (fl 4))))
                 (set! v_life (fl 1))
                 (set! v_seed (fract (+ a_seed "0.61803"))))
                ;; alive: integrate under gravity
                ((set! v_pos (+ a_pos (* a_vel u_dt)))
                 (set! v_vel (- a_vel (vec3 (fl 0) (* (fl 6) u_dt)
                                            (fl 0))))
                 (set! v_life life)
                 (set! v_seed a_seed)))
       (set! gl_Position (vec4 (fl 0) (fl 0) (fl 0) (fl 1)))))
   '((precision mediump float)
     (define (main) void
       (set! gl_FragColor (vec4 (fl 0) (fl 0) (fl 0) (fl 1)))))))

;; the draw step: the same buffer, as glowing point sprites
(define draw-p
  (fx-program3!
   '((attribute vec3 a_pos)
     (attribute vec3 a_vel)
     (attribute float a_life)
     (attribute float a_seed)
     (uniform mat4 u_vp)
     (varying float v_l)
     (define (main) void
       (set! gl_Position (* u_vp (vec4 a_pos (fl 1))))
       (set! gl_PointSize (+ (fl 1) (* a_life (fl 2))))
       (set! v_l a_life)))
   '((precision mediump float)
     (varying float v_l)
     (define (main) void
       (local vec2 pc (- gl_PointCoord (vec2 (fl 0 50) (fl 0 50))))
       (local float m (max (- (fl 1) (* (fl 4) (dot pc pc))) (fl 0)))
       (local vec3 hot (vec3 (fl 1) "0.92" "0.75"))
       (local vec3 cool (vec3 "0.85" "0.30" "0.04"))
       (set! gl_FragColor
             (vec4 (* (mix cool hot v_l) (* m v_l)) (fl 1)))))))

;; two state buffers; the seed data staggers everyone's life
(define buf-a (fx-buffer!))
(define buf-b (fx-buffer!))
(define ibase (fx-alloc! (* N 32)))
(define seed 3)
(define (rnd!)
  (set! seed (remainder (+ (* seed 1103515245) 12345) 2147483648))
  (fl/ (fixnum->flonum (remainder seed 100000)) 100000.0))
(let fill ((i 0))
  (when (< i N)
    (let ((at (+ ibase (* i 32))))
      (%mem-f32-set! at 0.0)
      (%mem-f32-set! (+ at 4) 0.0)
      (%mem-f32-set! (+ at 8) 0.0)
      (%mem-f32-set! (+ at 12) 0.0)
      (%mem-f32-set! (+ at 16) 0.0)
      (%mem-f32-set! (+ at 20) 0.0)
      (%mem-f32-set! (+ at 24) (rnd!))    ; staggered life
      (%mem-f32-set! (+ at 28) (rnd!)))   ; seed
    (fill (+ i 1))))

(define proj (m4-perspective 0.9 (/ 800.0 600.0) 0.1 100.0))
(define bufs (cons buf-a buf-b))
(define uploaded #f)

(fx-loop!
 (lambda (t dt)
   (let ((dtc (if (fl<? dt 0.05) dt 0.05)))
     ;; update: front buffer in, back buffer out, all on the GPU
     (fx-use! update-p (car bufs))
     (unless uploaded
       (cmd-buffer-data! ibase (* N 32))  ; fill A...
       (cmd-bind-buffer! (cdr bufs))
       (cmd-buffer-data! ibase (* N 32))  ; ...and size B like it
       (cmd-bind-buffer! (car bufs))      ; B is about to catch the
       (set! uploaded #t))                ; feedback: leave it unbound
     (fx-uniform! update-p 'u_dt dtc)
     (cmd-tf-buffer! (cdr bufs))
     (cmd-tf-begin!)
     (cmd-draw-arrays! GL-POINTS 0 N)
     (cmd-tf-end!)
     ;; draw the fresh buffer as additive sprites
     (cmd-clear! 0.02 0.02 0.05 1.0)
     (cmd-depth! #f)
     (cmd-blend! 'add)
     (let* ((a (fl* 0.15 t))
            (eye (v3 (fl* 11.0 (flsin a)) 5.0 (fl* 11.0 (flcos a))))
            (vp (m4-mul proj (m4-look-at eye (v3 0.0 2.5 0.0)
                                         (v3 0.0 1.0 0.0)))))
       (fx-use! draw-p (cdr bufs))
       (fx-uniform! draw-p 'u_vp vp)
       (cmd-draw-arrays! GL-POINTS 0 N))
     (cmd-blend! 'off)
     ;; swap: what was written becomes what is read
     (set! bufs (cons (cdr bufs) (car bufs))))))
