;; expect: #t
;; Tightly packed quantized attributes, and the morph paths that
;; read them.  Two GLBs:
;;
;; Q  KHR_mesh_quantization with NO byteStride anywhere -- U16 VEC3
;;    positions (tight stride 6, not 12), normalized I8 VEC3 normals
;;    (3, not 12), normalized U16 VEC2 uvs (4, not 8).  Vertex 0
;;    reads correctly under any stride; vertices 1 and 2 are the
;;    discriminator.  The mesh also carries two morph targets and a
;;    node-level weights override, so the morph base must come from
;;    the DEQUANTIZED stream (reading the raw u16 bytes as f32 gives
;;    denormals) and node.weights must beat mesh.weights.
;;
;; W  a morph-weight animation whose output accessor rides a
;;    bufferView with byteStride 8 -- each scalar element is 8 bytes
;;    apart, with poison in the padding.  Component j of a key must
;;    step by the accessor stride, not by 4.
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
(define (i8! v) (b! (if (< v 0) (+ v 256) v)))
(define (pad-to! n) (let loop () (when (< at n) (b! 0) (loop))))
(define (str! s)
  (string-for-each (lambda (c) (b! (char->integer c))) s))

(define (glb! json binlen fill!)
  (let* ((jlen (string-length json))
         (jpad (remainder (- 4 (remainder jlen 4)) 4))
         (total (+ 12 8 jlen jpad 8 binlen))
         (start at))
    (u32! #x46546C67)
    (u32! 2)
    (u32! total)
    (u32! (+ jlen jpad))
    (u32! #x4E4F534A)
    (str! json)
    (let pad ((i 0)) (when (< i jpad) (b! 32) (pad (+ i 1))))
    (u32! binlen)
    (u32! #x004E4942)
    (let ((bin-start at))
      (fill! bin-start)
      (pad-to! (+ bin-start binlen)))
    (cons (+ base start) total)))

;; ---- Q: quantized, tightly packed, with morphs ----
;; BIN: 0 pos(18) | 20 nrm(9) | 32 uv(12) | 44 idx(6) |
;;      52 target0(36) | 88 target1(36)
(define q-loc
  (glb!
   (string-append
    "{\"asset\":{\"version\":\"2.0\"},\"scene\":0,"
    "\"extensionsUsed\":[\"KHR_mesh_quantization\"],"
    "\"scenes\":[{\"nodes\":[0]}],"
    "\"nodes\":[{\"mesh\":0,\"weights\":[0.5,0.25]}],"
    "\"meshes\":[{\"weights\":[0,0],\"primitives\":[{\"attributes\":"
    "{\"POSITION\":0,\"NORMAL\":1,\"TEXCOORD_0\":2},\"indices\":3,"
    "\"targets\":[{\"POSITION\":4},{\"POSITION\":5}]}]}],"
    "\"buffers\":[{\"byteLength\":124}],"
    "\"bufferViews\":["
    "{\"buffer\":0,\"byteOffset\":0,\"byteLength\":18},"
    "{\"buffer\":0,\"byteOffset\":20,\"byteLength\":9},"
    "{\"buffer\":0,\"byteOffset\":32,\"byteLength\":12},"
    "{\"buffer\":0,\"byteOffset\":44,\"byteLength\":6},"
    "{\"buffer\":0,\"byteOffset\":52,\"byteLength\":36},"
    "{\"buffer\":0,\"byteOffset\":88,\"byteLength\":9}],"
    "\"accessors\":["
    "{\"bufferView\":0,\"componentType\":5123,\"count\":3,\"type\":\"VEC3\"},"
    "{\"bufferView\":1,\"componentType\":5120,\"normalized\":true,"
    "\"count\":3,\"type\":\"VEC3\"},"
    "{\"bufferView\":2,\"componentType\":5123,\"normalized\":true,"
    "\"count\":3,\"type\":\"VEC2\"},"
    "{\"bufferView\":3,\"componentType\":5123,\"count\":3,\"type\":\"SCALAR\"},"
    "{\"bufferView\":4,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"},"
    "{\"bufferView\":5,\"componentType\":5120,\"normalized\":true,"
    "\"count\":3,\"type\":\"VEC3\"}]}")
   124
   (lambda (bin)
     (u16! 100) (u16! 200) (u16! 300)      ; pos v0
     (u16! 400) (u16! 500) (u16! 600)      ; v1
     (u16! 700) (u16! 800) (u16! 900)      ; v2
     (pad-to! (+ bin 20))
     (i8! 0) (i8! 127) (i8! 0)             ; nrm v0 = +y
     (i8! 127) (i8! 0) (i8! 0)             ; v1 = +x
     (i8! 0) (i8! 0) (i8! -127)            ; v2 = -z
     (pad-to! (+ bin 32))
     (u16! 0) (u16! 0)                     ; uv v0 = (0,0)
     (u16! 65535) (u16! 0)                 ; v1 = (1,0)
     (u16! 0) (u16! 65535)                 ; v2 = (0,1)
     (u16! 0) (u16! 1) (u16! 2)            ; indices
     (pad-to! (+ bin 52))
     (v3! 10.0 0.0 0.0) (v3! 10.0 0.0 0.0) (v3! 10.0 0.0 0.0)
     ;; target 1 is normalized i8: 127 -> 1.0 per component.  The
     ;; three vertices differ (and include a negative) so a decoder
     ;; that never advances past vertex 0 cannot pass.
     (i8! 0) (i8! 127) (i8! 0)
     (i8! 127) (i8! 0) (i8! -127)
     (i8! -127) (i8! 64) (i8! 127))))

;; ---- W: morph weights animated through a strided accessor ----
;; BIN: 0 pos(36) | 36 idx(6) | 44 times(8) | 52 weights(32) |
;;      84 target0(36) | 120 target1(36)
(define w-loc
  (glb!
   (string-append
    "{\"asset\":{\"version\":\"2.0\"},\"scene\":0,"
    "\"scenes\":[{\"nodes\":[0]}],"
    "\"nodes\":[{\"mesh\":0,\"weights\":[0.3,0.1]}],"
    "\"meshes\":[{\"primitives\":[{\"attributes\":{\"POSITION\":0},"
    "\"indices\":1,\"targets\":[{\"POSITION\":4},{\"POSITION\":5}]}]}],"
    "\"animations\":[{\"name\":\"w\","
    "\"samplers\":[{\"input\":2,\"output\":3,"
    "\"interpolation\":\"LINEAR\"}],"
    "\"channels\":[{\"sampler\":0,\"target\":"
    "{\"node\":0,\"path\":\"weights\"}}]},"
    "{\"name\":\"move\","
    "\"samplers\":[{\"input\":2,\"output\":6,"
    "\"interpolation\":\"LINEAR\"}],"
    "\"channels\":[{\"sampler\":0,\"target\":"
    "{\"node\":0,\"path\":\"translation\"}}]}],"
    "\"buffers\":[{\"byteLength\":180}],"
    "\"bufferViews\":["
    "{\"buffer\":0,\"byteOffset\":0,\"byteLength\":36},"
    "{\"buffer\":0,\"byteOffset\":36,\"byteLength\":6},"
    "{\"buffer\":0,\"byteOffset\":44,\"byteLength\":8},"
    "{\"buffer\":0,\"byteOffset\":52,\"byteLength\":32,\"byteStride\":8},"
    "{\"buffer\":0,\"byteOffset\":84,\"byteLength\":36},"
    "{\"buffer\":0,\"byteOffset\":120,\"byteLength\":36},"
    "{\"buffer\":0,\"byteOffset\":156,\"byteLength\":24}],"
    "\"accessors\":["
    "{\"bufferView\":0,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"},"
    "{\"bufferView\":1,\"componentType\":5123,\"count\":3,\"type\":\"SCALAR\"},"
    "{\"bufferView\":2,\"componentType\":5126,\"count\":2,\"type\":\"SCALAR\"},"
    "{\"bufferView\":3,\"componentType\":5126,\"count\":4,\"type\":\"SCALAR\"},"
    "{\"bufferView\":4,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"},"
    "{\"bufferView\":5,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"},"
    "{\"bufferView\":6,\"componentType\":5126,\"count\":2,\"type\":\"VEC3\"}]}")
   180
   (lambda (bin)
     (v3! 0.0 0.0 0.0) (v3! 1.0 0.0 0.0) (v3! 0.0 1.0 0.0)
     (u16! 0) (u16! 1) (u16! 2)
     (pad-to! (+ bin 44))
     (f32! 0.0) (f32! 1.0)                 ; times
     ;; key0: w0 @52, w1 @60; key1: w0 @68, w1 @76 -- poison between
     (f32! 0.0) (f32! 999.0)
     (f32! 0.0) (f32! 999.0)
     (f32! 1.0) (f32! 999.0)
     (f32! 0.5) (f32! 999.0)
     (v3! 10.0 0.0 0.0) (v3! 10.0 0.0 0.0) (v3! 10.0 0.0 0.0)
     (v3! 0.0 20.0 0.0) (v3! 0.0 20.0 0.0) (v3! 0.0 20.0 0.0)
     (v3! 0.0 0.0 0.0) (v3! 9.0 0.0 0.0))))     ; "move" translation

