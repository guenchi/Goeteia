;; The particle fountain, on WebGPU: (web gpu) carries the command-
;; buffer architecture to the other API -- resources in a slot
;; table, one bridge call per frame replaying staged words into a
;; render pass, one queue.submit.  Physics runs in Scheme; each
;; particle is a small triangle whose 18 floats land in staging
;; memory and ride ONE writeBuffer to the GPU.  The pipeline is one
;; WGSL module (vs + fs entry points).  Needs a WebGPU browser.
(import (rnrs) (web js) (web dom) (web fx) (web gpu))

(define N 1500)
(define VBYTES (* N 3 24))              ; 3 verts x (vec2 pos + vec4 color)
(define VBASE 65536)                    ; commands live below
(let ((need (- (+ VBASE VBYTES) (* 65536 (%mem-size)))))
  (when (> need 0)
    (%mem-grow (quotient (+ need 65535) 65536))))

(define WGSL
  (string-append
   "struct VOut { @builtin(position) pos: vec4f,"
   "              @location(0) color: vec4f };\n"
   "@vertex fn vs(@location(0) p: vec2f, @location(1) c: vec4f)"
   "    -> VOut {\n"
   "  var o: VOut; o.pos = vec4f(p, 0.0, 1.0); o.color = c; return o;\n"
   "}\n"
   "@fragment fn fs(@location(0) c: vec4f) -> @location(0) vec4f {\n"
   "  return c;\n"
   "}\n"))

;; ---- the flock, in Scheme ----
(define xs (make-vector N 0.0))
(define ys (make-vector N 0.0))
(define vxs (make-vector N 0.0))
(define vys (make-vector N 0.0))
(define cols (make-vector (* N 3) 0.0))

(define seed 12345)                     ; a tiny LCG stays inside i31
(define (rand01)
  (set! seed (remainder (+ (* seed 75) 74) 65537))
  (fl/ (fixnum->flonum seed) 65537.0))

(define (spawn! i)
  (vector-set! xs i (fl* 0.04 (fl- (rand01) 0.5)))
  (vector-set! ys i -0.9)
  (vector-set! vxs i (fl* 1.2 (fl- (rand01) 0.5)))
  (vector-set! vys i (fl+ 1.4 (fl* 1.0 (rand01)))))

(let init ((i 0))
  (when (< i N)
    (spawn! i)
    (vector-set! ys i (fl- (fl* 2.0 (rand01)) 1.0))   ; stagger the start
    (let ((k (fl/ (fixnum->flonum i) (fixnum->flonum N))))
      (vector-set! cols (* i 3) (fl+ 0.9 (fl* 0.1 k)))
      (vector-set! cols (+ (* i 3) 1) (fl+ 0.5 (fl* 0.4 k)))
      (vector-set! cols (+ (* i 3) 2) (fl* 0.35 k)))
    (init (+ i 1))))

;; write particle i's triangle: 3 verts x (x y r g b a)
(define (emit! i)
  (let* ((x (vector-ref xs i)) (y (vector-ref ys i))
         (r (vector-ref cols (* i 3)))
         (g (vector-ref cols (+ (* i 3) 1)))
         (b (vector-ref cols (+ (* i 3) 2)))
         (s 0.011)
         (at (+ VBASE (* i 72))))
    (%mem-f32-set! at x)
    (%mem-f32-set! (+ at 4) (fl+ y s))
    (%mem-f32-set! (+ at 24) (fl- x s))
    (%mem-f32-set! (+ at 28) (fl- y s))
    (%mem-f32-set! (+ at 48) (fl+ x s))
    (%mem-f32-set! (+ at 52) (fl- y s))
    (let vert ((v 0))
      (when (< v 3)
        (let ((c (+ at (* v 24) 8)))
          (%mem-f32-set! c r)
          (%mem-f32-set! (+ c 4) g)
          (%mem-f32-set! (+ c 8) b)
          (%mem-f32-set! (+ c 12) 1.0))
        (vert (+ v 1))))))

(define ready #f)
(gpu-attach! (get-element-by-id "c")
             (lambda ()
               (gpu-pipeline! 0 WGSL 24 "float32x2,float32x4")
               (gpu-buffer! 1 VBYTES)
               (set! ready #t)))

(fx-ticks!                              ; the pump is renderer-neutral
 (lambda (t dt)
   (when ready
     (let ((dtc (if (fl<? dt 0.05) dt 0.05)))
       (let step ((i 0))
         (when (< i N)
           (vector-set! vys i (fl- (vector-ref vys i) (fl* 1.8 dtc)))
           (vector-set! xs i (fl+ (vector-ref xs i)
                                  (fl* (vector-ref vxs i) dtc)))
           (vector-set! ys i (fl+ (vector-ref ys i)
                                  (fl* (vector-ref vys i) dtc)))
           (when (fl<? (vector-ref ys i) -1.02)
             (spawn! i))
           (emit! i)
           (step (+ i 1)))))
     (gpu-begin!)
     (gpu-clear! 0.02 0.02 0.05 1.0)
     (gpu-use-pipeline! 0)
     (gpu-bind-vbuf! 1)
     (gpu-buffer-data! 1 VBASE VBYTES)
     (gpu-draw! (* N 3))
     (gpu-flush!))))
