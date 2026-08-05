;; expect: #t
;; (gfx gltf) animation sampling semantics + quantized skin weights.
;; One skinned GLB built in staging: a triangle bound to one joint,
;; JOINTS_0 as u8, WEIGHTS_0 as normalized u8, and three animations
;; over the same three keyframes (t = 0, 1, 2):
;;   "lin"  LINEAR        translation x = 0 -> 10 -> 20
;;   "stp"  STEP          same values -- holds the left key inside a
;;                        span, takes the right key AT its time
;;   "cub"  CUBICSPLINE   zero tangents, (1,2,3)/(7,8,9)/(13,14,15)
;; Checks: normalized-u8 weights dequantize to 0.2/0.8 in the
;; interleaved stream; LINEAR lerps; STEP holds; CUBICSPLINE reads
;; the VALUE element of each in/value/out triple and hermite-blends.
;; (t = duration wraps to 0 by design, so edges probe interior keys.)
(import (rnrs) (web js) (gfx gl) (gfx fx) (gfx mat) (gfx gltf))

(define base (fx-alloc! 4096))
(define at 0)
(define (b! v) (%mem-u8-set! (+ base at) v) (set! at (+ at 1)))
(define (u16! v) (b! (remainder v 256)) (b! (quotient v 256)))
(define (u32! v)
  (b! (remainder v 256))
  (b! (remainder (quotient v 256) 256))
  (b! (remainder (quotient v 65536) 256))
  (b! (quotient v 16777216)))
(define (f32! v) (%mem-f32-set! (+ base at) v) (set! at (+ at 4)))
(define (v3! x y z) (f32! x) (f32! y) (f32! z))
(define (str! s)
  (string-for-each (lambda (c) (b! (char->integer c))) s))

;; ---- binary chunk layout (offsets within BIN) ----
;; 0   positions  3 x vec3 f32   = 36
;; 36  joints     3 x 4 u8       = 12
;; 48  weights    3 x 4 u8 norm  = 12
;; 60  indices    3 x u16 + pad  = 8
;; 68  times      3 x f32        = 12
;; 80  lin vals   3 x vec3       = 36
;; 116 cub vals   9 x vec3       = 108
(define binlen 224)

(define json-text
  (string-append
   "{\"asset\":{\"version\":\"2.0\"},\"scene\":0,"
   "\"scenes\":[{\"nodes\":[0,1]}],"
   "\"nodes\":[{\"mesh\":0,\"skin\":0},{\"name\":\"j\"}],"
   "\"skins\":[{\"joints\":[1]}],"
   "\"meshes\":[{\"primitives\":[{\"attributes\":"
   "{\"POSITION\":0,\"JOINTS_0\":1,\"WEIGHTS_0\":2},\"indices\":3}]}],"
   "\"animations\":["
   "{\"name\":\"lin\",\"samplers\":[{\"input\":4,\"output\":5,"
   "\"interpolation\":\"LINEAR\"}],"
   "\"channels\":[{\"sampler\":0,\"target\":"
   "{\"node\":1,\"path\":\"translation\"}}]},"
   "{\"name\":\"stp\",\"samplers\":[{\"input\":4,\"output\":5,"
   "\"interpolation\":\"STEP\"}],"
   "\"channels\":[{\"sampler\":0,\"target\":"
   "{\"node\":1,\"path\":\"translation\"}}]},"
   "{\"name\":\"cub\",\"samplers\":[{\"input\":4,\"output\":6,"
   "\"interpolation\":\"CUBICSPLINE\"}],"
   "\"channels\":[{\"sampler\":0,\"target\":"
   "{\"node\":1,\"path\":\"translation\"}}]}],"
   "\"buffers\":[{\"byteLength\":224}],"
   "\"bufferViews\":["
   "{\"buffer\":0,\"byteOffset\":0,\"byteLength\":36},"
   "{\"buffer\":0,\"byteOffset\":36,\"byteLength\":12},"
   "{\"buffer\":0,\"byteOffset\":48,\"byteLength\":12},"
   "{\"buffer\":0,\"byteOffset\":60,\"byteLength\":6},"
   "{\"buffer\":0,\"byteOffset\":68,\"byteLength\":12},"
   "{\"buffer\":0,\"byteOffset\":80,\"byteLength\":36},"
   "{\"buffer\":0,\"byteOffset\":116,\"byteLength\":108}],"
   "\"accessors\":["
   "{\"bufferView\":0,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"},"
   "{\"bufferView\":1,\"componentType\":5121,\"count\":3,\"type\":\"VEC4\"},"
   "{\"bufferView\":2,\"componentType\":5121,\"normalized\":true,"
   "\"count\":3,\"type\":\"VEC4\"},"
   "{\"bufferView\":3,\"componentType\":5123,\"count\":3,\"type\":\"SCALAR\"},"
   "{\"bufferView\":4,\"componentType\":5126,\"count\":3,\"type\":\"SCALAR\"},"
   "{\"bufferView\":5,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"},"
   "{\"bufferView\":6,\"componentType\":5126,\"count\":9,\"type\":\"VEC3\"}]}"))

