;; Four thousand sparks, one draw call: a particle fountain from
;; parts the toolkit already has.  Particle state lives directly in
;; staging memory (position, velocity, life per particle); a Scheme
;; loop integrates it each frame and writes the compact instance
;; stream next door; drawElementsInstanced billboards one quad
;; through it under additive blending.  Needs WebGL 2.
(import (rnrs) (web js) (web dom) (web gl) (web glsl) (web fx)
        (web mat))

(fx-init! (get-element-by-id "c"))

(define N 4000)

(define p
  (fx-program!
   '((attribute vec2 a_corner)          ; the quad, [-1,1]^2
     (attribute vec3 i_pos)             ; per spark
     (attribute float i_life)           ; 1 at birth, 0 at death
     (uniform mat4 u_vp)
     (uniform vec3 u_right)             ; camera axes, for billboards
     (uniform vec3 u_up)
     (varying vec2 v_c)
     (varying float v_life)
     (define (main) void
       (local float size (+ (fl 0 4) (* (fl 0 12) (- (fl 1) i_life))))
       (local vec3 wp (+ i_pos
                         (* (+ (* u_right a_corner.x)
                               (* u_up a_corner.y))
                            size)))
       (set! gl_Position (* u_vp (vec4 wp (fl 1))))
       (set! v_c a_corner)
       (set! v_life i_life)))
   '((precision mediump float)
     (varying vec2 v_c)
     (varying float v_life)
     (define (main) void
       (local float d (max (- (fl 1) (length v_c)) (fl 0)))
       ;; white-hot at birth, ember-orange at death
       (local vec3 hot (vec3 (fl 1) (fl 0 95) (fl 0 80)))
       (local vec3 cool (vec3 (fl 0 90) (fl 0 30) (fl 0 5)))
       (set! gl_FragColor
             (vec4 (* (mix cool hot v_life) (* d (* d v_life)))
                   (fl 1)))))))

;; one quad, indexed
(define vbuf (fx-buffer!))
(define ibuf (fx-buffer!))
(define instbuf (fx-buffer!))
(define vbase (fx-alloc! 32))
(define ibase (fx-alloc! 12))
(let corner ((i 0) (xs '(-1.0 -1.0  1.0 -1.0  -1.0 1.0  1.0 1.0)))
  (unless (null? xs)
    (%mem-f32-set! (+ vbase (* i 4)) (car xs))
    (corner (+ i 1) (cdr xs))))
(%mem-i32-set! ibase (+ 0 (* 65536 1)))          ; u16 pairs: 0 1
(%mem-i32-set! (+ ibase 4) (+ 2 (* 65536 2)))    ;            2 2
(%mem-i32-set! (+ ibase 8) (+ 1 (* 65536 3)))    ;            1 3

;; state: pos3 vel3 life pad, 32 bytes each; instances: pos3 life
(define sbase (fx-alloc! (* N 32)))
(define instbase (fx-alloc! (* N 16)))

(define seed 7)
(define (rnd!)                           ; [0,1)
  (set! seed (remainder (+ (* seed 1103515245) 12345) 2147483648))
  (fl/ (fixnum->flonum (remainder seed 100000)) 100000.0))

(define (spawn! at stagger)              ; a fresh spark at the nozzle
  (let* ((a (fl* 6.283185307179586 (rnd!)))
         (r (fl* 1.6 (rnd!))))
    (%mem-f32-set! at 0.0)
    (%mem-f32-set! (+ at 4) 0.0)
    (%mem-f32-set! (+ at 8) 0.0)
    (%mem-f32-set! (+ at 12) (fl* r (flcos a)))          ; vx
    (%mem-f32-set! (+ at 16) (fl+ 5.5 (fl* 2.5 (rnd!)))) ; vy: up
    (%mem-f32-set! (+ at 20) (fl* r (flsin a)))          ; vz
    (%mem-f32-set! (+ at 24) (if stagger (rnd!) 1.0))))  ; life

(let init ((i 0))
  (when (< i N)
    (spawn! (+ sbase (* i 32)) #t)       ; staggered, so the stream
    (init (+ i 1))))                     ; is already in full flow

(define (step! dt)
  (let each ((i 0))
    (when (< i N)
      (let* ((at (+ sbase (* i 32)))
             (life (fl- (%mem-f32-ref (+ at 24)) (fl* 0.45 dt))))
        (if (fl<? life 0.0)
            (spawn! at #f)
            (let ((x (fl+ (%mem-f32-ref at)
                          (fl* (%mem-f32-ref (+ at 12)) dt)))
                  (y (fl+ (%mem-f32-ref (+ at 4))
                          (fl* (%mem-f32-ref (+ at 16)) dt)))
                  (z (fl+ (%mem-f32-ref (+ at 8))
                          (fl* (%mem-f32-ref (+ at 20)) dt))))
              (%mem-f32-set! at x)
              (%mem-f32-set! (+ at 4) y)
              (%mem-f32-set! (+ at 8) z)
              (%mem-f32-set! (+ at 16)                   ; gravity
                             (fl- (%mem-f32-ref (+ at 16))
                                  (fl* 6.0 dt)))
              (%mem-f32-set! (+ at 24) life)))
        ;; the instance stream: where it is and how alive it is
        (let ((out (+ instbase (* i 16))))
          (%mem-f32-set! out (%mem-f32-ref at))
          (%mem-f32-set! (+ out 4) (%mem-f32-ref (+ at 4)))
          (%mem-f32-set! (+ out 8) (%mem-f32-ref (+ at 8)))
          (%mem-f32-set! (+ out 12) (%mem-f32-ref (+ at 24)))))
      (each (+ i 1)))))

(define proj (m4-perspective 0.9 (/ 800.0 600.0) 0.1 100.0))
(define uploaded #f)

(fx-loop!
 (lambda (t dt)
   (step! (if (fl<? dt 0.05) dt 0.05))   ; clamp tab-switch jumps
   (cmd-clear! 0.03 0.03 0.06 1.0)
   (cmd-depth! #f)
   (cmd-blend! 'add)
   (let* ((a (fl* 0.2 t))
          (eye (v3 (fl* 10.0 (flsin a)) 4.5 (fl* 10.0 (flcos a))))
          (view (m4-look-at eye (v3 0.0 2.5 0.0) (v3 0.0 1.0 0.0)))
          (vp (m4-mul proj view)))
     (fx-use-instanced! p vbuf instbuf)
     (cmd-bind-index! ibuf)
     (unless uploaded
       (cmd-bind-buffer! vbuf)
       (cmd-buffer-data! vbase 32)
       (cmd-index-data! ibase 12)
       (set! uploaded #t))
     (cmd-bind-buffer! instbuf)          ; fresh positions every frame
     (cmd-buffer-data! instbase (* N 16))
     (fx-uniform! p 'u_vp vp)
     ;; the camera's right and up rows of the view matrix
     (fx-uniform! p 'u_right (vector-ref view 0) (vector-ref view 4)
                  (vector-ref view 8))
     (fx-uniform! p 'u_up (vector-ref view 1) (vector-ref view 5)
                  (vector-ref view 9))
     (cmd-draw-elements-instanced! GL-TRIANGLES 6 N))
   (cmd-blend! 'off)))
