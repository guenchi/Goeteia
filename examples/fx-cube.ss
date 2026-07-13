;; A spinning cube, raw WebGL -- no Three.js.  (gfx mat) computes the
;; perspective / look-at / rotation matrices in pure Scheme (its own
;; trig, identical bytes on both compiler hosts), fx wires the shader
;; from its own forms, and the mesh is indexed: 24 vertices, 36 u16
;; indices, one drawElements per frame with the depth test on.
(import (rnrs) (web js) (web dom) (gfx gl) (gfx glsl) (gfx fx) (gfx mat))

(fx-init! (get-element-by-id "c"))

(define p
  (fx-program!
   '((attribute vec3 a_pos)
     (attribute vec3 a_color)
     (uniform mat4 u_mvp)
     (varying vec3 v_color)
     (define (main) void
       (set! gl_Position (* u_mvp (vec4 a_pos (fl 1))))
       (set! v_color a_color)))
   '((precision mediump float)
     (varying vec3 v_color)
     (define (main) void
       (set! gl_FragColor (vec4 v_color (fl 1)))))))

(define buf (fx-buffer!))
(define ibuf (fx-buffer!))               ; bound as the element array
(define vbase (fx-alloc! 576))           ; 24 verts x 6 f32
(define ibase (fx-alloc! 72))            ; 36 u16

;; six faces: a color and four corners, counter-clockwise from outside
(define faces
  '(((0.95 0.35 0.35) (( 1 -1 -1) ( 1  1 -1) ( 1  1  1) ( 1 -1  1)))
    ((0.35 0.80 0.95) ((-1 -1  1) (-1  1  1) (-1  1 -1) (-1 -1 -1)))
    ((0.45 0.85 0.45) ((-1  1 -1) (-1  1  1) ( 1  1  1) ( 1  1 -1)))
    ((0.95 0.65 0.30) ((-1 -1  1) (-1 -1 -1) ( 1 -1 -1) ( 1 -1  1)))
    ((0.95 0.90 0.35) ((-1 -1  1) ( 1 -1  1) ( 1  1  1) (-1  1  1)))
    ((0.60 0.45 0.95) (( 1 -1 -1) (-1 -1 -1) (-1  1 -1) ( 1  1 -1)))))

(let face ((fs faces) (vi 0))
  (unless (null? fs)
    (let* ((f (car fs))
           (col (car f)))
      (let corner ((cs (cadr f)) (vi vi))
        (if (null? cs)
            (face (cdr fs) vi)
            (let ((c (car cs))
                  (at (+ vbase (* vi 24))))
              (%mem-f32-set! at (fixnum->flonum (car c)))
              (%mem-f32-set! (+ at 4) (fixnum->flonum (cadr c)))
              (%mem-f32-set! (+ at 8) (fixnum->flonum (caddr c)))
              (%mem-f32-set! (+ at 12) (car col))
              (%mem-f32-set! (+ at 16) (cadr col))
              (%mem-f32-set! (+ at 20) (caddr col))
              (corner (cdr cs) (+ vi 1))))))))

;; two triangles per face (0 1 2, 0 2 3), u16 pairs packed per word
(let idx ((i 0) (at ibase))
  (when (< i 6)
    (let ((b (* 4 i)))
      (%mem-i32-set! at (+ b (* 65536 (+ b 1))))
      (%mem-i32-set! (+ at 4) (+ (+ b 2) (* 65536 b)))
      (%mem-i32-set! (+ at 8) (+ (+ b 2) (* 65536 (+ b 3)))))
    (idx (+ i 1) (+ at 12))))

(define proj (m4-perspective 0.9 (/ 800.0 600.0) 0.1 100.0))
(define view (m4-look-at (v3 0 0 6) (v3 0 0 0) (v3 0 1 0)))

(fx-loop!
 (lambda (t dt)
   (cmd-clear! 0.05 0.06 0.10 1.0)
   (cmd-depth! #t)
   (fx-use! p buf)
   (cmd-buffer-data! vbase 576)
   (cmd-bind-index! ibuf)
   (cmd-index-data! ibase 72)
   (fx-uniform! p 'u_mvp
                (m4-mul proj
                        (m4-mul view
                                (m4-mul (m4-rotate-y t)
                                        (m4-rotate-x (fl* 0.7 t))))))
   (cmd-draw-elements! GL-TRIANGLES 36)))
