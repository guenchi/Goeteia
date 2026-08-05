;; expect: #t
;; (gfx gltf) extended vertex attributes + material texture slots.
;; Two primitives in one GLB:
;;   A  static:  POSITION + TEXCOORD_0 + TANGENT + COLOR_0 (u8 norm,
;;      VEC4); material carries normal/emissive/occlusion textures
;;      and an emissiveFactor
;;   B  skinned: POSITION + COLOR_0 (f32 VEC3 -> alpha fills as 1)
;;      + JOINTS_0/WEIGHTS_0
;; The interleave follows the canonical attribute order
;;   position normal uv tangent color joints weights
;; so A lands at stride 64 with tangent@32/color@48, and B at stride
;; 80 with color@32/joints@48/weights@64.  gprim-layout names the
;; attributes present, in order -- the exact contract a matching
;; shader must declare.
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
(define (str! s)
  (string-for-each (lambda (c) (b! (char->integer c))) s))

;; ---- BIN layout ----
;; 0    posA 36 | 36 uvA 24 | 60 tanA 48 | 108 colA 12 | 120 idxA 6+2
;; 128  posB 36 | 164 colB 36 | 200 jB 12 | 212 wB 48 | 260 idxB 6+2
;; 268  img0 4 | 272 img1 4
(define binlen 276)

(define json-text
  (string-append
   "{\"asset\":{\"version\":\"2.0\"},\"scene\":0,"
   "\"scenes\":[{\"nodes\":[0,1,2]}],"
   "\"nodes\":[{\"mesh\":0},{\"mesh\":1,\"skin\":0},{\"name\":\"j\"}],"
   "\"skins\":[{\"joints\":[2]}],"
   "\"meshes\":["
   "{\"primitives\":[{\"attributes\":{\"POSITION\":0,\"TEXCOORD_0\":1,"
   "\"TANGENT\":2,\"COLOR_0\":3},\"indices\":4,\"material\":0}]},"
   "{\"primitives\":[{\"attributes\":{\"POSITION\":5,\"COLOR_0\":6,"
   "\"JOINTS_0\":7,\"WEIGHTS_0\":8},\"indices\":9}]}],"
   "\"materials\":[{"
   "\"pbrMetallicRoughness\":{\"baseColorFactor\":[1,1,1,1]},"
   "\"normalTexture\":{\"index\":0},"
   "\"emissiveTexture\":{\"index\":1},"
   "\"occlusionTexture\":{\"index\":0},"
   "\"emissiveFactor\":[0.5,0.25,1]}],"
   "\"textures\":[{\"source\":0},{\"source\":1}],"
   "\"images\":[{\"bufferView\":10,\"mimeType\":\"image/png\"},"
   "{\"bufferView\":11,\"mimeType\":\"image/png\"}],"
   "\"buffers\":[{\"byteLength\":276}],"
   "\"bufferViews\":["
   "{\"buffer\":0,\"byteOffset\":0,\"byteLength\":36},"
   "{\"buffer\":0,\"byteOffset\":36,\"byteLength\":24},"
   "{\"buffer\":0,\"byteOffset\":60,\"byteLength\":48},"
   "{\"buffer\":0,\"byteOffset\":108,\"byteLength\":12},"
   "{\"buffer\":0,\"byteOffset\":120,\"byteLength\":6},"
   "{\"buffer\":0,\"byteOffset\":128,\"byteLength\":36},"
   "{\"buffer\":0,\"byteOffset\":164,\"byteLength\":36},"
   "{\"buffer\":0,\"byteOffset\":200,\"byteLength\":12},"
   "{\"buffer\":0,\"byteOffset\":212,\"byteLength\":48},"
   "{\"buffer\":0,\"byteOffset\":260,\"byteLength\":6},"
   "{\"buffer\":0,\"byteOffset\":268,\"byteLength\":4},"
   "{\"buffer\":0,\"byteOffset\":272,\"byteLength\":4}],"
   "\"accessors\":["
   "{\"bufferView\":0,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"},"
   "{\"bufferView\":1,\"componentType\":5126,\"count\":3,\"type\":\"VEC2\"},"
   "{\"bufferView\":2,\"componentType\":5126,\"count\":3,\"type\":\"VEC4\"},"
   "{\"bufferView\":3,\"componentType\":5121,\"normalized\":true,"
   "\"count\":3,\"type\":\"VEC4\"},"
   "{\"bufferView\":4,\"componentType\":5123,\"count\":3,\"type\":\"SCALAR\"},"
   "{\"bufferView\":5,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"},"
   "{\"bufferView\":6,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"},"
   "{\"bufferView\":7,\"componentType\":5121,\"count\":3,\"type\":\"VEC4\"},"
   "{\"bufferView\":8,\"componentType\":5126,\"count\":3,\"type\":\"VEC4\"},"
   "{\"bufferView\":9,\"componentType\":5123,\"count\":3,\"type\":\"SCALAR\"}]}"))

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
(v3! 0.0 0.0 0.0) (v3! 1.0 0.0 0.0) (v3! 0.0 1.0 0.0)   ; posA
(f32! 0.0) (f32! 0.0) (f32! 1.0) (f32! 0.0)             ; uvA
(f32! 0.0) (f32! 1.0)
(f32! 1.0) (f32! 0.0) (f32! 0.0) (f32! -1.0)            ; tanA x3
(f32! 1.0) (f32! 0.0) (f32! 0.0) (f32! -1.0)
(f32! 1.0) (f32! 0.0) (f32! 0.0) (f32! -1.0)
(b! 255) (b! 0) (b! 51) (b! 204)                        ; colA u8 norm
(b! 255) (b! 255) (b! 255) (b! 255)
(b! 255) (b! 255) (b! 255) (b! 255)
(u16! 0) (u16! 1) (u16! 2) (u16! 0)                     ; idxA + pad
(v3! 0.0 0.0 0.0) (v3! 1.0 0.0 0.0) (v3! 0.0 1.0 0.0)   ; posB
(v3! 0.3 0.6 0.9) (v3! 0.3 0.6 0.9) (v3! 0.3 0.6 0.9)   ; colB VEC3
(let j ((i 0)) (when (< i 12) (b! 0) (j (+ i 1))))      ; jB
(let w ((i 0))                                           ; wB f32
  (when (< i 3)
    (f32! 0.5) (f32! 0.5) (f32! 0.0) (f32! 0.0)
    (w (+ i 1))))
