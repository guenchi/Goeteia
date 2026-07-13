;; Picking: the cursor casts a ray.  m4-inverse turns the
;; view-projection inside out, m4-unproject pushes the mouse through
;; the near and far planes, and (gfx collide)'s ray-aabb answers
;; which box the ray meets first.  Hover lifts a box's color; a
;; click keeps it lit.
(import (rnrs) (web js) (web dom) (gfx gl) (gfx glsl) (gfx fx)
        (gfx mat) (gfx mesh) (gfx collide))

(fx-init! (get-element-by-id "c"))
(fx-init-input!)

(define lit (fx-program! mesh-lit-vs mesh-lit-fs))
(define box (mesh-box 1.2 1.2 1.2))
(define vbuf (fx-buffer!))
(define ibuf (fx-buffer!))
(define vbase (fx-alloc! (mesh-vertex-bytes box)))
(define ibase (fx-alloc! (mesh-index-bytes box)))
(mesh-write! box vbase ibase)

;; a 5x5 grid; picked boxes stay lit
(define N 5)
(define picked (make-vector (* N N) #f))
(define (grid-x i) (fl* 2.2 (fl- (fixnum->flonum (remainder i N)) 2.0)))
(define (grid-z i) (fl* 2.2 (fl- (fixnum->flonum (quotient i N)) 2.0)))

(define proj (m4-perspective 0.9 (/ 800.0 600.0) 0.1 100.0))
(define view (m4-look-at (v3 7.0 9.0 11.0) (v3 0.0 0.0 0.0)
                         (v3 0.0 1.0 0.0)))
(define vp (m4-mul proj view))
(define inv (m4-inverse vp))
(define eye (v3 7.0 9.0 11.0))

(define light (v3-normalize (v3 0.5 0.9 0.4)))
(define uploaded #f)
(define was-down #f)

;; the box the cursor's ray meets first, or -1
(define (hover-index)
  (let* ((nx (fl- (fl/ (pointer-x) 400.0) 1.0))
         (ny (fl- 1.0 (fl/ (pointer-y) 300.0)))
         (near (m4-unproject inv nx ny -1.0))
         (far (m4-unproject inv nx ny 1.0))
         (dir (v3-normalize (v3-sub far near))))
    (let scan ((i 0) (best -1) (bestd 0.0))
      (if (= i (* N N))
          best
          (let* ((c (v3 (grid-x i) 0.0 (grid-z i)))
                 (h (ray-aabb near dir
                              (v3-sub c (v3 0.6 0.6 0.6))
                              (v3-add c (v3 0.6 0.6 0.6)))))
            (if (and h (or (= best -1) (fl<? h bestd)))
                (scan (+ i 1) i h)
                (scan (+ i 1) best bestd)))))))

(fx-loop!
 (lambda (t dt)
   (cmd-clear! 0.08 0.09 0.13 1.0)
   (cmd-depth! #t)
   (let ((hover (hover-index))
         (down (pointer-down?)))
     ;; click lands on the hovered box, once per press
     (when (and down (not was-down) (>= hover 0))
       (vector-set! picked hover (not (vector-ref picked hover))))
     (set! was-down down)
     (fx-use! lit vbuf)
     (cmd-bind-index! ibuf)
     (unless uploaded
       (cmd-buffer-data! vbase (mesh-vertex-bytes box))
       (cmd-index-data! ibase (mesh-index-bytes box))
       (set! uploaded #t))
     (fx-uniform! lit 'u_light (v3-x light) (v3-y light) (v3-z light))
     (fx-uniform! lit 'u_ambient 0.3)
     (let each ((i 0))
       (when (< i (* N N))
         (let ((m (m4-translate (grid-x i) 0.0 (grid-z i))))
           (fx-uniform! lit 'u_mvp (m4-mul vp m))
           (fx-uniform! lit 'u_model m)
           (cond
            ((vector-ref picked i)
             (fx-uniform! lit 'u_color 0.95 0.55 0.25 1.0))
            ((= i hover)
             (fx-uniform! lit 'u_color 0.75 0.80 0.95 1.0))
            (else
             (fx-uniform! lit 'u_color 0.35 0.42 0.55 1.0)))
           (cmd-draw-elements! GL-TRIANGLES (mesh-index-count box)))
         (each (+ i 1)))))))