(define jlen (string-length json-text))
(define jpad (remainder (- 4 (remainder jlen 4)) 4))
(define total (+ 12 8 jlen jpad 8 binlen))

(u32! #x46546C67)
(u32! 2)
(u32! total)
(u32! (+ jlen jpad))
(u32! #x4E4F534A)
(str! json-text)
(let pad ((i 0)) (when (< i jpad) (b! 32) (pad (+ i 1))))
(u32! binlen)
(u32! #x004E4942)
(v3! 0.0 0.0 0.0) (v3! 1.0 0.0 0.0) (v3! 0.0 1.0 0.0)   ; positions
(let j ((i 0)) (when (< i 12) (b! 0) (j (+ i 1))))      ; joints: all 0
(let w ((i 0))                                           ; weights u8:
  (when (< i 3)                                          ; 51/255 = .2
    (b! 51) (b! 204) (b! 0) (b! 0)                       ; 204/255 = .8
    (w (+ i 1))))
(u16! 0) (u16! 1) (u16! 2) (u16! 0)                      ; indices + pad
(f32! 0.0) (f32! 1.0) (f32! 2.0)                         ; times
(v3! 0.0 0.0 0.0) (v3! 10.0 0.0 0.0) (v3! 20.0 0.0 0.0) ; lin/stp
(v3! 0.0 0.0 0.0) (v3! 1.0 2.0 3.0) (v3! 0.0 0.0 0.0)   ; cub: in v out
(v3! 0.0 0.0 0.0) (v3! 7.0 8.0 9.0) (v3! 0.0 0.0 0.0)
(v3! 0.0 0.0 0.0) (v3! 13.0 14.0 15.0) (v3! 0.0 0.0 0.0)

(define (near? a b)
  (and (fl<? (fl- a b) 0.00001) (fl<? (fl- b a) 0.00001)))

(define g (gltf-parse base total))
(define p1 (car (gltf-prims g)))

;; joint 0's palette matrix: IBM defaults to identity, so the
;; translation column IS the sampled channel value
(define (joint-x-y-z)
  (let ((m (vector-ref (gltf-joint-matrices g 0) 0)))
    (vector (vector-ref m 12) (vector-ref m 13) (vector-ref m 14))))

(define (sampled anim t)
  (gltf-animate! g anim t)
  (joint-x-y-z))

;; normalized-u8 weights land dequantized in the interleaved stream
(define weights-ok
  (and (near? (%mem-f32-ref (+ (gprim-vbase p1) 48)) 0.2)
       (near? (%mem-f32-ref (+ (gprim-vbase p1) 52)) 0.8)
       (near? (%mem-f32-ref (+ (gprim-vbase p1) 56)) 0.0)))

(define lin-ok
  (and (near? (vector-ref (sampled 0 0.5) 0) 5.0)
       (near? (vector-ref (sampled 0 1.5) 0) 15.0)))

(define stp-ok
  (and (near? (vector-ref (sampled 1 0.5) 0) 0.0)    ; holds key 0
       (near? (vector-ref (sampled 1 1.0) 0) 10.0)   ; takes key 1 AT 1.0
       (near? (vector-ref (sampled 1 1.5) 0) 10.0))) ; holds key 1

(define cub-ok
  (let ((a (sampled 2 0.0))
        (b (sampled 2 0.5))
        (c (sampled 2 1.5)))
    (and (near? (vector-ref a 0) 1.0)        ; the VALUE element,
         (near? (vector-ref a 1) 2.0)        ; not the in-tangent
         (near? (vector-ref a 2) 3.0)
         (near? (vector-ref b 0) 4.0)        ; hermite, zero tangents
         (near? (vector-ref b 1) 5.0)
         (near? (vector-ref b 2) 6.0)
         (near? (vector-ref c 0) 10.0)
         (near? (vector-ref c 1) 11.0)
         (near? (vector-ref c 2) 12.0))))

(and weights-ok lin-ok stp-ok cub-ok)