(define (near? a b)
  (and (fl<? (fl- a b) 0.001) (fl<? (fl- b a) 0.001)))

(define gq (gltf-parse (car q-loc) (cdr q-loc)))
(define pq (car (gltf-prims gq)))
(define (q@ v off) (%mem-f32-ref (+ (gprim-vbase pq) (* v 32) off)))

;; vertex 1 and 2 only land right when each attribute's tight stride
;; follows its component type (6 / 3 / 4, not 12 / 12 / 8)
(define pos-ok
  (and (near? (q@ 0 0) 100.0) (near? (q@ 0 4) 200.0)
       (near? (q@ 1 0) 400.0) (near? (q@ 1 4) 500.0)
       (near? (q@ 1 8) 600.0)
       (near? (q@ 2 0) 700.0) (near? (q@ 2 8) 900.0)))

(define nrm-ok
  (and (near? (q@ 0 16) 1.0)              ; v0 = +y
       (near? (q@ 1 12) 1.0)              ; v1 = +x
       (near? (q@ 1 16) 0.0)
       (near? (q@ 2 20) -1.0)))           ; v2 = -z, signed i8

(define uv-ok
  (and (near? (q@ 0 24) 0.0)
       (near? (q@ 1 24) 1.0) (near? (q@ 1 28) 0.0)
       (near? (q@ 2 24) 0.0) (near? (q@ 2 28) 1.0)))

