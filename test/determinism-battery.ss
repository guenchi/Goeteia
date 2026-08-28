;; expect: trig 357c/c6b3 m4scalar 7c8c/267a m4simd baef/73e9 slerp 7d6d/512d gltf 1481/d453 intbits 4631/adbf fltext 32ed/9b30 numlit bccc/537b edge 0478/553a bigfl 3e32/924a
;; Numeric determinism battery: one fixed computation list whose every
;; result is printed as an IEEE 754 bit pattern, so "the two backends
;; agree" becomes a byte comparison instead of an assumption.
;;
;; Golden image regression, RLVR reward replay and motion fitting all
;; rest on same-input-same-output ACROSS hosts.  Both backends run the
;; same f64 arithmetic and the same prelude, so they should agree to
;; the bit; this file is what turns that "should" into a checked fact.
;; test/determinism.mjs runs it through six channels -- two compiler
;; hosts x two targets, plus both optimization levels -- three times
;; each, and compares the full text byte for byte.
;;
;; Two output modes, chosen by the first byte of stdin:
;;   no input (or anything else)  one line of per-section digests --
;;                                the ";; expect:" oracle above
;;   "v"                          the full value list, one token per
;;                                line, for locating a divergence
;;
;; A float is printed as its 16 hex digits, big-endian, read back out
;; of the linear memory: %mem-f64-set! stores the exact double and
;; %mem-u8-ref hands the bytes back.  There is no other primitive that
;; exposes a double's bits, and printing decimals instead would hide a
;; low-bit difference behind the printer's rounding.  Section "fltext"
;; covers the printer separately, since golden TEXT depends on it.
;;
;; The ";; expect:" line is the same digest list, and all six channels
;; produce it.  Sections "numlit" and "bigfl" were each written around
;; a real divergence -- one between the two compiler hosts, one between
;; the two targets -- and both are fixed; the witnesses stay here as
;; the nails.  docs/determinism.md records what they were and how to
;; put them back to check that this file still catches them.
;;
;; Changing this line is a deliberate act.  Regenerate it only when you
;; can say which computation changed and why.
;;
;; Copyright (c) 2026 guenchi.  MIT license; see LICENSE.
(import (rnrs) (web js) (gfx gl) (gfx fx) (gfx mat) (gfx gltf))

