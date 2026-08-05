;; expect: #t
;; (gfx gltf) animation sampling semantics + quantized skin weights.
;; One skinned GLB built in staging: a triangle bound to one joint
;; (with a morph target), JOINTS_0 as u8, WEIGHTS_0 as normalized u8,
;; and five animations:
;;   "lin"  LINEAR       translation x = 0 -> 10 -> 20 at t = 0,1,2
;;   "stp"  STEP         same values -- holds the left key inside a
;;                       span, takes the right key AT its time
;;   "cub"  CUBICSPLINE  translation keys (1,2,3)/(7,8,9)/(13,14,15)
;;                       at t = 0,2,3, key0's OUT-tangent = (6,6,6),
;;                       every other tangent zero -- discriminates
;;                       the hermite from a lerp AND the span scaling
;;                       AND the m0/m1 (out/in) tangent choice
;;   "cubr" CUBICSPLINE  rotation identity -> 90deg-about-z, zero
;;                       tangents: the hermite midpoint is NOT unit,
;;                       so the written pose discriminates the
;;                       renormalization
;;   "cubw" CUBICSPLINE  morph weights 0 -> 1: the output accessor
;;                       holds 3*nk scalars, so ncomp must divide by
;;                       3*nk, not nk
;; Also: normalized-u8 weights dequantize to 0.2/0.8 in the stream.
;; (t = duration wraps to 0 by design, so edges probe interior keys.)
(import (rnrs) (web js) (gfx gl) (gfx fx) (gfx mat) (gfx gltf))

(define base (fx-alloc! 8192))
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
(define (v4! x y z w) (f32! x) (f32! y) (f32! z) (f32! w))
(define (str! s)
  (string-for-each (lambda (c) (b! (char->integer c))) s))

;; ---- binary chunk layout (offsets within BIN) ----
;; 0   positions   3 x vec3        = 36
;; 36  joints      3 x 4 u8        = 12
;; 48  weights     3 x 4 u8 norm   = 12
;; 60  indices     3 x u16 + pad   = 8
;; 68  times3      3 x f32 (0,1,2) = 12
;; 80  lin vals    3 x vec3        = 36
;; 116 cub vals    9 x vec3        = 108
;; 224 cub times   3 x f32 (0,2,3) = 12
;; 236 cubr vals   6 x vec4        = 96
;; 332 times2      2 x f32 (0,1)   = 8
;; 340 morph delta 3 x vec3        = 36
;; 376 cubw vals   6 x f32         = 24
(define binlen 400)

