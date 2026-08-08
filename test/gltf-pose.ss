;; expect: #t
;; (gfx gltf) hand posing and clamped clip sampling.
;;
;; One skinned GLB in staging: a triangle bound to a two-joint chain,
;; plus a fourth node carrying the MATRIX form of a transform, and one
;; clip "spin" that turns the root joint from identity to 90 degrees
;; about z over exactly one second.
;;
;;   node 0  the mesh, skinned
;;   node 1  "j", the root joint, no explicit TRS  (bind = identity)
;;   node 2  "c", child of 1, translation (1,0,0)  -- the probe: its
;;           global position IS node 1's rotation, read off an axis
;;   node 3  "m", "matrix": identity -- the node the setters refuse
;;
;; skin joints are [1 2] with identity inverse binds, so palette[k] is
;; simply the global of that joint and every expectation below is
;; closed form.  The two joint readers are INDEPENDENT implementations
;; -- gltf-joint-matrices composes boxed m4s through $node-global,
;; gltf-joint-palette! composes in SIMD into staging, parents first --
;; so every pose is checked against both and a write that reached only
;; one of them cannot pass.
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
(define (v4! x y z w) (f32! x) (f32! y) (f32! z) (f32! w))
(define (str! s)
  (string-for-each (lambda (c) (b! (char->integer c))) s))

;; ---- binary chunk layout (offsets within BIN) ----
;; 0   positions   3 x vec3 f32    = 36
;; 36  joints      3 x 4 u8        = 12
;; 48  weights     3 x vec4 f32    = 48
;; 96  indices     3 x u16 + pad   = 8
;; 104 times       2 x f32 (0,1)   = 8
;; 112 rot values  2 x vec4 f32    = 32
;; 144 back times  2 x f32 (-2,2)  = 8
;; 152 back values 2 x vec3 f32    = 24
(define binlen 176)

(define json-text
  (string-append
   "{\"asset\":{\"version\":\"2.0\"},\"scene\":0,"
   "\"scenes\":[{\"nodes\":[0,1,3]}],"
   "\"nodes\":[{\"mesh\":0,\"skin\":0},"
   "{\"name\":\"j\",\"children\":[2]},"
   "{\"name\":\"c\",\"translation\":[1,0,0]},"
   "{\"name\":\"m\",\"matrix\":[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1]}],"
   "\"skins\":[{\"joints\":[1,2]}],"
   "\"meshes\":[{\"primitives\":[{\"attributes\":"
   "{\"POSITION\":0,\"JOINTS_0\":1,\"WEIGHTS_0\":2},\"indices\":3}]}],"
   "\"animations\":["
   "{\"name\":\"spin\",\"samplers\":[{\"input\":4,\"output\":5,"
   "\"interpolation\":\"LINEAR\"}],\"channels\":[{\"sampler\":0,"
   "\"target\":{\"node\":1,\"path\":\"rotation\"}}]},"
   "{\"name\":\"back\",\"samplers\":[{\"input\":6,\"output\":7,"
   "\"interpolation\":\"LINEAR\"}],\"channels\":[{\"sampler\":0,"
   "\"target\":{\"node\":1,\"path\":\"translation\"}}]}],"
   "\"buffers\":[{\"byteLength\":176}],"
   "\"bufferViews\":["
   "{\"buffer\":0,\"byteOffset\":0,\"byteLength\":36},"
   "{\"buffer\":0,\"byteOffset\":36,\"byteLength\":12},"
   "{\"buffer\":0,\"byteOffset\":48,\"byteLength\":48},"
   "{\"buffer\":0,\"byteOffset\":96,\"byteLength\":6},"
   "{\"buffer\":0,\"byteOffset\":104,\"byteLength\":8},"
   "{\"buffer\":0,\"byteOffset\":112,\"byteLength\":32},"
   "{\"buffer\":0,\"byteOffset\":144,\"byteLength\":8},"
   "{\"buffer\":0,\"byteOffset\":152,\"byteLength\":24}],"
   "\"accessors\":["
   "{\"bufferView\":0,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"},"
   "{\"bufferView\":1,\"componentType\":5121,\"count\":3,\"type\":\"VEC4\"},"
   "{\"bufferView\":2,\"componentType\":5126,\"count\":3,\"type\":\"VEC4\"},"
   "{\"bufferView\":3,\"componentType\":5123,\"count\":3,\"type\":\"SCALAR\"},"
   "{\"bufferView\":4,\"componentType\":5126,\"count\":2,\"type\":\"SCALAR\"},"
   "{\"bufferView\":5,\"componentType\":5126,\"count\":2,\"type\":\"VEC4\"},"
   "{\"bufferView\":6,\"componentType\":5126,\"count\":2,\"type\":\"SCALAR\"},"
   "{\"bufferView\":7,\"componentType\":5126,\"count\":2,\"type\":\"VEC3\"}]}"))

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
(let w ((i 0))                                           ; weights
  (when (< i 3)
    (f32! 1.0) (f32! 0.0) (f32! 0.0) (f32! 0.0)
    (w (+ i 1))))
