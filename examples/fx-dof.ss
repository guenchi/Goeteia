;; Depth of field: the scene renders lit into one target and linear
;; view depth into another (the fx-ssao pattern), then (gfx post)'s
;; dof mixes each pixel toward a half-resolution blur of the scene
;; by its distance from the focal plane.  The focus breathes between
;; the near and far rows of spheres, so you watch the plane sweep.
;; Needs WebGL 2.
(import (rnrs) (web js) (web dom) (gfx gl) (gfx glsl) (gfx fx)
        (gfx mat) (gfx mesh) (gfx post))

(fx-init! (get-element-by-id "c"))

(define FAR 60.0)

(define lit-p (fx-program! mesh-lit-vs mesh-lit-fs))

(define depth-p
  (fx-program!
   '((attribute vec3 a_pos)
     (attribute vec3 a_normal)
     (uniform mat4 u_mvp)
     (uniform vec3 u_eye)
     (uniform float u_far)
     (varying float v_d)
     (define (main) void
       (set! gl_Position (* u_mvp (vec4 a_pos (fl 1))))
       (set! v_d (/ (distance a_pos u_eye) u_far))))
   '((precision mediump float)
     (varying float v_d)
     (define (main) void
       (set! gl_FragColor (vec4 v_d (fl 0) (fl 0) (fl 1)))))))

;; ---- a row of spheres marching away from the camera ----
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

(define ground (upload (mesh-plane 40.0 40.0)))
(define ball (upload (mesh-sphere 1.0 32 16)))

;; alternating spheres left and right, receding into the distance
(define places
  (let walk ((i 0) (acc '()))
    (if (= i 9)
        (reverse acc)
        (walk (+ i 1)
              (cons (v3 (if (= 0 (remainder i 2)) -2.2 2.2)
                        1.0
                        (fl- 6.0 (fl* 3.2 (fixnum->flonum i))))
                    acc)))))

(define scene-t (fx-target! 800 600))
(define depth-t (fx-target-hdr! 800 600))
(define dof (make-dof 800 600))

(define proj (m4-perspective 0.8 (/ 800.0 600.0) 0.5 FAR))
(define light (v3-normalize (v3 0.5 0.8 0.4)))
(define eye (v3 0.0 3.2 11.0))
(define vp (m4-mul proj (m4-look-at eye (v3 0.0 0.8 -4.0)
                                    (v3 0.0 1.0 0.0))))

(define (draw-scene! prog each)
  (bind-upload! prog ground)
  (each -1 (m4-identity))
  (cmd-draw-elements! GL-TRIANGLES (vector-ref ground 6))
  (let loop ((i 0) (cs places))
    (when (pair? cs)
      (let ((c (car cs)))
        (bind-upload! prog ball)
        (each i (m4-translate (v3-x c) (v3-y c) (v3-z c)))
        (cmd-draw-elements! GL-TRIANGLES (vector-ref ball 6)))
      (loop (+ i 1) (cdr cs)))))

(fx-loop!
 (lambda (t dt)
   (cmd-depth! #t)
   (cmd-unbind-texture! 0)
   (cmd-unbind-texture! 1)
   (cmd-unbind-texture! 2)
   ;; the lit scene
   (fx-bind-target! scene-t)
   (cmd-clear! 0.70 0.76 0.85 1.0)
   (draw-scene! lit-p
                (lambda (i m)
                  (fx-uniform! lit-p 'u_mvp (m4-mul vp m))
                  (fx-uniform! lit-p 'u_model m)
                  (fx-uniform! lit-p 'u_light (v3-x light)
                               (v3-y light) (v3-z light))
                  (fx-uniform! lit-p 'u_ambient 0.4)
                  (if (< i 0)
                      (fx-uniform! lit-p 'u_color 0.45 0.50 0.58 1.0)
                      (let ((k (fl/ (fixnum->flonum i) 8.0)))
                        (fx-uniform! lit-p 'u_color
                                     (fl- 0.9 (fl* 0.5 k))
                                     (fl+ 0.35 (fl* 0.3 k))
                                     (fl+ 0.3 (fl* 0.6 k))
                                     1.0)))))
   ;; linear depth
   (fx-bind-target! depth-t)
   (cmd-clear! 1.0 1.0 1.0 1.0)
   (draw-scene! depth-p
                (lambda (i m)
                  (fx-uniform! depth-p 'u_mvp (m4-mul vp m))
                  (fx-uniform! depth-p 'u_eye (v3-x eye) (v3-y eye)
                               (v3-z eye))
                  (fx-uniform! depth-p 'u_far FAR)))
   ;; the focal plane breathes from the first row to the last
   (cmd-depth! #f)
   (let ((focus (fl/ (fl+ 12.0 (fl* 10.0 (flsin (fl* 0.5 t)))) FAR)))
     (dof-run! dof (fx-target-texture scene-t)
               (fx-target-texture depth-t) #f focus 0.12))))