(define json-text
  (string-append
   "{\"asset\":{\"version\":\"2.0\"},\"scene\":0,"
   "\"scenes\":[{\"nodes\":[0,1]}],"
   "\"nodes\":[{\"mesh\":0,\"skin\":0},{\"name\":\"j\"}],"
   "\"skins\":[{\"joints\":[1]}],"
   "\"meshes\":[{\"primitives\":[{\"attributes\":"
   "{\"POSITION\":0,\"JOINTS_0\":1,\"WEIGHTS_0\":2},\"indices\":3,"
   "\"targets\":[{\"POSITION\":11}]}]}],"
   "\"animations\":["
   "{\"name\":\"lin\",\"samplers\":[{\"input\":4,\"output\":5,"
   "\"interpolation\":\"LINEAR\"}],"
   "\"channels\":[{\"sampler\":0,\"target\":"
   "{\"node\":1,\"path\":\"translation\"}}]},"
   "{\"name\":\"stp\",\"samplers\":[{\"input\":4,\"output\":5,"
   "\"interpolation\":\"STEP\"}],"
   "\"channels\":[{\"sampler\":0,\"target\":"
   "{\"node\":1,\"path\":\"translation\"}}]},"
   "{\"name\":\"cub\",\"samplers\":[{\"input\":7,\"output\":6,"
   "\"interpolation\":\"CUBICSPLINE\"}],"
   "\"channels\":[{\"sampler\":0,\"target\":"
   "{\"node\":1,\"path\":\"translation\"}}]},"
   "{\"name\":\"cubr\",\"samplers\":[{\"input\":8,\"output\":9,"
   "\"interpolation\":\"CUBICSPLINE\"}],"
   "\"channels\":[{\"sampler\":0,\"target\":"
   "{\"node\":1,\"path\":\"rotation\"}}]},"
   "{\"name\":\"cubw\",\"samplers\":[{\"input\":8,\"output\":10,"
   "\"interpolation\":\"CUBICSPLINE\"}],"
   "\"channels\":[{\"sampler\":0,\"target\":"
   "{\"node\":0,\"path\":\"weights\"}}]}],"
   "\"buffers\":[{\"byteLength\":400}],"
   "\"bufferViews\":["
   "{\"buffer\":0,\"byteOffset\":0,\"byteLength\":36},"
   "{\"buffer\":0,\"byteOffset\":36,\"byteLength\":12},"
   "{\"buffer\":0,\"byteOffset\":48,\"byteLength\":12},"
   "{\"buffer\":0,\"byteOffset\":60,\"byteLength\":6},"
   "{\"buffer\":0,\"byteOffset\":68,\"byteLength\":12},"
   "{\"buffer\":0,\"byteOffset\":80,\"byteLength\":36},"
   "{\"buffer\":0,\"byteOffset\":116,\"byteLength\":108},"
   "{\"buffer\":0,\"byteOffset\":224,\"byteLength\":12},"
   "{\"buffer\":0,\"byteOffset\":332,\"byteLength\":8},"
   "{\"buffer\":0,\"byteOffset\":236,\"byteLength\":96},"
   "{\"buffer\":0,\"byteOffset\":376,\"byteLength\":24},"
   "{\"buffer\":0,\"byteOffset\":340,\"byteLength\":36}],"
   "\"accessors\":["
   "{\"bufferView\":0,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"},"
   "{\"bufferView\":1,\"componentType\":5121,\"count\":3,\"type\":\"VEC4\"},"
   "{\"bufferView\":2,\"componentType\":5121,\"normalized\":true,"
   "\"count\":3,\"type\":\"VEC4\"},"
   "{\"bufferView\":3,\"componentType\":5123,\"count\":3,\"type\":\"SCALAR\"},"
   "{\"bufferView\":4,\"componentType\":5126,\"count\":3,\"type\":\"SCALAR\"},"
   "{\"bufferView\":5,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"},"
   "{\"bufferView\":6,\"componentType\":5126,\"count\":9,\"type\":\"VEC3\"},"
   "{\"bufferView\":7,\"componentType\":5126,\"count\":3,\"type\":\"SCALAR\"},"
   "{\"bufferView\":8,\"componentType\":5126,\"count\":2,\"type\":\"SCALAR\"},"
   "{\"bufferView\":9,\"componentType\":5126,\"count\":6,\"type\":\"VEC4\"},"
   "{\"bufferView\":10,\"componentType\":5126,\"count\":6,\"type\":\"SCALAR\"},"
   "{\"bufferView\":11,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"}]}"))

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
(f32! 0.0) (f32! 1.0) (f32! 2.0)                         ; times3
(v3! 0.0 0.0 0.0) (v3! 10.0 0.0 0.0) (v3! 20.0 0.0 0.0) ; lin/stp
(v3! 0.0 0.0 0.0) (v3! 1.0 2.0 3.0) (v3! 6.0 6.0 6.0)   ; cub k0: in v OUT
(v3! 0.0 0.0 0.0) (v3! 7.0 8.0 9.0) (v3! 0.0 0.0 0.0)   ; cub k1
(v3! 0.0 0.0 0.0) (v3! 13.0 14.0 15.0) (v3! 0.0 0.0 0.0); cub k2
(f32! 0.0) (f32! 2.0) (f32! 3.0)                         ; cub times
(v4! 0.0 0.0 0.0 0.0) (v4! 0.0 0.0 0.0 1.0)              ; cubr k0
(v4! 0.0 0.0 0.0 0.0)
(v4! 0.0 0.0 0.0 0.0)                                    ; cubr k1
(v4! 0.0 0.0 0.70710678 0.70710678)
(v4! 0.0 0.0 0.0 0.0)
(f32! 0.0) (f32! 1.0)                                    ; times2
(v3! 0.0 0.0 1.0) (v3! 0.0 0.0 1.0) (v3! 0.0 0.0 1.0)   ; morph deltas
(f32! 0.0) (f32! 0.0) (f32! 0.0)                         ; cubw k0: in v out
(f32! 0.0) (f32! 1.0) (f32! 0.0)                         ; cubw k1