;; ---- output mode ----
(define verbose?
  (let ((c (read-char)))
    (and (char? c) (char=? c #\v))))

;; ---- the digest ----
;; Two rolling hashes over different moduli plus the byte count.  Both
;; stay inside the fixnum range at every step (65520*33+255 and
;; 65212*257+255 are far below 2^29), so the digest itself never
;; reaches the bignum path and cannot be the thing that diverges.
(define $h1 1)
(define $h2 0)
(define $n 0)
(define (hash-char! c)
  (let ((v (char->integer c)))
    (set! $h1 (remainder (+ (* $h1 33) v) 65521))
    (set! $h2 (remainder (+ (* $h2 257) v) 65213))
    (set! $n (+ $n 1))))
(define (hash-string! s)
  (let loop ((i 0))
    (when (< i (string-length s))
      (hash-char! (string-ref s i))
      (loop (+ i 1)))))
(define (hash-reset!) (set! $h1 1) (set! $h2 0) (set! $n 0))
(define $hex "0123456789abcdef")
(define (hex4 v)
  (string (string-ref $hex (remainder (quotient v 4096) 16))
          (string-ref $hex (remainder (quotient v 256) 16))
          (string-ref $hex (remainder (quotient v 16) 16))
          (string-ref $hex (remainder v 16))))
(define (digest) (string-append (hex4 $h1) "/" (hex4 $h2)))

;; ---- emission ----
;; Every token goes through the hash; the text itself is only kept in
;; verbose mode, where the caller wants to see where two runs parted.
(define (emit! s)
  (hash-string! s)
  (when verbose?
    (display s)
    (newline)))

;; the digest line, assembled as one line so the ";; expect:" oracle
;; can hold it
(define $summary "")
(define (section! name)
  (set! $summary
        (if (string=? $summary "")
            (string-append name " " (digest))
            (string-append $summary " " name " " (digest))))
  (when verbose?
    (display "=== ") (display name) (display " ") (display (digest))
    (display " n=") (display $n) (newline))
  (hash-reset!))

;; ---- bit patterns ----
(define $bitbuf (fx-alloc! 16))
(define (fb x)                          ; f64 -> 16 hex digits
  (%mem-f64-set! $bitbuf x)
  (let loop ((i 7) (acc ""))
    (if (< i 0)
        (emit! acc)
        (loop (- i 1)
              (let ((b (%mem-u8-ref (+ $bitbuf i))))
                (string-append
                 acc
                 (string (string-ref $hex (quotient b 16))
                         (string-ref $hex (remainder b 16)))))))))
(define (fv v)                          ; every element of a vector
  (let loop ((i 0))
    (when (< i (vector-length v))
      (fb (vector-ref v i))
      (loop (+ i 1)))))
(define (ne! n) (emit! (number->string n)))
(define (fl-of k) (fixnum->flonum k))

;; ==================================================================
;; trig: the (gfx mat) polynomial kernels, swept
;; ==================================================================
;; 400 points across seven periods for sin/cos/tan, so the argument
;; reduction is exercised at every branch, and the inverse pair over
;; the whole closed domain including both clamped ends.
(let loop ((k -200))
  (when (< k 200)
    (let ((x (fl/ (fl-of k) 17.0)))
      (fb (flsin x))
      (fb (flcos x))
      (fb (fltan x))
      (fb (flatan x)))
    (loop (+ k 1))))
(let loop ((k -105))
  (when (< k 106)
    (let ((x (fl/ (fl-of k) 100.0)))    ; |x| > 1 at both ends: clamped
      (fb (flasin x))
      (fb (flacos x)))
    (loop (+ k 1))))
(let loop ((k 0))                       ; all four quadrants and both axes
  (when (< k 72)
    (let ((y (fl- (fl/ (fl-of k) 8.0) 4.5))
          (x (fl- (fl/ (fl-of (* 3 k)) 8.0) 13.5)))
      (fb (flatan2 y x))
      (fb (flatan2 x y))
      (fb (flatan2 y 0.0))
      (fb (flatan2 0.0 x)))
    (loop (+ k 1))))
(section! "trig")

;; ==================================================================
;; m4scalar: boxed 4x4 chains, f64 throughout
;; ==================================================================
;; Forty multiplies deep: a chain that long makes the summation order
;; inside m4-mul observable, which is exactly what a backend could
;; get wrong without any single operation being wrong.
(define (chain n seed)
  (let loop ((i 0) (m (m4-identity)))
    (if (= i n)
        m
        (loop (+ i 1)
              (m4-mul m
                      (m4-mul (m4-rotate-z (fl/ (fl-of (+ i seed)) 7.0))
                              (m4-mul (m4-rotate-y (fl/ (fl-of (- i seed)) 11.0))
                                      (m4-translate (fl/ (fl-of i) 3.0)
                                                    (fl/ (fl-of seed) 5.0)
                                                    -1.25))))))))
(m4-scratch! #f)                        ; the boxed path, explicitly
(let loop ((s 0))
  (when (< s 8)
    (let ((m (chain 40 s)))
      (fv m)
      (let ((inv (m4-inverse m)))
        (if inv (fv inv) (emit! "singular")))
      (fv (m4-transform m (v3 0.5 -2.25 3.125))))
    (loop (+ s 1))))
(fv (m4-perspective 0.9 1.7777777777777777 0.1 1000.0))
(fv (m4-ortho -3.5 4.25 -1.125 2.5 0.01 512.0))
(fv (m4-look-at (v3 3.0 4.0 5.0) (v3 -1.0 0.5 2.0) (v3 0.0 1.0 0.0)))
(fv (m4-from-quat 0.18257418583505536 0.3651483716701107
                  0.5477225575051661 0.7302967433402214))
(fv (m4-inverse (m4-look-at (v3 3.0 4.0 5.0) (v3 -1.0 0.5 2.0)
                            (v3 0.0 1.0 0.0))))
(let ((planes (m4-frustum-planes (m4-mul (m4-perspective 0.9 1.5 0.1 100.0)
                                         (m4-look-at (v3 1.0 2.0 3.0)
                                                     (v3 0.0 0.0 0.0)
                                                     (v3 0.0 1.0 0.0))))))
  (let loop ((i 0))
    (when (< i (vector-length planes))
      (fv (vector-ref planes i))
      (loop (+ i 1)))))
(section! "m4scalar")

;; ==================================================================
;; m4simd: the f32 lane path
;; ==================================================================
;; With scratch wired, m4-mul routes through %f32x4-*.  wasm runs real
;; SIMD; the JS backend emulates it with Math.fround and Float32
;; stores.  f64 carries 53 bits and an f32 product needs 48, so the
;; emulation's intermediate cannot double-round -- but that is a
;; property to check, not to assume.
(define $scratch (fx-alloc! 128))
(define $ma (fx-alloc! 64))
(define $mb (fx-alloc! 64))
(define $mc (fx-alloc! 64))
(m4-scratch! $scratch)
(let loop ((s 0))
  (when (< s 8)
    (fv (chain 40 s))
    (loop (+ s 1))))
;; staging-resident chains: no boxed intermediate anywhere
(m4s-identity! $ma)
(m4s-write! $mb (m4-rotate-y 0.37))
(let loop ((i 0))
  (when (< i 40)
    (m4s-mul! $mc $ma $mb)
    (m4s-write! $ma (m4s-read $mc))
    (loop (+ i 1))))
(fv (m4s-read $ma))
(let loop ((k 0))
  (when (< k 24)
    (m4s-trs! $ma
              (fl/ (fl-of k) 3.0) (fl/ (fl-of (- k 12)) 7.0) -2.5
              (fl/ (fl-of k) 5.0) (fl/ (fl-of k) 9.0) (fl/ (fl-of k) 13.0)
              (fl+ 0.25 (fl/ (fl-of k) 32.0)))
    (fv (m4s-read $ma))
    (m4s-tqs! $mb
              0.5 -1.5 2.25
              0.18257418583505536 0.3651483716701107
              0.5477225575051661 0.7302967433402214
              (fl+ 0.5 (fl/ (fl-of k) 48.0)) 1.5 0.75)
    (fv (m4s-read $mb))
    (loop (+ k 1))))
;; f32 round trip: every store rounds, and the two backends must round
;; the same way
(let loop ((k 1))
  (when (< k 200)
    (%mem-f32-set! $ma (fl/ (fl-of k) 3.0))
    (fb (%mem-f32-ref $ma))
    (%mem-f32-set! $ma (fl/ 1.0 (fl-of k)))
    (fb (%mem-f32-ref $ma))
    (loop (+ k 1))))
;; the quaternion/plane dot, four f32 lanes summed left to right
(let loop ((k 0))
  (when (< k 32)
    (%mem-f32-set! $ma (fl/ (fl-of (+ k 1)) 7.0))
    (%mem-f32-set! (+ $ma 4) (fl/ (fl-of (- k 16)) 3.0))
    (%mem-f32-set! (+ $ma 8) (fl/ 1.0 (fl-of (+ k 3))))
    (%mem-f32-set! (+ $ma 12) (fl* 0.0000001 (fl-of (+ k 1))))
    (%mem-f32-set! $mb (fl/ (fl-of (+ k 5)) 11.0))
    (%mem-f32-set! (+ $mb 4) (fl/ 10000000.0 (fl-of (+ k 1))))
    (%mem-f32-set! (+ $mb 8) -0.125)
    (%mem-f32-set! (+ $mb 12) (fl-of (+ k 1)))
    (fb (%f32x4-dot $ma $mb))
    (loop (+ k 1))))
;; the three lane-wise kernels, including the aliasing case: dst
;; overlapping a source must read every lane before the first store,
;; which the JS emulation has to arrange by hand
(let loop ((k 0))
  (when (< k 24)
    (let put ((i 0))
      (when (< i 4)
        (%mem-f32-set! (+ $ma (* i 4)) (fl/ (fl-of (+ k i 1)) 7.0))
        (%mem-f32-set! (+ $mb (* i 4)) (fl/ (fl-of (- (* 3 i) k)) 13.0))
        (put (+ i 1))))
    (%f32x4-add! $mc $ma $mb) (fv (m4s-read $mc))
    (%f32x4-sub! $mc $ma $mb) (fv (m4s-read $mc))
    (%f32x4-mul! $mc $ma $mb) (fv (m4s-read $mc))
    (%f32x4-add! $ma $ma $mb) (fv (m4s-read $ma))
    (loop (+ k 1))))
(m4-scratch! #f)
(section! "m4simd")

;; ==================================================================
;; slerp: the great-arc path and its near-parallel fallback
;; ==================================================================
(define (slerp-sweep a b)
  (let loop ((k -8))
    (when (< k 41)                      ; t outside [0,1] too: it extrapolates
      (fv (q-slerp a b (fl/ (fl-of k) 32.0)))
      (loop (+ k 1)))))
(slerp-sweep (vector 0.0 0.0 0.0 1.0) (vector 0.6 0.0 0.8 0.0))
(slerp-sweep (vector 0.0 0.0 0.0 1.0) (vector 0.0 0.0 -0.7071067811865476
                                             -0.7071067811865476))
;; inside the nine-digit dot window: the lerp-and-renormalize branch
(slerp-sweep (vector 0.0 0.0 0.0 1.0)
             (vector 0.00001 0.0 0.0 0.99999999995))
(slerp-sweep (vector 0.18257418583505536 0.3651483716701107
                     0.5477225575051661 0.7302967433402214)
             (vector 0.5 -0.5 0.5 0.5))
(section! "slerp")

;; ==================================================================
;; gltf: the animation sampling kernels
;; ==================================================================
;; One GLB assembled in staging, holding the three interpolations the
;; sampler implements: LINEAR rotation (shortest-path nlerp),
;; CUBICSPLINE translation (the hermite with its span scaling) and
;; CUBICSPLINE rotation (hermite plus renormalization).  Sampling is
;; not exported on its own, so the clip drives a one-joint skin and
;; the joint palette matrix is read back -- the same handle a renderer
;; would use, which is the point.
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
(define (str! s) (string-for-each (lambda (c) (b! (char->integer c))) s))

;; BIN layout
;;   0   positions   3 x vec3      = 36
;;   36  joints      3 x 4 u8      = 12
;;   48  weights     3 x 4 u8 norm = 12
;;   60  indices     3 x u16 + pad = 8
;;   68  times3      3 x f32       = 12   (0, 1, 2)
;;   80  linrot      3 x vec4      = 48
;;   128 cubtrans    9 x vec3      = 108
;;   236 cubtimes    3 x f32       = 12   (0, 2, 3)
;;   248 times2      2 x f32       = 8    (0, 1)
;;   256 cubrot      6 x vec4      = 96
(define binlen 352)

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
   "{\"node\":1,\"path\":\"rotation\"}}]},"
   "{\"name\":\"cub\",\"samplers\":[{\"input\":7,\"output\":6,"
   "\"interpolation\":\"CUBICSPLINE\"}],"
   "\"channels\":[{\"sampler\":0,\"target\":"
   "{\"node\":1,\"path\":\"translation\"}}]},"
   "{\"name\":\"cubr\",\"samplers\":[{\"input\":8,\"output\":9,"
   "\"interpolation\":\"CUBICSPLINE\"}],"
   "\"channels\":[{\"sampler\":0,\"target\":"
   "{\"node\":1,\"path\":\"rotation\"}}]}],"
   "\"buffers\":[{\"byteLength\":352}],"
   "\"bufferViews\":["
   "{\"buffer\":0,\"byteOffset\":0,\"byteLength\":36},"
   "{\"buffer\":0,\"byteOffset\":36,\"byteLength\":12},"
   "{\"buffer\":0,\"byteOffset\":48,\"byteLength\":12},"
   "{\"buffer\":0,\"byteOffset\":60,\"byteLength\":6},"
   "{\"buffer\":0,\"byteOffset\":68,\"byteLength\":12},"
   "{\"buffer\":0,\"byteOffset\":80,\"byteLength\":48},"
   "{\"buffer\":0,\"byteOffset\":128,\"byteLength\":108},"
   "{\"buffer\":0,\"byteOffset\":236,\"byteLength\":12},"
   "{\"buffer\":0,\"byteOffset\":248,\"byteLength\":8},"
   "{\"buffer\":0,\"byteOffset\":256,\"byteLength\":96}],"
   "\"accessors\":["
   "{\"bufferView\":0,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"},"
   "{\"bufferView\":1,\"componentType\":5121,\"count\":3,\"type\":\"VEC4\"},"
   "{\"bufferView\":2,\"componentType\":5121,\"normalized\":true,"
   "\"count\":3,\"type\":\"VEC4\"},"
   "{\"bufferView\":3,\"componentType\":5123,\"count\":3,\"type\":\"SCALAR\"},"
   "{\"bufferView\":4,\"componentType\":5126,\"count\":3,\"type\":\"SCALAR\"},"
   "{\"bufferView\":5,\"componentType\":5126,\"count\":3,\"type\":\"VEC4\"},"
   "{\"bufferView\":6,\"componentType\":5126,\"count\":9,\"type\":\"VEC3\"},"
   "{\"bufferView\":7,\"componentType\":5126,\"count\":3,\"type\":\"SCALAR\"},"
   "{\"bufferView\":8,\"componentType\":5126,\"count\":2,\"type\":\"SCALAR\"},"
   "{\"bufferView\":9,\"componentType\":5126,\"count\":6,\"type\":\"VEC4\"}]}"))

(define jlen (string-length json-text))
(define jpad (remainder (- 4 (remainder jlen 4)) 4))
(define total (+ 12 8 jlen jpad 8 binlen))

(u32! #x46546C67)                       ; "glTF"
(u32! 2)
(u32! total)
(u32! (+ jlen jpad))
(u32! #x4E4F534A)                       ; "JSON"
(str! json-text)
(let pad ((i 0)) (when (< i jpad) (b! 32) (pad (+ i 1))))
(u32! binlen)
(u32! #x004E4942)                       ; "BIN\0"
(v3! 0.0 0.0 0.0) (v3! 1.0 0.0 0.0) (v3! 0.0 1.0 0.0)
(let j ((i 0)) (when (< i 12) (b! 0) (j (+ i 1))))
(let w ((i 0))
  (when (< i 3) (b! 51) (b! 204) (b! 0) (b! 0) (w (+ i 1))))
(u16! 0) (u16! 1) (u16! 2) (u16! 0)
(f32! 0.0) (f32! 1.0) (f32! 2.0)                        ; times3
(v4! 0.0 0.0 0.0 1.0)                                   ; linrot k0
(v4! 0.5 0.5 0.5 0.5)                                   ; linrot k1
(v4! 0.0 0.70710678 0.0 0.70710678)                     ; linrot k2
(v3! 0.0 0.0 0.0) (v3! 1.0 2.0 3.0) (v3! 6.0 6.0 6.0)   ; cub k0 in/v/out
(v3! 0.0 0.0 0.0) (v3! 7.0 8.0 9.0) (v3! -2.5 4.0 0.5)  ; cub k1
(v3! 1.5 -3.0 0.25) (v3! 13.0 14.0 15.0) (v3! 0.0 0.0 0.0)
(f32! 0.0) (f32! 2.0) (f32! 3.0)                        ; cubtimes
(f32! 0.0) (f32! 1.0)                                   ; times2
(v4! 0.0 0.0 0.0 0.0) (v4! 0.0 0.0 0.0 1.0) (v4! 0.3 0.0 0.0 0.0)
(v4! 0.0 0.1 -0.2 0.0) (v4! 0.0 0.0 0.70710678 0.70710678)
(v4! 0.0 0.0 0.0 0.0)

(define g (gltf-parse base total))
(define (joint-m) (vector-ref (gltf-joint-matrices g 0) 0))
(define (sweep anim dur steps)
  (let loop ((k 0))
    (when (< k steps)
      (gltf-animate! g anim (fl* dur (fl/ (fl-of k) (fl-of steps))))
      (fv (joint-m))
      (loop (+ k 1)))))
(sweep 0 2.0 48)                        ; LINEAR rotation: nlerp
(sweep 1 3.0 48)                        ; CUBICSPLINE translation
(sweep 2 1.0 48)                        ; CUBICSPLINE rotation
;; the dequantized skin weights land in the interleaved stream
(let ((vb (gprim-vbase (car (gltf-prims g)))))
  (let loop ((i 0))
    (when (< i 24)
      (fb (%mem-f32-ref (+ vb (* i 4))))
      (loop (+ i 1)))))
(section! "gltf")

;; ==================================================================
;; intbits: fixnum bit operations and the bignum tower
;; ==================================================================
;; Bit operations stay under 2^29 -- past that the i31 cast traps, so
;; the sweep is built with remainder rather than a mask on a product.
(let loop ((k 0))
  (when (< k 200)
    (let ((x (remainder (* k 2654435761) 536870912))
          (y (remainder (* (+ k 7) 40503) 536870912)))
      (ne! (bitwise-xor x y))
      (ne! (bitwise-and x y))
      (ne! (bitwise-ior x y))
      (ne! (bitwise-xor x 536870911))
      (ne! (bitwise-arithmetic-shift-left (remainder x 256) 3))
      (ne! (bitwise-arithmetic-shift-right x 5))
      (ne! (quotient x (+ 1 (remainder y 97))))
      (ne! (remainder x (+ 1 (remainder y 97)))))
    (loop (+ k 1))))
(define (pw b n) (let loop ((i n) (a 1)) (if (= i 0) a (loop (- i 1) (* a b)))))
(let loop ((k 1))
  (when (< k 30)
    (let ((a (+ (pw 3 (+ 30 k)) 12345))
          (b (- (pw 7 (+ 12 k)) 99)))
      (ne! (* a b))
      (ne! (+ a b))
      (ne! (- a b))
      (ne! (quotient (* a b) 1000000007))
      (ne! (remainder (* a b) 1000000007))
      (ne! (quotient (- 0 (* a b)) b))
      (ne! (remainder (- 0 (* a b)) b))
      (ne! (gcd a b))
      (ne! (/ a b)))
    (loop (+ k 1))))
(section! "intbits")

;; ==================================================================
;; fltext: the printer, on which every golden TEXT depends
;; ==================================================================
;; number->string routes through the prelude's own decimal printer on
;; both backends, so text and bits should be equally stable.  If they
;; ever part, every text golden in the tree is void, which is why this
;; section exists next to the bit sections rather than instead of one.
(let loop ((k -240))
  (when (< k 240)
    (ne! (fl/ (fl-of k) 7.0))
    (ne! (fl/ (fl-of k) 1024.0))
    (ne! (fl* (fl-of k) 1048576.0))
    (loop (+ k 1))))
(ne! 0.1) (ne! 0.2) (ne! 0.30000000000000004)
(ne! (fl+ 0.1 0.2))
(ne! (fl/ 1.0 3.0))
;; The two zeros, side by side, and the point is that they no longer
;; print alike.  (fl- 0.0 0.0) is +0.0 and (fl* -1.0 0.0) is -0.0; the
;; printer used to render both as "0.0", so this pair was two cells
;; asserting one fact and a text golden could not see the sign at all.
;; The fltext digest moved from 54d4/8563 to 32ed/9b30 for this and
;; only this: of the 13377 values this file prints, exactly one
;; changed, "0.0" -> "-0.0", verified by running the value dump
;; against a build of the previous commit.
(ne! (fl- 0.0 0.0))
(ne! (fl* -1.0 0.0))
(ne! 0.000000001) (ne! 0.000000000001) (ne! 0.0000000000001)
(ne! (fl/ 1.0 0.0)) (ne! (fl/ -1.0 0.0)) (ne! (fl/ 0.0 0.0))
(ne! (string->number "0.5772156649015329"))
(ne! (string->number "-1234567.890625"))
(ne! (string->number "123456789012345678901234567890"))
(let loop ((k 0))
  (when (< k 120)
    (ne! (string->number
          (string-append "0." (number->string (+ 100000 (* k 8191))))))
    (loop (+ k 1))))
;; string->number over the same 17-digit range, at RUNTIME: the
;; parser is prelude code, so a divergence here would be a
;; backend difference rather than a compiler-host one
  (fb (string->number "0.4523795535098186"))
  (fb (string->number "0.559772386080496"))
  (fb (string->number "0.9242105840237294"))
  (fb (string->number "0.4656500700997733"))
  (fb (string->number "0.5078412730622711"))
  (fb (string->number "0.587384828849897"))
  (fb (string->number "0.18466034385487662"))
  (fb (string->number "0.5119086390418055"))
  (fb (string->number "0.6298827202168019"))
  (fb (string->number "0.7929768725199526"))
  (fb (string->number "0.09412345622921847"))
  (fb (string->number "0.3034012626245255"))
  (fb (string->number "0.0906705374918394"))
  (fb (string->number "0.8096445343671775"))
  (fb (string->number "0.6934384825412391"))
  (fb (string->number "0.041880336369846005"))
  (fb (string->number "0.9821934207987782"))
  (fb (string->number "0.9647577811255668"))
  (fb (string->number "0.6539225335338404"))
  (fb (string->number "0.6155627045785708"))
  (fb (string->number "0.15749409514016244"))
  (fb (string->number "0.01500073694960491"))
  (fb (string->number "0.5283812661704788"))
  (fb (string->number "0.05955110516885498"))
  (fb (string->number "0.19020826279792913"))
  (fb (string->number "0.24194301366521476"))
  (fb (string->number "0.03008258922478857"))
  (fb (string->number "0.4639344612232845"))
  (fb (string->number "0.4405311166566568"))
  (fb (string->number "0.842427128518532"))
  (fb (string->number "0.5191241147640767"))
  (fb (string->number "0.6402917079191771"))
  (fb (string->number "0.49977315220679164"))
  (fb (string->number "0.6624495318903681"))
  (fb (string->number "0.4573298815995577"))
  (fb (string->number "0.27816289966388585"))
  (fb (string->number "0.9976562004630843"))
  (fb (string->number "0.9956916416561992"))
  (fb (string->number "0.8402155494928618"))
  (fb (string->number "0.7078096214979495"))
  (fb (string->number "315277217.0155499"))
  (fb (string->number "229665901.60790557"))
  (fb (string->number "289039947.31420213"))
  (fb (string->number "70223499.5599259"))
  (fb (string->number "766287886.4104071"))
  (fb (string->number "400399804.918491"))
  (fb (string->number "846583621.8811786"))
  (fb (string->number "386513531.7059345"))
  (fb (string->number "958042383.3198135"))
  (fb (string->number "847309773.3028045"))
  (fb (string->number "544937.0555704603"))
  (fb (string->number "209717414.72961113"))
  (fb (string->number "910271928.1041814"))
  (fb (string->number "469987276.0136664"))
  (fb (string->number "980358941.1742921"))
  (fb (string->number "397424388.07928115"))
  (fb (string->number "73038343.8336979"))
  (fb (string->number "629454912.2340242"))
  (fb (string->number "778510858.6766508"))
  (fb (string->number "269775586.8501427"))
(section! "fltext")

;; ==================================================================
;; numlit: decimal literals, as the COMPILER rounds them
;; ==================================================================
;; Everything above measures the two runtimes.  This measures the two
;; compiler hosts: a decimal literal becomes an f64 constant at COMPILE
;; time, read by the Chez host's reader under bin/goeteiac and by the
;; prelude's %parse-decimal under the self-hosted compiler.  A constant
;; that depends on which compiler built the module is a determinism
;; break one level below every runtime check -- the two builds would
;; not be the same program.
;;
;; 600 literals at 17 significant digits, where the numerator no longer
;; fits 53 bits and the conversion has to round.  62 of them used to
;; disagree between the hosts, always by one ulp and always with the
;; self-hosted side wrong, because %parse-decimal built the exact ratio
;; and then converted numerator and denominator separately -- three
;; roundings where its own comment promised one.  All 600 now agree,
;; and all 600 match an arbitrary-precision oracle.  This block is the
;; nail: it is the witness set, kept.
;;
;; The literals are grouped into procedures of forty rather than left
;; at top level.  Constants are hoisted per emitted function, and the
;; top level is one function: 600 more of them there put its type past
;; the 1000-parameter ceiling wasm engines impose, and the module
;; stops instantiating.  See docs/limits.md.
(define ($nl0)
  (fb 0.32383276483316237) (fb 0.15084917392450192)
  (fb 0.6509344730398537) (fb 0.07243628666754276)
  (fb 0.5358820043066892) (fb 0.36568891691258554)
  (fb 0.057998924774706806) (fb 0.5074357331894203)
  (fb 0.03749565844198488) (fb 0.4336456836623859)
  (fb 0.06985542357461894) (fb 0.09071301334386506)
  (fb 0.42451918914251396) (fb 0.8268521246720381)
  (fb 0.12380196114964559) (fb 0.22323896460701453)
  (fb 0.6274332224055893) (fb 0.9477089424570057)
  (fb 0.5771029486174987) (fb 0.39668047465078016)
  (fb 0.9762551055929201) (fb 0.04658268061775628)
  (fb 0.8584684590486795) (fb 0.28960928633167626)
  (fb 0.14425508335743753) (fb 0.11779223807836836)
  (fb 0.30848182410193437) (fb 0.8161263591200314)
  (fb 0.18072637992393747) (fb 0.5816001636624663)
  (fb 0.6389134689261841) (fb 0.3723975427257312)
  (fb 0.5477444657095578) (fb 0.06278897497332314)
  (fb 0.05960116996623266) (fb 0.20595871281932654)
  (fb 0.6803999731817859) (fb 0.4275923056694029)
  (fb 0.3141471703767915) (fb 0.5855618635076387))
(define ($nl1)
  (fb 0.45318437637077535) (fb 0.29976699686368236)
  (fb 0.7943794815224912) (fb 0.6989944337295713)
  (fb 0.24409651072215288) (fb 0.574423710258671)
  (fb 0.5251965038114514) (fb 0.8751374955734289)
  (fb 0.7294452894392176) (fb 0.2879377648901865)
  (fb 0.9801748474925821) (fb 0.11806577825496212)
  (fb 0.4181228217852272) (fb 0.7571409295652494)
  (fb 0.15198453466050477) (fb 0.4889631004758056)
  (fb 0.03920725704743766) (fb 0.6682158565343952)
  (fb 0.7645708662128131) (fb 0.573025940277384)
  (fb 0.8754778118308882) (fb 0.31374751284809677)
  (fb 0.6952953662736593) (fb 0.5943698771050184)
  (fb 0.5798952042824922) (fb 0.45620533130141305)
  (fb 0.8399677805125414) (fb 0.9446810951079374)
  (fb 0.47409833741964447) (fb 0.6641522054746745)
  (fb 0.060669427597219716) (fb 0.7014920213044239)
  (fb 0.6471288545276688) (fb 0.9930959394666341)
  (fb 0.8219247866097149) (fb 0.28459553209414923)
  (fb 0.3857914424467108) (fb 0.6686527158841882)
  (fb 0.02256292805558857) (fb 0.46169528629976586))
(define ($nl2)
  (fb 0.16804837890654456) (fb 0.11709579448173191)
  (fb 0.058954419331310404) (fb 0.7682329884725208)
  (fb 0.12934022201868423) (fb 0.24761483369691428)
  (fb 0.3909497031332271) (fb 0.8714219741262994)
  (fb 0.08058130120013862) (fb 0.44918740094933096)
  (fb 0.5494399091440374) (fb 0.8833838264415125)
  (fb 0.8192798378357413) (fb 0.8639844696985152)
  (fb 0.27842106451389714) (fb 0.4152965172116986)
  (fb 0.3587711653316248) (fb 0.884192827198217)
  (fb 0.9577312039639913) (fb 0.15092090579110895)
  (fb 0.17621772849037032) (fb 0.23195686681953576)
  (fb 0.23333608368086112) (fb 0.4849627303413566)
  (fb 0.5891235037322556) (fb 0.26274661929853793)
  (fb 0.004093603385063926) (fb 0.41894650112532794)
  (fb 0.3692535728947254) (fb 0.566341223706392)
  (fb 0.9530979255250953) (fb 0.6904936571359779)
  (fb 0.5154914330707784) (fb 0.6175927494091277)
  (fb 0.6762000824495014) (fb 0.053992893223790195)
  (fb 0.8995330100579522) (fb 0.7799694907060728)
  (fb 0.8745131841344765) (fb 0.7978731211965661))
(define ($nl3)
  (fb 0.39237890689126864) (fb 0.398978832320273)
  (fb 0.10353709371032427) (fb 0.634289565685709)
  (fb 0.06224782161868758) (fb 0.06734761584302484)
  (fb 0.20876318544616446) (fb 0.1623031877720974)
  (fb 0.3400536522323434) (fb 0.05257560389026694)
  (fb 0.00023328190135663007) (fb 0.15126493227942794)
  (fb 0.10146436802259651) (fb 0.363609922034571)
  (fb 0.025500886666145695) (fb 0.8743323773738196)
  (fb 0.6140689877884787) (fb 0.14855048533089144)
  (fb 0.2522577565570773) (fb 0.34738954605370154)
  (fb 0.36416343952828245) (fb 0.12284223076219491)
  (fb 0.8489369264846149) (fb 0.9931027217047139)
  (fb 0.4659894591599337) (fb 0.48383465641626944)
  (fb 0.08588466155616559) (fb 0.10218761674816845)
  (fb 0.3426358382430018) (fb 0.2647568917171801)
  (fb 0.8288553781215605) (fb 0.1614386105264315)
  (fb 0.023095721045248152) (fb 0.9509855728747021)
  (fb 0.5282573950421248) (fb 0.1466025388990907)
  (fb 0.5431724258821143) (fb 0.027042491422168524)
  (fb 0.5281094409383065) (fb 0.9785012427189728))
(define ($nl4)
  (fb 0.8633250302896689) (fb 0.6961967859078019)
  (fb 0.26111519722936194) (fb 0.36669979176117884)
  (fb 0.1670420345343363) (fb 0.7719379084020312)
  (fb 0.532592397492879) (fb 0.7790548913381772)
  (fb 0.32966499504776237) (fb 0.22304167310318512)
  (fb 0.811511246773595) (fb 0.9849260505908908)
  (fb 0.8526287987466605) (fb 0.8060785847856675)
  (fb 0.8183329433253732) (fb 0.7398730203757141)
  (fb 0.2267394900315849) (fb 0.5176387242435055)
  (fb 0.3555625433549582) (fb 0.028980150741365396)
  (fb 0.027937075422064472) (fb 0.2794185390490298)
  (fb 0.25917436326775656) (fb 0.6925219417001234)
  (fb 0.9565150763413378) (fb 0.44722767776672345)
  (fb 0.9370212012762423) (fb 0.9880380582028602)
  (fb 0.9550006313213332) (fb 0.3646358853618661)
  (fb 0.22046232299623747) (fb 0.22684582673072795)
  (fb 0.19670616341931724) (fb 0.20437336327622302)
  (fb 0.6240663974378182) (fb 0.9003083378841142)
  (fb 0.8404355272792898) (fb 0.4794734262615382)
  (fb 0.652978042841009) (fb 0.7996437448496602))
(define ($nl5)
  (fb 0.08477848645038011) (fb 0.6605856502048941)
  (fb 0.909777137551723) (fb 0.78230288409809) (fb 0.7501404598304584)
  (fb 0.47803274459400025) (fb 0.17852171833757358)
  (fb 0.7891354310202764) (fb 0.3325171998646099)
  (fb 0.800823568896691) (fb 0.9716572889821583)
  (fb 0.3958384950694481) (fb 0.4013868178677015)
  (fb 0.946797006464893) (fb 0.7247986656342152)
  (fb 0.17000365997189548) (fb 0.12703836729786433)
  (fb 0.1511507003814898) (fb 0.9048520957332393)
  (fb 0.8065019820321961) (fb 0.14617430874387416)
  (fb 0.8265104785253871) (fb 0.9803059434470305)
  (fb 0.6572682927360199) (fb 0.3504075121575029)
  (fb 0.5486600439867791) (fb 0.1309838520094504)
  (fb 0.014242938156105556) (fb 0.9708901772377644)
  (fb 0.6496746696738306) (fb 0.5265810470990555)
  (fb 0.9336248050574267) (fb 0.4338094367574856)
  (fb 0.8717429279894041) (fb 0.8261552518152211)
  (fb 0.2110423373281488) (fb 0.2518348113654538)
  (fb 0.29296665267021893) (fb 0.24053939255833456)
  (fb 0.5864371681659617))
(define ($nl6)
  (fb 0.25936479527021017) (fb 0.41901255275454363)
  (fb 0.13107367650348334) (fb 0.9100170563155565)
  (fb 0.3537840239532589) (fb 0.45816098647173364)
  (fb 0.58334877204185) (fb 0.9042967745420398)
  (fb 0.42062827070906517) (fb 0.9177210843426643)
  (fb 0.5016489411202315) (fb 0.5318249624359338)
  (fb 0.5235065855871663) (fb 0.01870486790542003)
  (fb 0.44012491238494333) (fb 0.18310788727219873)
  (fb 0.003932481825641987) (fb 0.7991704504922217)
  (fb 0.17234671221344888) (fb 0.47349293246195634)
  (fb 0.7251932704473779) (fb 0.5564756249022133)
  (fb 0.3259821510488641) (fb 0.5183487127030368)
  (fb 0.5554418748802469) (fb 0.7842724753654755)
  (fb 0.10610941710492827) (fb 0.5602961335839522)
  (fb 0.24849432104309) (fb 0.27691707046478153)
  (fb 0.7722610987554883) (fb 0.5077139917923206)
  (fb 0.5617293866564762) (fb 0.7599931425900166)
  (fb 0.912488036329812) (fb 0.44324839357743884)
  (fb 0.6125278843444604) (fb 0.5055531308512217)
  (fb 0.5121614724353194) (fb 0.6927310025482292))
(define ($nl7)
  (fb 0.4523457922649097) (fb 0.5332854375791709)
  (fb 0.4780363180320848) (fb 0.9415011275385007)
  (fb 0.6992178821802858) (fb 0.8765354817805934)
  (fb 0.9421805883035757) (fb 0.2595922941176907)
  (fb 0.5595138064977149) (fb 0.9432670340134838)
  (fb 0.8399997833932058) (fb 0.13713443589685148)
  (fb 0.12162195438418066) (fb 0.4421180882750436)
  (fb 0.07254609965648828) (fb 0.24063875845326987)
  (fb 0.07312076697267433) (fb 0.6694721453098957)
  (fb 0.7839360171731552) (fb 0.8970264328787668)
  (fb 0.15444662376869212) (fb 0.7161198827881962)
  (fb 0.6602565151913709) (fb 0.14297899792423718)
  (fb 0.8828328336570754) (fb 0.9675447826663839)
  (fb 0.21958783080191968) (fb 0.9525041289189863)
  (fb 0.3982568747172719) (fb 0.48726077499088016)
  (fb 0.9898714547442865) (fb 0.8324446694829476)
  (fb 0.16146605988087914) (fb 0.4315218179976389)
  (fb 0.5156050578043591) (fb 0.33911614433881987)
  (fb 0.19574466613393116) (fb 0.31852556833769397)
  (fb 0.7221508351411857) (fb 0.019482928052393156))
(define ($nl8)
  (fb 0.554050247808328) (fb 0.44045810180270206)
  (fb 0.018081980827037603) (fb 0.33149788914199063)
  (fb 0.623927073891864) (fb 0.5122622844634556)
  (fb 0.06429079259075188) (fb 0.9850832441340993)
  (fb 0.7883630560975808) (fb 0.9716959586470741)
  (fb 0.10477959427283157) (fb 0.26556427234351976)
  (fb 0.03958818991406765) (fb 0.7789974300678922)
  (fb 0.2704460975213091) (fb 0.1295555593056773)
  (fb 0.4222541812776611) (fb 0.911413816183609)
  (fb 0.8189789797812816) (fb 0.2586090147938417)
  (fb 0.14936794740407822) (fb 0.9191715085117713)
  (fb 0.5705949253932538) (fb 0.7004174465466179)
  (fb 0.0894622078468077) (fb 0.05752651244094631)
  (fb 0.6882055713485481) (fb 0.42531704079572263)
  (fb 0.07241409472319049) (fb 0.9383497090401628)
  (fb 0.6344395062965595) (fb 0.8016285915713898)
  (fb 0.08374252623451806) (fb 0.8562286363721489)
  (fb 0.06662253487446146) (fb 0.8627749690538462)
  (fb 0.4537735209729249) (fb 0.3391517772846362)
  (fb 0.553064118458035) (fb 0.9266692840712272))
(define ($nl9)
  (fb 0.26785974667745416) (fb 0.12922479989532887)
  (fb 0.5269150265271717) (fb 0.23843616946135393)
  (fb 0.10945146507928383) (fb 0.16144909159761134)
  (fb 0.050379717209532604) (fb 0.20176824876850008)
  (fb 0.31199240407847684) (fb 0.30500539787922676)
  (fb 0.7594982549985613) (fb 0.2899608347243582)
  (fb 0.5000885998618394) (fb 0.17789988421292868)
  (fb 0.3470010221278589) (fb 0.018163107294581704)
  (fb 0.25044875619522744) (fb 0.015346117455019681)
  (fb 0.7330803834323136) (fb 0.5510491280112536)
  (fb 0.18945649649377838) (fb 0.47476063851773376)
  (fb 0.9346428397823539) (fb 0.10628134502709141)
  (fb 0.8189201403417139) (fb 0.4321775857844161)
  (fb 0.4950015734576154) (fb 0.8346139333302227)
  (fb 0.3930860755615859) (fb 0.5066859521551657)
  (fb 0.6877417356906914) (fb 0.9824405404147971)
  (fb 0.3427046254174745) (fb 0.8322865432644495)
  (fb 0.7067254016462279) (fb 0.6359769488850147)
  (fb 0.4046977087068413) (fb 0.34755218015523204)
  (fb 0.05438853678843625) (fb 0.12981858115088285))
(define ($nl10)
  (fb 70722.81558400617) (fb 740889.1981829276)
  (fb 255593.87676969692) (fb 163246.52027637576)
  (fb 84484.8727079307) (fb 841268.9818507564) (fb 870537.8212477482)
  (fb 670543.2979086785) (fb 281933.2823066295)
  (fb 242212.93399248656) (fb 293058.49258033547)
  (fb 459452.9433947208) (fb 157532.9398292057)
  (fb 445824.60823374026) (fb 263243.0669973891)
  (fb 961786.5333626133) (fb 972622.9979463763) (fb 547073.3741189084)
  (fb 244446.49394189354) (fb 965666.7700587851)
  (fb 309547.91767795273) (fb 356583.9170139871)
  (fb 1068.914944922783) (fb 381626.60661258217) (fb 474643.627397186)
  (fb 502764.0063763996) (fb 200980.05420103215)
  (fb 504735.6395143127) (fb 4950.531503943312) (fb 264168.6858016571)
  (fb 89753.39788097992) (fb 399511.1702889258) (fb 41666.9576911527)
  (fb 22494.146970257534) (fb 304244.56022433843)
  (fb 232809.5665908061) (fb 585583.2841816334) (fb 529189.54829311)
  (fb 750540.6301859925) (fb 657543.6733126728))
(define ($nl11)
  (fb 715993.4400323115) (fb 879090.69356739) (fb 389516.47106044996)
  (fb 326134.7541263495) (fb 984729.0850742962) (fb 149463.149042253)
  (fb 724155.7733618257) (fb 643219.4497045294) (fb 43788.06669158586)
  (fb 835289.5432338937) (fb 891942.3558785111) (fb 627332.1243319266)
  (fb 733852.1234769619) (fb 812218.915712394) (fb 139307.61001920432)
  (fb 523757.28452851734) (fb 504371.05125546077)
  (fb 834937.5934370264) (fb 804677.6057487708) (fb 826409.1215019802)
  (fb 584061.5168062388) (fb 892829.7364055078) (fb 682895.3695005006)
  (fb 693326.1352992788) (fb 229940.72053649795)
  (fb 31160.526289508496) (fb 133093.1979203215)
  (fb 360707.4764334862) (fb 104916.47106869706)
  (fb 835821.1997999711) (fb 558527.2464959347) (fb 627767.1085211685)
  (fb 626226.4589327859) (fb 680664.1760808205) (fb 489294.3148597545)
  (fb 3314.32712784796) (fb 797697.5520708526) (fb 748265.3702237058)
  (fb 502971.0523624538) (fb 535199.8142297709))
(define ($nl12)
  (fb 659299.4893043499) (fb 66050.35622215194) (fb 736788.3285422506)
  (fb 252193.53146269007) (fb 74449.99997417345)
  (fb 265558.22219539894) (fb 729335.0380393967)
  (fb 205217.5270820865) (fb 739828.5914207419) (fb 975735.0941027704)
  (fb 493948.7788493279) (fb 382560.47723248496) (fb 479010.164070626)
  (fb 683696.5627023515) (fb 766970.1058175226) (fb 616974.0157782497)
  (fb 642762.9753819862) (fb 77471.81951780069)
  (fb 147425.07287690742) (fb 253940.28165589532)
  (fb 743217.2573572905) (fb 304417.13795923255)
  (fb 567761.6978693083) (fb 12469.213324939443)
  (fb 60661.01406364177) (fb 268772.76578924805)
  (fb 672001.5786552359) (fb 692185.172570448) (fb 675707.6568127745)
  (fb 290856.478429369) (fb 516535.6940444077) (fb 464662.8533743143)
  (fb 466339.1542968881) (fb 118502.86270156795)
  (fb 893662.9261752702) (fb 199250.02985950303) (fb 978125.736757027)
  (fb 936254.3409537164) (fb 17504.455816662823)
  (fb 458970.82296359714))
(define ($nl13)
  (fb 819897.6926998682) (fb 968108.2516506995) (fb 449450.9696510952)
  (fb 268657.2401735808) (fb 209837.21998747264)
  (fb 945587.2768948678) (fb 210708.79753390592) (fb 581472.367721074)
  (fb 141740.67785953116) (fb 524065.7125548196)
  (fb 952740.3366532443) (fb 132605.07288102608) (fb 820217.010614784)
  (fb 508744.3536487809) (fb 886862.1596148429) (fb 703337.0387940744)
  (fb 231383.6030504699) (fb 897705.6956003996) (fb 486140.6564271489)
  (fb 24834.403090665204) (fb 3590.471669730255)
  (fb 491696.1094855377) (fb 450760.30049785465)
  (fb 301951.04127513437) (fb 140707.22025767856)
  (fb 343960.14642794535) (fb 316078.0453749698) (fb 840231.033647987)
  (fb 1741.3819175032818) (fb 750734.0411713169)
  (fb 839110.7946504619) (fb 120041.34759218254)
  (fb 926398.8598863864) (fb 713023.5657969237) (fb 901566.5630989359)
  (fb 289832.9589755253) (fb 372221.99935449177)
  (fb 392899.38204110455) (fb 998792.5057856137)
  (fb 589176.6553849033))
(define ($nl14)
  (fb 360709.32392340514) (fb 428052.751389566)
  (fb 275155.25262247963) (fb 48268.0967497654)
  (fb 101709.85796762633) (fb 834675.9949771924)
  (fb 285623.19006743643) (fb 935589.8883112846)
  (fb 249324.71641181852) (fb 265728.0149775798)
  (fb 510962.98780740326) (fb 189849.04716300688)
  (fb 373349.2850150366) (fb 956165.2647536071) (fb 884266.5555254468)
  (fb 811962.2674707723) (fb 630895.803869081) (fb 913423.8874593851)
  (fb 940699.2983382416) (fb 549228.1481879638) (fb 719572.581951148)
  (fb 49476.034443567296) (fb 732352.4684524983)
  (fb 450860.4229607736) (fb 752668.0092407207) (fb 644490.7104185137)
  (fb 286208.3203015855) (fb 48976.904987582784) (fb 926777.046547146)
  (fb 127311.32038505966) (fb 472184.0874468285)
  (fb 343662.8526579293) (fb 297771.86554478685)
  (fb 739032.5049962496) (fb 976296.1764098541)
  (fb 260169.05461407648) (fb 655995.3260322289) (fb 300836.291038856)
  (fb 557321.7024570404) (fb 394367.77770327416))
  ($nl0) ($nl1) ($nl2) ($nl3) ($nl4) ($nl5) ($nl6) ($nl7) ($nl8)
  ($nl9) ($nl10) ($nl11) ($nl12) ($nl13) ($nl14)
(section! "numlit")

;; ==================================================================
;; edge: signed zeros, infinities, denormals, f32 saturation
;; ==================================================================
(fb 0.0)
(fb (fl- 0.0 0.0))
(fb (fl* -1.0 0.0))
(fb (fl/ 1.0 0.0))
(fb (fl/ -1.0 0.0))
(fb (fl- (fl/ 1.0 0.0) (fl/ 1.0 0.0)))  ; a NaN: payload is NOT contracted
(fb (flsqrt 2.0))
(fb (flsqrt 0.0))
(fb (flfloor -2.5)) (fb (flfloor 2.5))
(fb (fltruncate -2.5)) (fb (fltruncate 2.5))
(let loop ((k 0))                       ; down into the denormals
  (when (< k 80)
    (let dn ((i 0) (v 1.0))
      (if (< i (+ 1000 (* k 4)))
          (dn (+ i 1) (fl* v 0.5))
          (fb v)))
    (loop (+ k 1))))
(let loop ((k 0))                       ; f32 store overflow and underflow
  (when (< k 40)
    (let up ((i 0) (v 1.0))
      (if (< i (+ 100 k))
          (up (+ i 1) (fl* v 2.0))
          (begin (%mem-f32-set! $ma v) (fb (%mem-f32-ref $ma)))))
    (let dn ((i 0) (v 1.0))
      (if (< i (+ 120 k))
          (dn (+ i 1) (fl* v 0.5))
          (begin (%mem-f32-set! $ma v) (fb (%mem-f32-ref $ma)))))
    (loop (+ k 1))))
(section! "edge")

;; ==================================================================
;; bigfl: exact -> inexact, where an integer wider than 53 bits has to
;; be rounded
;; ==================================================================
;; This is the conversion a parsed asset, a fixed-point accumulator or
;; an exact ratio reaches whenever it crosses into float.  Both
;; backends must round the same way for a golden to survive.
(let loop ((k 1))
  (when (< k 60)
    (fb (exact->inexact (+ (pw 3 (+ 34 k)) 7)))
    (fb (exact->inexact (- (pw 2 (+ 53 k)) 1)))
    (fb (exact->inexact (+ (pw 2 (+ 53 k)) 1)))
    (fb (exact->inexact (* (pw 3 (+ 30 k)) 1000000007)))
    (fb (exact->inexact (/ (+ (pw 3 (+ 30 k)) 1) (+ (pw 7 (+ 14 k)) 3))))
    (fb (sqrt (+ (pw 3 (+ 30 k)) 1)))
    (loop (+ k 1))))
(let loop ((k 1))                       ; and back, which is exact
  (when (< k 60)
    (ne! (inexact->exact (fl/ (fl-of k) 64.0)))
    (loop (+ k 1))))
(section! "bigfl")

;; ---- the oracle line ----
(display $summary)
