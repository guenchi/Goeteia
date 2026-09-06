;; Reads test/assets/p1.glb, hands everything the reader kept back to
;; the writer -- the re-export recipe of docs/graphics.md extended to
;; the material model, cameras, every skin and morph normals -- and
;; writes the result to the path given as the program's argument.
;; test/glb-p1.mjs checks the written file with tools that never ran
;; the reader.
;; Copyright (c) 2026 guenchi.  MIT license; see LICENSE.
(import (rnrs) (gfx fx) (gfx gltf) (gfx glb) (web fs) (web args))
(define cap 262144)
(define base (fx-alloc! cap))
(define n (fs-slurp! "test/assets/p1.glb" base cap))
(define g (gltf-parse base n))

(define (ref->desc r) (and r (list (gtexref-texture r) (gtexref-texcoord r) (gtexref-factor r))))
(define (node->desc i v)
  (append (list #f (vector-ref v 11)
                (vector (vector-ref v 0) (vector-ref v 1) (vector-ref v 2))
                (vector (vector-ref v 3) (vector-ref v 4) (vector-ref v 5) (vector-ref v 6))
                (vector (vector-ref v 7) (vector-ref v 8) (vector-ref v 9)))
          (let ((c (gltf-node-camera g i))) (if c (list 'camera c) '()))))
(define (chan->desc ch)
  (let* ((path (vector-ref ch 1)) (times (vector-ref ch 2)) (vals (vector-ref ch 3))
         (interp (vector-ref ch 5)) (n (vector-length times))
         (out (if (eq? interp 'cubic)
                  (let ((o (make-vector (* 3 n) #f)))
                    (let loop ((i 0))
                      (if (= i n) o
                          (begin (vector-set! o (* 3 i) (vector-ref (vector-ref ch 6) i))
                                 (vector-set! o (+ (* 3 i) 1) (vector-ref vals i))
                                 (vector-set! o (+ (* 3 i) 2) (vector-ref (vector-ref ch 7) i))
                                 (loop (+ i 1))))))
                  vals)))
    (append (list (vector-ref ch 0) path times out n interp)
            (if (eq? path 'weights) (list 'components (vector-length (vector-ref vals 0))) '()))))
(define (clip->desc a) (list (vector-ref a 0) (map chan->desc (vector->list (vector-ref a 1)))))
(define (prim->desc p mi)
  (append (list (gprim-layout p) (gprim-vbase p) (quotient (gprim-vbytes p) (gprim-stride p))
                (gprim-ibase p) (gprim-icount p)
                'index-u32? (gprim-index-u32? p)
                'node (gprim-node p))
          (if (gprim-skin p) (list 'skin (gprim-skin p)) '())
          (list 'material mi)
          (let ((mo (gprim-morph p)))
            (if mo
                (let* ((ds (vector-ref mo 1)) (dn (gprim-morph-normals p)) (dt (gprim-morph-tangents p)) (nt (vector-length ds)))
                  (list 'targets (let loop ((k 0) (acc '()))
                                   (if (= k nt) (reverse acc)
                                       (loop (+ k 1) (cons (list (vector-ref ds k) (and dn (vector-ref dn k)) (and dt (vector-ref dt k))) acc))))
                        'weights (vector->list (vector-ref mo 5))))
                '()))))
;; one material per primitive, in primitive order: the reader keeps
;; material data on the primitive, so identity is not recoverable
(define materials
  (map (lambda (p)
         ;; the file's own factor (#f when absent), not the rendering fallback
         (list (gprim-base-color-factor p) (cons (gprim-metallic p) (gprim-roughness p)) (gprim-emissive p)
               (ref->desc (gprim-base-tex p)) (ref->desc (gprim-mr-tex p)) (ref->desc (gprim-normal-tex p))
               (ref->desc (gprim-emissive-tex p)) (ref->desc (gprim-occlusion-tex p))))
       (gltf-prims g)))
(define (sampler->desc s) (list (gsampler-mag s) (gsampler-min s) (gsampler-wrap-s s) (gsampler-wrap-t s)))
(define (camera->desc c) (vector->list c))
(define loc
  (glb-write!
   (let loop ((ps (gltf-prims g)) (i 0) (acc '()))
     (if (null? ps) (reverse acc) (loop (cdr ps) (+ i 1) (cons (prim->desc (car ps) i) acc))))
   'nodes (let loop ((i 0) (acc '()))
            (if (= i (gltf-node-count g)) (reverse acc)
                (loop (+ i 1) (cons (node->desc i (vector-ref (gltf-nodes g) i)) acc))))
   'skins (map (lambda (s) (list (vector-ref s 0) (vector-ref s 1))) (vector->list (gltf-skins g)))
   'anims (map clip->desc (vector->list (gltf-anims g)))
   'images (map (lambda (im) (list (car im) (cadr im) (caddr im))) (vector->list (gltf-images g)))
   'samplers (map sampler->desc (vector->list (gltf-samplers g)))
   'textures (vector->list (gltf-textures g))
   'materials materials
   'cameras (map camera->desc (vector->list (gltf-cameras g)))))
(fs-spit! (args-ref 0) (car loc) (cdr loc))
(display "wrote ") (display (cdr loc)) (newline)