(define (near? a b)
  (and (fl<? (fl- a b) 0.0001) (fl<? (fl- b a) 0.0001)))

(define g (gltf-parse base total))
(define p1 (car (gltf-prims g)))

;; joint 0's palette matrix: IBM defaults to identity, so it IS the
;; joint node's local transform
(define (joint-m)
  (vector-ref (gltf-joint-matrices g 0) 0))

(define (sampled anim t)
  (gltf-animate! g anim t)
  (let ((m (joint-m)))
    (vector (vector-ref m 12) (vector-ref m 13) (vector-ref m 14))))

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

;; hermite in span [0,2] at t=1 (a=.5, span=2): h00=.5 h01=.5
;; h10=.125*span; key0 out-tangent (6,6,6), key1 in-tangent zero:
;;   x = .5*1 + .125*2*6 + .5*7  = 5.5   (a lerp would give 4)
;;   y = .5*2 + 1.5      + .5*8  = 6.5
;;   z = .5*3 + 1.5      + .5*9  = 7.5
;; span [2,3] has zero tangents: t=2.5 is the plain midpoint
(define cub-ok
  (let ((a (sampled 2 0.0))
        (b (sampled 2 1.0))
        (c (sampled 2 2.5)))
    (and (near? (vector-ref a 0) 1.0)        ; the VALUE element,
         (near? (vector-ref a 1) 2.0)        ; not the in-tangent
         (near? (vector-ref a 2) 3.0)
         (near? (vector-ref b 0) 5.5)
         (near? (vector-ref b 1) 6.5)
         (near? (vector-ref b 2) 7.5)
         (near? (vector-ref c 0) 10.0)
         (near? (vector-ref c 1) 11.0)
         (near? (vector-ref c 2) 12.0))))

;; cubic rotation: identity -> 90deg about z, zero tangents.  The
;; hermite midpoint (0,0,.35355,.85355) is NOT unit; only after
;; renormalization does the pose become the 45-degree rotation with
;; m[0] = m[1] = cos45.  (An unnormalized write gives m[0] = .75.)
(define cubr-ok
  (begin
    (gltf-animate! g 3 0.5)
    (let ((m (joint-m)))
      (and (near? (vector-ref m 0) 0.70710678)
           (near? (vector-ref m 1) 0.70710678)))))

;; cubic morph weights: 6 scalars = 2 keys x (in value out) x 1
;; target -- ncomp divides by 3*nk.  Midpoint of 0 -> 1 is .5.
(define cubw-ok
  (begin
    (gltf-animate! g 4 0.5)
    (near? (vector-ref (vector-ref (gprim-morph p1) 2) 0) 0.5)))

;; ---- a second GLB: sub-epsilon spans, off-midpoint rotation,
;; and a crossfade between clips with DIFFERENT channel sets ----
(let pad ((i 0)) (when (< i (remainder (- 4 (remainder at 4)) 4))
                   (b! 0) (pad (+ i 1))))
(define base2 (+ base at))
(define at2-start at)