(u16! 0) (u16! 1) (u16! 2) (u16! 0)                     ; idxB + pad
(u32! #xFFFFFFFF) (u32! #xFFFFFFFF)                     ; fake images

(define (near? a b)
  (and (fl<? (fl- a b) 0.00001) (fl<? (fl- b a) 0.00001)))
(define (f32@ p off) (%mem-f32-ref (+ (gprim-vbase p) off)))

(define g (gltf-parse base total))
(define pa (car (gltf-prims g)))
(define pb (cadr (gltf-prims g)))

(define a-ok
  (and (= (gprim-stride pa) 64)
       (equal? (gprim-layout pa) '(position normal uv tangent color))
       (near? (f32@ pa 12) 0.0)          ; defaulted normal +y
       (near? (f32@ pa 16) 1.0)
       (near? (f32@ pa 24) 0.0)          ; uv v0
       (near? (f32@ pa 32) 1.0)          ; tangent v0
       (near? (f32@ pa 36) 0.0)
       (near? (f32@ pa 44) -1.0)
       (near? (f32@ pa 48) 1.0)          ; color v0: 255,0,51,204
       (near? (f32@ pa 52) 0.0)
       (near? (f32@ pa 56) 0.2)
       (near? (f32@ pa 60) 0.8)))

(define a-mat-ok
  (and (= (gprim-normal-img pa) 0)
       (= (gprim-emissive-img pa) 1)
       (= (gprim-occlusion-img pa) 0)
       (near? (vector-ref (gprim-emissive pa) 0) 0.5)
       (near? (vector-ref (gprim-emissive pa) 1) 0.25)
       (near? (vector-ref (gprim-emissive pa) 2) 1.0)))

(define b-ok
  (and (= (gprim-stride pb) 80)
       (equal? (gprim-layout pb)
               '(position normal uv color joints weights))
       (near? (f32@ pb 24) 0.0)          ; uv slot present, zeroed
       (near? (f32@ pb 32) 0.3)          ; VEC3 color, alpha fills 1
       (near? (f32@ pb 36) 0.6)
       (near? (f32@ pb 40) 0.9)
       (near? (f32@ pb 44) 1.0)
       (near? (f32@ pb 48) 0.0)          ; joints (as floats)
       (near? (f32@ pb 64) 0.5)          ; weights
       (near? (f32@ pb 68) 0.5)))

(define plain-ok                          ; no normal/emissive slots
  (and (not (gprim-normal-img pb))
       (not (gprim-emissive-img pb))
       (not (gprim-occlusion-img pb))))

(and a-ok a-mat-ok b-ok plain-ok)
