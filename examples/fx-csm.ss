;; Cascaded shadow maps: one depth map cannot cover a long view --
;; spread over the whole range it turns to mush up close.  So two
;; depth-only targets share the work: a tight cascade around the
;; camera (crisp nearby shadows) and a wide one behind it (soft far
;; ones).  Each fragment projects into the near cascade first and
;; falls back to the far one when it lands outside.  Needs WebGL 2.
(import (rnrs) (web js) (web dom) (web gl) (web glsl) (web fx)
        (web mat) (web mesh))

(fx-init! (get-element-by-id "c"))

(define depth-p
  (fx-program!
   '((attribute vec3 a_pos)
     (attribute vec3 a_normal)
     (uniform mat4 u_mvp)
     (define (main) void
       (set! gl_Position (* u_mvp (vec4 a_pos (fl 1))))))
   '((precision mediump float)
     (define (main) void
       (set! gl_FragColor (vec4 (fl 1) (fl 1) (fl 1) (fl 1)))))))

(define lit-p
  (fx-program!
   '((attribute vec3 a_pos)
     (attribute vec3 a_normal)
     (uniform mat4 u_mvp)
     (uniform mat4 u_model)
     (uniform mat4 u_lvp0)               ; near cascade, model folded in
     (uniform mat4 u_lvp1)               ; far cascade
     (varying vec3 v_n)
     (varying vec4 v_sh0)
     (varying vec4 v_sh1)
     (define (main) void
       (local vec4 p (vec4 a_pos (fl 1)))
       (set! gl_Position (* u_mvp p))
       (set! v_sh0 (* u_lvp0 p))
       (set! v_sh1 (* u_lvp1 p))
       (set! v_n (* (mat3 u_model) a_normal))))
   '((precision mediump float)
     (uniform sampler2D u_shadow0)
     (uniform sampler2D u_shadow1)
     (uniform vec3 u_light)
     (uniform vec4 u_color)
     (varying vec3 v_n)
     (varying vec4 v_sh0)
     (varying vec4 v_sh1)
     (define (main) void
       (local vec3 s0 (+ (* (/ v_sh0.xyz v_sh0.w) (fl 0 50))
                         (vec3 (fl 0 50) (fl 0 50) (fl 0 50))))
       (local vec3 s1 (+ (* (/ v_sh1.xyz v_sh1.w) (fl 0 50))
                         (vec3 (fl 0 50) (fl 0 50) (fl 0 50))))
       ;; inside the near cascade's map (with a margin)?
       (local float use0 (* (* (step "0.02" s0.x) (step s0.x "0.98"))
                            (* (step "0.02" s0.y) (step s0.y "0.98"))))
       (local vec4 t0 (texture2D u_shadow0 s0.xy))
       (local vec4 t1 (texture2D u_shadow1 s1.xy))
       (local float lit0 (step (- s0.z "0.002") t0.r))
       (local float lit1 (step (- s1.z "0.003") t1.r))
       (local float lit (mix lit1 lit0 use0))
       (local float d (max (dot (normalize v_n) u_light) (fl 0)))
       (local vec3 base (pow u_color.rgb (vec3 "2.2" "2.2" "2.2")))
       (local vec3 c (* base (+ (fl 0 25) (* (fl 0 75) (* d lit)))))
       (set! gl_FragColor
             (vec4 (pow c (vec3 "0.4545" "0.4545" "0.4545"))
                   u_color.a))))))

;; ---- geometry: a wide ground, a field of pillars ----
(define ground (mesh-plane 240.0 240.0))
(define box (mesh-box 1.6 5.0 1.6))
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
(define ground-obj (upload ground))
(define box-obj (upload box))

;; pillars on a jittered grid
(define N 80)
(define seed 11)
(define (rnd!)
  (set! seed (remainder (+ (* seed 1103515245) 12345) 2147483648))
  (fl/ (fixnum->flonum (remainder seed 100000)) 100000.0))