;; BIN: 0 pos(36) | 36 joints(12) | 48 weights(48) | 96 idx(6) |
;;      104 tiny-times(8) | 112 tiny-vals(24) | 136 times(8) |
;;      144 rot-vals(32) | 176 ta-vals(24)
(define binlen2 248)
(define json2
  (string-append
   "{\"asset\":{\"version\":\"2.0\"},\"scene\":0,"
   "\"scenes\":[{\"nodes\":[0,1]}],"
   "\"nodes\":[{\"mesh\":0,\"skin\":0},"
   "{\"name\":\"j\",\"translation\":[7,0,0]}],"
   "\"skins\":[{\"joints\":[1]}],"
   "\"meshes\":[{\"primitives\":[{\"attributes\":"
   "{\"POSITION\":0,\"JOINTS_0\":1,\"WEIGHTS_0\":2},\"indices\":3}]}],"
   "\"animations\":["
   "{\"name\":\"tiny\",\"samplers\":[{\"input\":4,\"output\":5,"
   "\"interpolation\":\"LINEAR\"}],\"channels\":[{\"sampler\":0,"
   "\"target\":{\"node\":1,\"path\":\"translation\"}}]},"
   "{\"name\":\"rot\",\"samplers\":[{\"input\":6,\"output\":7,"
   "\"interpolation\":\"LINEAR\"}],\"channels\":[{\"sampler\":0,"
   "\"target\":{\"node\":1,\"path\":\"rotation\"}}]},"
   "{\"name\":\"ta\",\"samplers\":[{\"input\":6,\"output\":8,"
   "\"interpolation\":\"LINEAR\"}],\"channels\":[{\"sampler\":0,"
   "\"target\":{\"node\":1,\"path\":\"translation\"}}]},"
   "{\"name\":\"dup\",\"samplers\":[{\"input\":9,\"output\":10,"
   "\"interpolation\":\"LINEAR\"}],\"channels\":[{\"sampler\":0,"
   "\"target\":{\"node\":1,\"path\":\"translation\"}}]},"
   "{\"name\":\"n0\",\"samplers\":[{\"input\":6,\"output\":8,"
   "\"interpolation\":\"LINEAR\"}],\"channels\":[{\"sampler\":0,"
   "\"target\":{\"node\":0,\"path\":\"translation\"}}]}],"
   "\"buffers\":[{\"byteLength\":248}],"
   "\"bufferViews\":["
   "{\"buffer\":0,\"byteOffset\":0,\"byteLength\":36},"
   "{\"buffer\":0,\"byteOffset\":36,\"byteLength\":12},"
   "{\"buffer\":0,\"byteOffset\":48,\"byteLength\":48},"
   "{\"buffer\":0,\"byteOffset\":96,\"byteLength\":6},"
   "{\"buffer\":0,\"byteOffset\":104,\"byteLength\":8},"
   "{\"buffer\":0,\"byteOffset\":112,\"byteLength\":24},"
   "{\"buffer\":0,\"byteOffset\":136,\"byteLength\":8},"
   "{\"buffer\":0,\"byteOffset\":144,\"byteLength\":32},"
   "{\"buffer\":0,\"byteOffset\":176,\"byteLength\":24},"
   "{\"buffer\":0,\"byteOffset\":200,\"byteLength\":12},"
   "{\"buffer\":0,\"byteOffset\":212,\"byteLength\":36}],"
   "\"accessors\":["
   "{\"bufferView\":0,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"},"
   "{\"bufferView\":1,\"componentType\":5121,\"count\":3,\"type\":\"VEC4\"},"
   "{\"bufferView\":2,\"componentType\":5126,\"count\":3,\"type\":\"VEC4\"},"
   "{\"bufferView\":3,\"componentType\":5123,\"count\":3,\"type\":\"SCALAR\"},"
   "{\"bufferView\":4,\"componentType\":5126,\"count\":2,\"type\":\"SCALAR\"},"
   "{\"bufferView\":5,\"componentType\":5126,\"count\":2,\"type\":\"VEC3\"},"
   "{\"bufferView\":6,\"componentType\":5126,\"count\":2,\"type\":\"SCALAR\"},"
   "{\"bufferView\":7,\"componentType\":5126,\"count\":2,\"type\":\"VEC4\"},"
   "{\"bufferView\":8,\"componentType\":5126,\"count\":2,\"type\":\"VEC3\"},"
   "{\"bufferView\":9,\"componentType\":5126,\"count\":3,\"type\":\"SCALAR\"},"
   "{\"bufferView\":10,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"}]}"))