(u16! 0) (u16! 1) (u16! 2) (u16! 0)                     ; indices + pad
(f32! 0.0) (f32! 1.0)                                    ; times
(v4! 0.0 0.0 0.0 1.0)                                    ; identity ->
(v4! 0.0 0.0 0.70710678 0.70710678)                      ; 90 deg / z
(f32! -2.0) (f32! 2.0)                       ; "back" times: keys BEFORE 0
(v3! 0.0 0.0 0.0) (v3! 8.0 0.0 0.0)          ; "back" translation values

(define g (gltf-parse base total))

(define (near? a b)
  (and (fl<? (fl- a b) 0.0001) (fl<? (fl- b a) 0.0001)))

(define (raises? thunk)
  (guard (e (#t #t)) (thunk) #f))

;; ---- the two independent readers of one joint's matrix -----------
;; boxed: global(joint k) x identity inverse bind
(define (boxed-m k) (vector-ref (gltf-joint-matrices g 0) k))

;; SIMD, in staging: the palette gltf-draw! actually uploads.  Read
;; back as a boxed m4 so the two are comparable element by element.
(define (staged-m k)
  (let ((pb (gltf-joint-palette! g 0))
        (m (make-vector 16 0.0)))
    (let l ((i 0))
      (when (< i 16)
        (vector-set! m i (%mem-f32-ref (+ pb (* k 64) (* i 4))))
        (l (+ i 1))))
    m))

(define (m-agree? k)
  (let ((a (boxed-m k)) (b (staged-m k)))
    (let l ((i 0))
      (or (= i 16)
          (and (near? (vector-ref a i) (vector-ref b i)) (l (+ i 1)))))))

;; both readers, one predicate: every expectation is stated once and
;; checked twice, so a write that landed in only one path is a failure
;; rather than a coin flip about which reader the test happened to use
(define (m-is? k . want)
  (and (m-agree? k)
       (let ((m (staged-m k)))
         (let l ((ws want))
           (or (null? ws)
               (and (near? (vector-ref m (car ws)) (cadr ws))
                    (l (cddr ws))))))))

;; ---- hand posing: the named slots, pinned against the composed
;; ---- matrix so an off-by-one in EITHER direction shows ------------
;; T = (1.5, 2.5, 3.5), R = 90 deg about z, S = (2, 3, 4).  Every
;; number is distinct and no two lanes share a value, so a setter or
;; getter reading one slot over lands somewhere visibly wrong.
;;   M = T . R . S  has columns
;;     col0 = ( 0, 2, 0)   col1 = (-3, 0, 0)   col2 = (0, 0, 4)
;;     col3 = (1.5, 2.5, 3.5)
(gltf-node-translation-set! g 1 1.5 2.5 3.5)
(gltf-node-rotation-set! g 1 0.0 0.0 0.70710678 0.70710678)
(gltf-node-scale-set! g 1 2.0 3.0 4.0)

(define pose-matrix-ok
  (m-is? 0 0 0.0 1 2.0 2 0.0
           4 -3.0 5 0.0 6 0.0
           8 0.0 9 0.0 10 4.0
           12 1.5 13 2.5 14 3.5))

;; the child inherits it: palette[1] = M . T(1,0,0), whose translation
;; column is col0 + col3 = (1.5, 4.5, 3.5).  A parent write that the
;; palette failed to propagate would leave (1,0,0) here.
(define pose-child-ok
  (m-is? 1 0 0.0 1 2.0 2 0.0
           12 1.5 13 4.5 14 3.5))

;; the getters read the slots the setters wrote -- against the literal
;; values, not against each other, so a matched pair of off-by-ones
;; cannot round-trip its way to green
(define get-ok
  (let ((t (gltf-node-translation g 1))
        (r (gltf-node-rotation g 1))
        (s (gltf-node-scale g 1)))
    (and (= 3 (vector-length t)) (= 4 (vector-length r))
         (= 3 (vector-length s))
         (near? (vector-ref t 0) 1.5) (near? (vector-ref t 1) 2.5)
         (near? (vector-ref t 2) 3.5)
         (near? (vector-ref r 0) 0.0) (near? (vector-ref r 1) 0.0)
         (near? (vector-ref r 2) 0.70710678)
         (near? (vector-ref r 3) 0.70710678)
         (near? (vector-ref s 0) 2.0) (near? (vector-ref s 1) 3.0)
         (near? (vector-ref s 2) 4.0))))

;; a getter hands back a COPY: mutating it must not be a second,
;; unchecked route into the slots the setters guard
(define get-copies-ok
  (let ((t (gltf-node-translation g 1)))
    (vector-set! t 0 999.0)
    (near? (vector-ref (gltf-node-translation g 1) 0) 1.5)))

;; the palette is recomputed on EVERY call, so a second write needs no
;; invalidation, no dirty flag and no other call in between
(define immediate-ok
  (begin
    (gltf-node-translation-set! g 1 -7.0 2.5 3.5)
    (and (m-is? 0 12 -7.0)
         (m-is? 1 12 -7.0 13 4.5))))

;; Postel on the way in: loose components, a vector, or a list -- and
;; a getter's own result feeds the matching setter unchanged
(define shapes-ok
  (begin
    (gltf-node-translation-set! g 1 (vector 4.0 5.0 6.0))
    (and (near? (vector-ref (gltf-node-translation g 1) 1) 5.0)
         (begin
           (gltf-node-translation-set! g 1 (list 7.0 8.0 9.0))
           (near? (vector-ref (gltf-node-translation g 1) 2) 9.0))
         (begin
           (gltf-node-scale-set! g 1 (gltf-node-scale g 1))
           (near? (vector-ref (gltf-node-scale g 1) 2) 4.0)))))

;; exact numbers widen: JSON writes an exact 0 wherever a lane is
;; exactly zero, and every TRS slot is flonum only -- m4s-tqs! reads
;; them as f64 lanes and a fixnum there is not a slightly wrong pose,
;; it is a trap
(define widen-ok
  (begin
    (gltf-node-translation-set! g 1 1 2 3)
    (gltf-node-rotation-set! g 1 0 0 0 1)
    (let ((t (gltf-node-translation g 1))
          (r (gltf-node-rotation g 1)))
      (and (flonum? (vector-ref t 0)) (flonum? (vector-ref t 1))
           (flonum? (vector-ref t 2))
           (flonum? (vector-ref r 0)) (flonum? (vector-ref r 3))
           (near? (vector-ref t 2) 3.0)
           ;; and the widened values really compose
           (m-is? 0 12 1.0 13 2.0 14 3.0)))))

;; wrong component counts are refused rather than silently padded
(define arity-ok
  (and (raises? (lambda () (gltf-node-translation-set! g 1 1.0 2.0)))
       (raises? (lambda () (gltf-node-rotation-set! g 1 1.0 2.0 3.0)))
       (raises? (lambda () (gltf-node-scale-set! g 1 (vector 1.0 2.0))))
       ;; ... and the refusals left the node alone
       (near? (vector-ref (gltf-node-translation g 1) 0) 1.0)))

;; ---- the node the setters must refuse -----------------------------
(define matrix-flag-ok
  (and (gltf-node-matrix? g 3)
       (not (gltf-node-matrix? g 1))
       (not (gltf-node-matrix? g 2))))

;; node 3 carries the matrix form, so $node-local and the palette both
;; read slot 10 and IGNORE its TRS slots.  A setter that wrote them
;; anyway would return normally having posed nothing -- silently, at
;; every call site, forever.  It must raise, and it must raise BEFORE
;; writing, so the node is unchanged after the refusal.
(define matrix-refusal-ok
  (and (raises? (lambda () (gltf-node-translation-set! g 3 9.0 9.0 9.0)))
       (raises? (lambda ()
                  (gltf-node-rotation-set! g 3 0.0 0.0 1.0 0.0)))
       (raises? (lambda () (gltf-node-scale-set! g 3 9.0 9.0 9.0)))
       (let ((t (gltf-node-translation g 3))
             (r (gltf-node-rotation g 3))
             (s (gltf-node-scale g 3)))
         (and (near? (vector-ref t 0) 0.0)
              (near? (vector-ref r 2) 0.0) (near? (vector-ref r 3) 1.0)
              (near? (vector-ref s 0) 1.0)))))

;; reading a matrix node's TRS is legal -- those are the defaults, and
;; gltf-node-matrix? is the named way to learn they do not apply
(define matrix-read-ok
  (and (= 3 (vector-length (gltf-node-translation g 3)))
       (= -1 (gltf-node-parent g 3))))

(define parent-ok
  (and (= 1 (gltf-node-parent g 2))       ; "c" hangs off "j"
       (= -1 (gltf-node-parent g 1))      ; a root
       (= -1 (gltf-node-parent g 0))))

(define range-ok
  (and (raises? (lambda () (gltf-node-translation g 4)))
       (raises? (lambda () (gltf-node-parent g -1)))
       (raises? (lambda () (gltf-node-rotation-set! g 99 0.0 0.0 0.0 1.0)))))

;; ---- clip time: wrapped versus held -------------------------------
;; "spin" turns node 1 from identity to 90 degrees about z over one
;; second, and node 2 sits at (1,0,0) in its parent, so palette[1]'s
;; translation column reads the rotation directly:
;;   identity -> (1, 0, 0)     45 deg -> (.7071, .7071, 0)
;;   90 deg   -> (0, 1, 0)
;; Sampling also resets node 1 wholesale to bind, undoing the hand
;; poses above, so these cases stand on their own.
(define dur (gltf-animation-duration g 0))

(define duration-ok (near? dur 1.0))

;; INSIDE the clip the two entry points are the same function
(define interior-ok
  (begin
    (gltf-animate! g 0 0.5)
    (and (m-is? 1 12 0.70710678 13 0.70710678 14 0.0)
         (begin
           (gltf-pose-at! g 0 0.5)
           (m-is? 1 12 0.70710678 13 0.70710678 14 0.0)))))

;; AT the duration they must differ, and this is the whole point:
;; gltf-animate!'s clock is half-open, so t = dur is t = 0 and the
;; clip reads as if it had not started -- a 90 degree error at the
;; very moment a caller asks for the end pose.  gltf-pose-at! holds
;; the last keyframe.  Asserting they DIFFER is what a pose-at! that
;; quietly wrapped would fail; asserting each value is what a
;; clamp-to-the-wrong-end would fail.
(define end-differs-ok
  (begin
    (gltf-animate! g 0 dur)
    (and (m-is? 1 12 1.0 13 0.0 14 0.0)          ; wrapped: the START
         (begin
           (gltf-pose-at! g 0 dur)
           (m-is? 1 12 0.0 13 1.0 14 0.0)))))    ; held: the END

;; past the end it stays held, however far past -- not wrapped, and
;; not extrapolated either
(define past-end-ok
  (begin
    (gltf-pose-at! g 0 2.5)
    (and (m-is? 1 12 0.0 13 1.0 14 0.0)
         (begin (gltf-pose-at! g 0 1000.0)
                (m-is? 1 12 0.0 13 1.0 14 0.0))
         ;; the wrapping clock at the same t is somewhere else
         ;; entirely (2.5 wraps to 0.5, the 45 degree pose)
         (begin (gltf-animate! g 0 2.5)
                (m-is? 1 12 0.70710678 13 0.70710678 14 0.0)))))

;; negative t is DEFINED, not undefined: gltf-pose-at! clamps to 0 and
;; poses the first keyframe, while gltf-animate! wraps by floor (so
;; -0.5 of a one-second clip is 0.5, the 45 degree pose).  The two
;; answers differ, which is what makes this a real assertion.
(define negative-ok
  (begin
    (gltf-pose-at! g 0 -0.5)
    (and (m-is? 1 12 1.0 13 0.0 14 0.0)          ; held at the first key
         (begin (gltf-pose-at! g 0 -1000.0)
                (m-is? 1 12 1.0 13 0.0 14 0.0))
         (begin (gltf-animate! g 0 -0.5)         ; wrapped: 45 degrees
                (m-is? 1 12 0.70710678 13 0.70710678 14 0.0)))))

;; ... and clamping the CLOCK is not the same as clamping the
;; interpolant.  Clip "back" drives node 1's translation from x = 0 to
;; x = 8 over keys at t = -2 and t = +2, so its duration -- the
;; largest timestamp -- is 2.0 and its clock domain is [0, 2] for both
;; entry points: the keys before 0 are as unreachable here as they are
;; through gltf-animate!'s wrap.  Held at 0 the sampler is halfway
;; between the keys, x = 4; a clock allowed through unclamped would
;; sample t = -0.5 itself and read x = 3.
(define dur2 (gltf-animation-duration g 1))

(define negative-clock-ok
  (and (near? dur2 2.0)
       (begin (gltf-pose-at! g 1 -0.5)  (m-is? 0 12 4.0))
       (begin (gltf-pose-at! g 1 -1000.0) (m-is? 0 12 4.0))
       (begin (gltf-pose-at! g 1 0.0)   (m-is? 0 12 4.0))
       ;; the wrapping clock at the same negative t lands elsewhere:
       ;; -0.5 wraps to 1.5, three quarters of the way, x = 7
       (begin (gltf-animate! g 1 -0.5)  (m-is? 0 12 7.0))
       ;; and at the duration the two disagree once more, on a clip
       ;; whose first key is not at zero
       (begin (gltf-pose-at! g 1 dur2)  (m-is? 0 12 8.0))
       (begin (gltf-animate! g 1 dur2)  (m-is? 0 12 4.0))))

;; gltf-pose-at! poses COMPLETELY, exactly as gltf-animate! does: the
;; clip drives rotation only, so a hand-written translation on the
;; node it touches must go back to bind rather than survive the call
(define pose-at-resets-ok
  (begin
    (gltf-node-translation-set! g 1 5.0 6.0 7.0)
    (gltf-pose-at! g 0 dur)
    (and (near? (vector-ref (gltf-node-translation g 1) 0) 0.0)
         (m-is? 1 12 0.0 13 1.0 14 0.0))))

;; ... and a node the clip does not touch keeps its hand-written pose
;; across a sample, which is what makes hand posing composable with
;; clips over disjoint parts of a skeleton
(define untouched-survives-ok
  (begin
    (gltf-node-translation-set! g 2 0.0 0.0 5.0)
    (gltf-pose-at! g 0 0.0)
    (and (near? (vector-ref (gltf-node-translation g 2) 2) 5.0)
         (m-is? 1 12 0.0 13 0.0 14 5.0))))

(and pose-matrix-ok pose-child-ok get-ok get-copies-ok immediate-ok
     shapes-ok widen-ok arity-ok
     matrix-flag-ok matrix-refusal-ok matrix-read-ok
     parent-ok range-ok
     duration-ok interior-ok end-differs-ok past-end-ok negative-ok
     negative-clock-ok pose-at-resets-ok untouched-survives-ok)