(define spots
  (let gen ((i 0) (acc '()))
    (if (= i N)
        acc
        (gen (+ i 1)
             (cons (cons (fl* 200.0 (fl- (rnd!) 0.5))
                         (fl* 200.0 (fl- (rnd!) 0.5)))
                   acc)))))

(define csm0 (fx-target! 1024 1024 #t))  ; tight, around the camera
(define csm1 (fx-target! 1024 1024 #t))  ; wide, the whole field
(define light (v3-normalize (v3 0.5 0.85 0.35)))
(define proj (m4-perspective 0.9 (/ 800.0 600.0) 0.5 300.0))

(define (light-vp center half)
  (m4-mul (m4-ortho (fl- 0.0 half) half (fl- 0.0 half) half 1.0 120.0)
          (m4-look-at (v3-add center (v3-scale light 60.0)) center
                      (v3 0.0 1.0 0.0))))

(define (draw-boxes! prog each)
  (bind-upload! prog box-obj)
  (for-each (lambda (s)
              (each (m4-translate (car s) 2.5 (cdr s)))
              (cmd-draw-elements! GL-TRIANGLES (vector-ref box-obj 6)))
            spots))

(fx-loop!
 (lambda (t dt)
   (cmd-depth! #t)
   (let* ((a (fl* 0.06 t))
          (eye (v3 (fl* 60.0 (flsin a)) 9.0 (fl* 60.0 (flcos a))))
          (ahead (v3 (fl* 40.0 (flsin (fl+ a 0.9))) 0.0
                     (fl* 40.0 (flcos (fl+ a 0.9)))))
          (vp (m4-mul proj (m4-look-at eye ahead (v3 0.0 1.0 0.0))))
          ;; cascades center on the view: near just ahead, far wide
          (lvp0 (light-vp (v3 (fl* 0.7 (v3-x ahead))
                              0.0 (fl* 0.7 (v3-z ahead))) 18.0))
          (lvp1 (light-vp (v3 0.0 0.0 0.0) 130.0)))
     ;; two depth passes, the pillars only; both maps were
     ;; sampled last frame -- unbind before rendering into them
     (cmd-unbind-texture! 0)
     (cmd-unbind-texture! 1)
     (fx-bind-target! csm0)
     (cmd-clear! 1.0 1.0 1.0 1.0)
     (draw-boxes! depth-p
                  (lambda (m)
                    (fx-uniform! depth-p 'u_mvp (m4-mul lvp0 m))))
     (fx-bind-target! csm1)
     (cmd-clear! 1.0 1.0 1.0 1.0)
     (draw-boxes! depth-p
                  (lambda (m)
                    (fx-uniform! depth-p 'u_mvp (m4-mul lvp1 m))))
     ;; the scene, asking the right cascade
     (fx-bind-canvas!)
     (cmd-clear! 0.63 0.71 0.81 1.0)
     (let ((unis! (lambda (m r g b)
                    (fx-uniform! lit-p 'u_mvp (m4-mul vp m))
                    (fx-uniform! lit-p 'u_model m)
                    (fx-uniform! lit-p 'u_lvp0 (m4-mul lvp0 m))
                    (fx-uniform! lit-p 'u_lvp1 (m4-mul lvp1 m))
                    (fx-uniform! lit-p 'u_color r g b 1.0))))
       (bind-upload! lit-p ground-obj)
       (cmd-bind-texture! 0 (fx-target-texture csm0))
       (cmd-bind-texture! 1 (fx-target-texture csm1))
       (fx-uniform! lit-p 'u_shadow0 0)
       (fx-uniform! lit-p 'u_shadow1 1)
       (fx-uniform! lit-p 'u_light (v3-x light) (v3-y light)
                    (v3-z light))
       (unis! (m4-identity) 0.38 0.42 0.38)
       (cmd-draw-elements! GL-TRIANGLES (vector-ref ground-obj 6))
       (draw-boxes! lit-p
                    (lambda (m) (unis! m 0.72 0.5 0.35)))))))