(define jlen2 (string-length json2))
(define jpad2 (remainder (- 4 (remainder jlen2 4)) 4))
(define total2 (+ 12 8 jlen2 jpad2 8 binlen2))
(u32! #x46546C67)
(u32! 2)
(u32! total2)
(u32! (+ jlen2 jpad2))
(u32! #x4E4F534A)
(str! json2)
(let pad ((i 0)) (when (< i jpad2) (b! 32) (pad (+ i 1))))
(u32! binlen2)
(u32! #x004E4942)
(v3! 0.0 0.0 0.0) (v3! 1.0 0.0 0.0) (v3! 0.0 1.0 0.0)
(let j ((i 0)) (when (< i 12) (b! 0) (j (+ i 1))))
(let w ((i 0))
  (when (< i 3)
    (f32! 1.0) (f32! 0.0) (f32! 0.0) (f32! 0.0)
    (w (+ i 1))))
(u16! 0) (u16! 1) (u16! 2) (u16! 0)
(f32! 0.0) (f32! 0.0000005)               ; tiny times: a legal span
(v3! 0.0 0.0 0.0) (v3! 1.0 0.0 0.0)       ; tiny values
(f32! 0.0) (f32! 1.0)                     ; times
(v4! 0.0 0.0 0.0 1.0)                     ; rot: identity ->
(v4! 0.0 0.0 1.0 0.0)                     ;      180 deg about z
(v3! 0.0 0.0 0.0) (v3! 5.0 0.0 0.0)       ; ta values
(f32! 0.0) (f32! 0.0) (f32! 1.0)          ; dup times: t0 == t1
(v3! 3.0 0.0 0.0) (v3! 3.0 0.0 0.0) (v3! 7.0 0.0 0.0)

(define g2 (gltf-parse base2 total2))

(define (joint2-m)
  (vector-ref (gltf-joint-matrices g2 0) 0))

;; a span far below 1e-6 is legal glTF: it must still interpolate
(define tiny-span-ok
  (begin
    (gltf-animate! g2 0 0.00000025)
    (near? (vector-ref (joint2-m) 12) 0.5)))

;; LINEAR rotation interpolates by shortest-path NLERP, a documented
;; deviation from the spec's SHOULD-be-slerp: the path is the same
;; great arc, only the angular rate differs, and it is unobservable
;; at keyframe spacing.  This locks the choice down -- a quarter of
;; the way from identity to 180 degrees lands at nlerp's 36.87
;; degrees (m[0] = 0.8), where slerp would give 45 (0.7071).  If
;; anyone implements slerp, this goes red and the module doc's
;; "known deviations" note must change with it.
(define nlerp-contract-ok
  (begin
    (gltf-animate! g2 1 0.25)
    (near? (vector-ref (joint2-m) 0) 0.8)))

;; every clip poses COMPLETELY: switching to a clip that does not
;; drive translation must return translation to bind, not keep the
;; previous clip's value
(define complete-pose-ok
  (begin
    (gltf-animate! g2 2 0.5)               ; "ta": translation = 2.5
    (and (near? (vector-ref (joint2-m) 12) 2.5)
         (begin
           (gltf-animate! g2 1 0.5)        ; "rot" drives rotation only
           (near? (vector-ref (joint2-m) 12) 7.0)))))  ; the ASSET bind

;; crossfading INTO a clip that lacks a channel must return that
;; channel to the bind pose, not leave the previous clip's value
(define crossfade-default-ok
  (begin
    (gltf-animate! g2 2 0.5)               ; "ta": translation = 2.5
    (gltf-animate-blend! g2 2 0.5 1 0.5 1.0)  ; fully into "rot"
    (let ((m (joint2-m)))
      (and (near? (vector-ref m 12) 7.0)   ; translation back to bind
           (near? (vector-ref m 0) 0.0)))))  ; rot at t=.5 = 90 deg

;; ... and the same holds for the clip being faded FROM: posing A
;; must start from bind too, or a channel A does not drive carries
;; whatever ran before into the blend
(define crossfade-from-ok
  (begin
    (gltf-animate! g2 2 0.5)               ; "ta": translation = 2.5
    (gltf-animate-blend! g2 1 0.5 2 0.5 0.0)  ; fully "rot" (A side)
    (near? (vector-ref (joint2-m) 12) 7.0)))

;; a duplicated timestamp gives a zero span at k /= k1.  It is a
;; validator error but a common exporter artifact, and it must
;; degrade to holding the left key -- dividing by the zero span
;; would put a NaN in the node TRS, and every descendant's
;; u_mvp/u_model inherits it.
(define dup-time-ok
  (begin
    (gltf-animate! g2 3 0.0)
    (near? (vector-ref (joint2-m) 12) 3.0)))

;; when a crossfade COMPLETES, the outgoing clip's nodes must go
;; back to bind too.  Clips "ta" (node 1) and "n0" (node 0) drive
;; disjoint nodes, so after settling into n0 nothing may still hold
;; node 1 at ta's pose.
(define fade-settle-ok
  (let ((m (anim-machine g2 '((a . 2) (b . 4)) 0.1)))
    (anim-update! m 0.5)                 ; playing "ta": node1 = 2.5
    (and (near? (vector-ref (joint2-m) 12) 2.5)
         (begin
           (anim-goto! m 'b)
           (anim-update! m 0.5)          ; past the fade: settled on n0
           (near? (vector-ref (joint2-m) 12) 7.0)))))

;; the union of two clips' touched nodes visits each node ONCE.
;; "ta" and "rot" BOTH touch node 1, so without dedup the blend runs
;; twice on it: lerp(2.5, 0, .5) = 1.25 the first time, then
;; lerp(2.5, 1.25, .5) = 1.875 the second.  (A mid k is required --
;; at k = 0 or 1 a second pass is idempotent and proves nothing.)
(define union-dedup-ok
  (begin
    (gltf-animate-blend! g2 2 0.5 1 0.5 0.5)
    (near? (vector-ref (joint2-m) 12) 4.75)))

;; interrupting a live transition must not abandon the clip being
;; faded OUT of.  "ta" drives node 1; states b and c both run "n0",
;; which drives node 0 only.  Going ta -> b and then, mid-fade,
;; b -> c means NOTHING touches node 1 again -- so unless the
;; interrupted source is released, node 1 keeps ta's last blended
;; value forever instead of returning to bind.
(define interrupt-ok
  (let ((m (anim-machine g2 '((a . 2) (b . 4) (c . 4)) 1.0)))
    (anim-update! m 0.5)                 ; "ta": node1 translation
    (anim-goto! m 'b)
    (anim-update! m 0.25)                ; mid-fade into n0
    (anim-goto! m 'c)                    ; interrupt: source dropped
    (anim-update! m 2.0)                 ; settle
    (near? (vector-ref (joint2-m) 12) 7.0)))

(and interrupt-ok union-dedup-ok
     weights-ok lin-ok stp-ok cub-ok cubr-ok cubw-ok
     tiny-span-ok nlerp-contract-ok complete-pose-ok
     crossfade-default-ok crossfade-from-ok dup-time-ok
     fade-settle-ok)