;; the morph base holds DEQUANTIZED positions: reading the raw u16
;; bytes as f32 would give denormals near zero
(define morph-base-ok
  (let ((b (vector-ref (gprim-morph pq) 0)))
    (and (near? (vector-ref b 0) 100.0)
         (near? (vector-ref b 3) 400.0)
         (near? (vector-ref b 6) 700.0))))

;; node.weights overrides mesh.weights
(define node-weights-ok
  (let ((w (vector-ref (gprim-morph pq) 2)))
    (and (near? (vector-ref w 0) 0.5)
         (near? (vector-ref w 1) 0.25))))

(define gw (gltf-parse (car w-loc) (cdr w-loc)))
(define pw (car (gltf-prims gw)))

;; component j of a weights key steps by the accessor stride
;; (t = duration wraps to 0, so sample the interior)
(define strided-weights-ok
  (begin
    (gltf-animate! gw 0 0.5)
    (let ((w (vector-ref (gprim-morph pw) 2)))
      (and (near? (vector-ref w 0) 0.5)     ; lerp of 0 -> 1
           (near? (vector-ref w 1) 0.25))))) ; lerp of 0 -> .5, and
                                             ; NOT the 999 poison

;; a clip that touches the node but does NOT drive weights poses
;; them at bind, rather than keeping the previous clip's blend
(define morph-bind-ok
  (begin
    (gltf-animate! gw 0 0.5)               ; "w": weights = .5 / .25
    (gltf-animate! gw 1 0.5)               ; "move": translation only
    (let ((w (vector-ref (gprim-morph pw) 2)))
      (and (near? (vector-ref w 0) 0.3)    ; the ASSET's bind weights,
           (near? (vector-ref w 1) 0.1))))) ; not a hardcoded zero

;; the quantized target dequantizes too: raw i8 read as f32 gives
;; denormals, and a float-strided read walks off the 9-byte view
(define morph-target-quant-ok
  (let ((d (vector-ref (vector-ref (gprim-morph pq) 1) 1)))
    (and (near? (vector-ref d 0) 0.0)      ; v0 = (0, 1, 0)
         (near? (vector-ref d 1) 1.0)
         (near? (vector-ref d 2) 0.0)
         (near? (vector-ref d 3) 1.0)      ; v1 = (1, 0, -1)
         (near? (vector-ref d 4) 0.0)
         (near? (vector-ref d 5) -1.0)
         (near? (vector-ref d 6) -1.0)     ; v2 = (-1, .504, 1)
         (near? (vector-ref d 7) 0.504)
         (near? (vector-ref d 8) 1.0))))

;; morph weights crossfade through the same two-pose scheme as the
;; node TRS: "w" poses them at (.5,.25) and "move" does not drive
;; them at all, so at k = .5 they sit halfway to bind (.3,.1) --
;; (.4,.175).  The dirty check is a contract on the blend as a
;; whole -- the reset inside it already sets the flag, so it does
;; not discriminate $morph-blend!'s own store; it does catch a
;; blend that leaves the vertex buffer stale.
(define morph-crossfade-ok
  (begin
    (vector-set! (gprim-morph pw) 3 #f)    ; clear dirty first
    (gltf-animate-blend! gw 0 0.5 1 0.5 0.5)
    (let ((w (vector-ref (gprim-morph pw) 2)))
      (and (near? (vector-ref w 0) 0.4)
           (near? (vector-ref w 1) 0.175)
           (vector-ref (gprim-morph pw) 3)))))

(and morph-crossfade-ok
     morph-target-quant-ok
     pos-ok nrm-ok uv-ok morph-base-ok node-weights-ok
     strided-weights-ok morph-bind-ok)
