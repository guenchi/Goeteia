;; UASTC LDR 4x4 -> RGBA, decoded from the Basis Universal transcoder.
;; A UASTC block is 128 bits describing an ASTC-like block: a 7-bit
;; mode code selects the layout (1/2/3 subsets, 1 or 2 weight planes,
;; RGB / RGBA / LA / solid), then endpoints (BISE trits/quints packed
;; as plain base-3/5 bundles, the UASTC simplification) and per-texel
;; weights are unpacked and interpolated.  KTX2 stores these blocks
;; (DFD color model 166), zstd-wrapped or raw; (gfx zstd) unwraps, this
;; turns each block into 16 RGBA texels.
;;
;;   (uastc-block! src dst)          ; one 16-byte block -> 64 bytes RGBA
;;   (uastc-decode! src dst w h)     ; a whole level, ceil(w/4)*ceil(h/4)
;;
;; Verified byte-for-byte against the basisu transcoder's RGBA32 unpack
;; across the modes its encoder emits (test/uastc.ss).
;;
;; Copyright (c) 2026 guenchi. MIT license; see LICENSE.
(library (gfx uastc)
  (export uastc-block! uastc-decode! uastc-block-mode)
  (import (rnrs))

  (define ($u8 at) (%mem-u8-ref at))
  (define ($u8! at v) (%mem-u8-set! at (bitwise-and v 255)))
  (define ($shl a n) (bitwise-arithmetic-shift-left a n))
  (define ($shr a n) (bitwise-arithmetic-shift-right a n))

  ;; ---- per-mode tables (index by mode 0..18) ----
  (define $wb   '#(4 2 3 2 2 3 2 2 0 2 4 2 3 1 2 4 2 2 5))    ; weight bits
  (define $er   '#(19 20 8 7 12 20 18 12 0 8 13 13 19 20 20 20 20 20 11)) ; endpoint range
  (define $sub  '#(1 1 2 3 2 1 1 2 0 2 1 1 1 1 1 1 2 1 1))    ; subsets
  (define $pln  '#(1 1 1 1 1 1 2 1 0 1 1 2 1 2 1 1 1 2 1))    ; weight planes
  (define $cmp  '#(3 3 3 3 3 3 3 3 4 4 4 4 4 4 4 2 2 2 3))    ; components
  (define $hint '#(15 15 15 15 15 15 15 15 0 23 17 17 17 23 23 23 23 23 15))
  (define $hcsz '#(4 6 5 5 5 5 5 5 5 5 3 2 3 5 5 7 6 6 4))    ; mode code sizes
  (define $solid 8)

  ;; mode from the low 7 bits of byte 0
  (define $hm
    '#(11 0 10 3 11 15 12 7 11 18 10 5 11 14 12 9 11 0 10 4 11 16 12 8
       11 18 10 6 11 2 12 13 11 0 10 3 11 17 12 7 11 18 10 5 11 14 12 9
       11 0 10 4 11 1 12 8 11 18 10 6 11 2 12 13 11 0 10 3 11 19 12 7
       11 18 10 5 11 14 12 9 11 0 10 4 11 16 12 8 11 18 10 6 11 2 12 13
       11 0 10 3 11 17 12 7 11 18 10 5 11 14 12 9 11 0 10 4 11 1 12 8
       11 18 10 6 11 2 12 13))

  ;; BISE range table: #(bits trits quints) per ASTC range 0..20
  (define $bise
    '#(#(1 0 0) #(0 1 0) #(2 0 0) #(0 0 1) #(1 1 0) #(3 0 0) #(1 0 1)
       #(2 1 0) #(4 0 0) #(2 0 1) #(3 1 0) #(5 0 0) #(3 0 1) #(4 1 0)
       #(6 0 0) #(4 0 1) #(5 1 0) #(7 0 0) #(5 0 1) #(6 1 0) #(8 0 0)))
  (define ($bise-b r) (vector-ref (vector-ref $bise r) 0))
  (define ($bise-t r) (vector-ref (vector-ref $bise r) 1))
  (define ($bise-q r) (vector-ref (vector-ref $bise r) 2))

  ;; endpoint unquant params: C multiplier and B-bit swizzle per range.
  ;; $uqp-b[r] is a 9-vector of source bit positions (-1 for a '0'),
  ;; precomputed from the strings "b000b0bb0" (7), "cb0000cbc" (12),
  ;; "dcb000dcb" (13), "edcb0000e" (18), "fedcb000f" (19).
  (define $uqp-c '#(0 0 0 0 0 0 0 93 0 0 0 0 26 22 0 0 0 0 6 5 0))
  (define $uqp-b
    '#(#f #f #f #f #f #f #f #(1 -1 -1 -1 1 -1 1 1 -1)
       #f #f #f #f #(2 1 -1 -1 -1 -1 2 1 2) #(3 2 1 -1 -1 -1 3 2 1)
       #f #f #f #f #(4 3 2 1 -1 -1 -1 -1 4) #(5 4 3 2 1 -1 -1 -1 5) #f))

  ;; unquantize an ASTC endpoint index for a range
  (define ($unq packed r)
    (let ((bits ($bise-b r)) (trits ($bise-t r)) (quints ($bise-q r)))
      (if (and (= trits 0) (= quints 0))
          (let loop ((val 0) (bl 8))
            (if (<= bl 0) val
                (let* ((v packed)
                       (n (if (< bl bits) bl bits))
                       (v (if (< n bits) ($shr v (- bits n)) v)))
                  (loop (bitwise-ior val ($shl v (- bl n))) (- bl n)))))
          (let* ((pb (bitwise-and packed (- ($shl 1 bits) 1)))
                 (d ($shr packed bits))
                 (a (if (= 1 (bitwise-and pb 1)) 511 0))
                 (c (vector-ref $uqp-c r))
                 (bpos (vector-ref $uqp-b r)))
            (let ((b 0))
              (let loop ((i 0))
                (when (< i 9)
                  (set! b ($shl b 1))
                  (let ((p (vector-ref bpos i)))
                    (when (>= p 0) (set! b (bitwise-ior b (bitwise-and ($shr pb p) 1)))))
                  (loop (+ i 1))))
              (let* ((val (+ (* d c) b))
                     (val (bitwise-xor val a)))
                (bitwise-ior (bitwise-and a 128) ($shr val 2))))))))

  ;; interpolate two 8-bit endpoints by a 0..64 weight
  (define ($interp l h w)
    (let ((l (bitwise-ior ($shl l 8) l)) (h (bitwise-ior ($shl h 8) h)))
      ($shr ($shr (+ (* l (- 64 w)) (* h w) 32) 6) 8)))

  ;; weight unquant tables by weight-bit count
  (define $wtab
    '#(#f #(0 64) #(0 21 43 64) #(0 9 18 27 37 46 55 64)
       #(0 4 8 12 17 21 25 29 35 39 43 47 52 56 60 64)
       #(0 2 4 6 8 10 12 14 16 18 20 22 24 26 28 30
         34 36 38 40 42 44 46 48 50 52 54 56 58 60 62 64)))

  ;; common-pattern -> precomputed 16-texel partition (subset per
  ;; texel), the tables the reference derives from astc_hash52 --
  ;; $pat2 for 2-subset modes, $pat3 for mode 3, $pat7 for mode 7.
  (define $pat2
    '#(#(0 0 1 1 0 0 1 1 0 0 1 1 0 0 1 1)
       #(0 0 0 1 0 0 0 1 0 0 0 1 0 0 0 1)
       #(1 0 0 0 1 0 0 0 1 0 0 0 1 0 0 0)
       #(0 0 0 1 0 0 1 1 0 0 1 1 0 1 1 1)
       #(1 1 1 1 1 1 1 0 1 1 1 0 1 1 0 0)
       #(0 0 1 1 0 1 1 1 0 1 1 1 1 1 1 1)
       #(1 1 1 0 1 1 0 0 1 0 0 0 0 0 0 0)
       #(1 1 1 1 1 1 1 0 1 1 0 0 1 0 0 0)
       #(0 0 0 0 0 0 0 0 0 0 0 1 0 0 1 1)
       #(1 1 0 0 1 0 0 0 0 0 0 0 0 0 0 0)
       #(0 0 0 0 0 0 0 1 0 1 1 1 1 1 1 1)
       #(1 1 1 1 1 1 1 1 1 1 1 0 1 0 0 0)
       #(1 1 1 0 1 0 0 0 0 0 0 0 0 0 0 0)
       #(1 1 1 1 1 1 1 1 0 0 0 0 0 0 0 0)
       #(0 0 0 0 1 1 1 1 1 1 1 1 1 1 1 1)
       #(1 1 1 1 1 1 1 1 1 1 1 1 0 0 0 0)
       #(1 0 0 0 1 1 1 0 1 1 1 1 1 1 1 1)
       #(1 1 1 1 1 1 1 1 0 1 1 1 0 0 0 1)
       #(0 1 1 1 0 0 1 1 0 0 0 1 0 0 0 0)
       #(0 0 1 1 0 0 0 1 0 0 0 0 0 0 0 0)
       #(0 0 0 0 1 0 0 0 1 1 0 0 1 1 1 0)
       #(1 1 1 1 1 1 1 1 0 1 1 1 0 0 1 1)
       #(1 0 0 0 1 1 0 0 1 1 0 0 1 1 1 0)
       #(0 0 1 1 0 0 0 1 0 0 0 1 0 0 0 0)
       #(1 1 1 1 0 1 1 1 0 1 1 1 0 0 1 1)
       #(0 1 1 0 0 1 1 0 0 1 1 0 0 1 1 0)
       #(1 1 1 1 0 0 0 0 0 0 0 0 1 1 1 1)
       #(1 0 1 0 1 0 1 0 1 0 1 0 1 0 1 0)
       #(1 1 1 1 0 0 0 0 1 1 1 1 0 0 0 0)
       #(1 0 0 1 0 0 1 1 0 1 1 0 1 1 0 0)))
  (define $pat3
    '#(#(0 0 0 0 0 0 0 0 1 1 2 2 1 1 2 2)
       #(1 1 1 1 1 1 1 1 0 0 0 0 2 2 2 2)
       #(1 1 1 1 0 0 0 0 0 0 0 0 2 2 2 2)
       #(1 1 1 1 2 2 2 2 0 0 0 0 0 0 0 0)
       #(1 1 2 0 1 1 2 0 1 1 2 0 1 1 2 0)
       #(0 1 1 2 0 1 1 2 0 1 1 2 0 1 1 2)
       #(0 2 1 1 0 2 1 1 0 2 1 1 0 2 1 1)
       #(2 0 0 0 2 0 0 0 2 1 1 1 2 1 1 1)
       #(2 0 1 2 2 0 1 2 2 0 1 2 2 0 1 2)
       #(1 1 1 1 0 0 0 0 2 2 2 2 1 1 1 1)
       #(0 0 2 2 0 0 1 1 0 0 1 1 0 0 2 2)))
  (define $pat7
    '#(#(0 0 0 0 1 1 1 1 0 0 0 0 0 0 0 0)
       #(0 0 1 0 0 0 1 0 0 0 1 0 0 0 1 0)
       #(1 1 0 0 1 1 0 0 1 0 0 0 0 0 0 0)
       #(0 0 0 0 0 0 0 1 0 0 1 1 0 0 1 1)
       #(1 1 1 1 1 1 1 1 0 0 0 0 1 1 1 1)
       #(0 1 0 0 0 1 0 0 0 1 0 0 0 1 0 0)
       #(0 0 0 1 0 0 1 1 1 1 1 1 1 1 1 1)
       #(0 1 1 1 0 0 1 1 0 0 1 1 0 0 1 1)
       #(1 1 0 0 0 0 0 0 0 0 1 1 1 1 0 0)
       #(0 1 1 1 0 1 1 1 0 0 0 0 0 0 0 0)
       #(0 0 0 0 0 0 0 0 1 1 1 0 1 1 1 0)
       #(1 1 0 0 0 0 0 0 0 0 0 0 1 1 0 0)
       #(0 1 1 1 0 0 1 1 0 0 0 0 0 0 0 0)
       #(0 0 0 0 0 0 0 1 1 1 1 1 1 1 1 1)
       #(1 1 1 1 1 1 1 1 1 1 1 1 0 1 1 0)
       #(1 1 0 0 1 1 0 0 1 1 0 0 1 0 0 0)
       #(1 1 1 1 1 1 1 1 1 0 0 0 1 0 0 0)
       #(0 0 1 1 0 1 1 0 1 1 0 0 1 0 0 0)
       #(1 1 1 1 0 1 1 1 0 0 0 0 0 0 0 0)))
  ;; ---- bit reader over the 16-byte block (LSB-first); pos is a box ----
  (define ($rd src p n)
    (if (= n 0) 0
        (let loop ((left n) (shift 0)
                   (at (+ src ($shr (vector-ref p 0) 3)))
                   (bo (bitwise-and (vector-ref p 0) 7)) (res 0))
          (if (<= left 0)
              (begin (vector-set! p 0 (+ (vector-ref p 0) n)) res)
              (let* ((take (if (< left (- 8 bo)) left (- 8 bo)))
                     (chunk (bitwise-and ($shr ($u8 at) bo) (- ($shl 1 take) 1))))
                (loop (- left take) (+ shift take) (+ at 1) 0
                      (bitwise-ior res ($shl chunk shift))))))))

  (define (uastc-emit! dst mode subsets comps er wb planes ccs eps pat weights)
    (let* ((tc (if (< comps 4) comps 4))
           (levels ($shl 1 wb))
           (wt (vector-ref $wtab wb))
           ;; block-colors[subset][level] -> packed rgba as 4-vector
           (bc (make-vector subsets #f)))
      (let sub ((si 0))
        (when (< si subsets)
          (let ((e0 (make-vector 4 255)) (e1 (make-vector 4 255)))
            (if (= tc 2)
                (let ((ll ($unq (vector-ref eps (+ (* si tc 2) 0)) er))
                      (lh ($unq (vector-ref eps (+ (* si tc 2) 1)) er))
                      (al ($unq (vector-ref eps (+ (* si tc 2) 2)) er))
                      (ah ($unq (vector-ref eps (+ (* si tc 2) 3)) er)))
                  (vector-set! e0 0 ll) (vector-set! e0 1 ll) (vector-set! e0 2 ll) (vector-set! e0 3 al)
                  (vector-set! e1 0 lh) (vector-set! e1 1 lh) (vector-set! e1 2 lh) (vector-set! e1 3 ah))
                (let cc ((c 0))
                  (when (< c tc)
                    (vector-set! e0 c ($unq (vector-ref eps (+ (* si tc 2) (* c 2) 0)) er))
                    (vector-set! e1 c ($unq (vector-ref eps (+ (* si tc 2) (* c 2) 1)) er))
                    (cc (+ c 1)))))
            (let ((ramp (make-vector levels #f)))
              (let lv ((l 0))
                (when (< l levels)
                  (let ((px (make-vector 4 255)))
                    (if (= tc 2)
                        (let ((lc ($interp (vector-ref e0 0) (vector-ref e1 0) (vector-ref wt l)))
                              (ac ($interp (vector-ref e0 3) (vector-ref e1 3) (vector-ref wt l))))
                          (vector-set! px 0 lc) (vector-set! px 1 lc) (vector-set! px 2 lc) (vector-set! px 3 ac))
                        (let cc ((c 0))
                          (when (< c tc)
                            (vector-set! px c ($interp (vector-ref e0 c) (vector-ref e1 c) (vector-ref wt l)))
                            (cc (+ c 1)))))
                    (vector-set! ramp l px))
                  (lv (+ l 1))))
              (vector-set! bc si ramp)))
          (sub (+ si 1))))
      ;; scatter to the 16 texels
      (if (= planes 1)
          (let loop ((i 0))
            (when (< i 16)
              (let* ((s (if pat (vector-ref pat i) 0))
                     (px (vector-ref (vector-ref bc s) (vector-ref weights i))))
                ($u8! (+ dst (* i 4)) (vector-ref px 0))
                ($u8! (+ dst (* i 4) 1) (vector-ref px 1))
                ($u8! (+ dst (* i 4) 2) (vector-ref px 2))
                ($u8! (+ dst (* i 4) 3) (vector-ref px 3)))
              (loop (+ i 1))))
          (let loop ((i 0))
            (when (< i 16)
              (let* ((w0 (vector-ref weights (* i 2)))
                     (w1 (vector-ref weights (+ (* i 2) 1)))
                     (p0 (vector-ref (vector-ref bc 0) w0))
                     (p1 (vector-ref (vector-ref bc 0) w1)))
                (let cc ((c 0))
                  (when (< c 4)
                    ($u8! (+ dst (* i 4) c) (vector-ref (if (= c ccs) p1 p0) c))
                    (cc (+ c 1)))))
              (loop (+ i 1)))))))

  ;; decode a whole level: blocks laid out row-major, into a w*h RGBA image
  (define (uastc-general! src dst mode)
    (let ((p (vector (+ (vector-ref $hcsz mode) (vector-ref $hint mode))))  ; skip mode + hints
          (subsets (vector-ref $sub mode))
          (er (vector-ref $er mode))
          (wb (vector-ref $wb mode))
          (comps (vector-ref $cmp mode)))
      ;; common pattern -> precomputed partition table
      (let ((common (cond ((memv mode '(2 4 7 9 16)) ($rd src p 5))
                          ((= mode 3) ($rd src p 4))
                          (else 0))))
        (when (memv mode '(2 4 7 9 16)) (set! subsets 2))
        (when (= mode 3) (set! subsets 3))
        ;; dual plane / ccs
        (let* ((planes (if (or (memv mode '(6 11 13)) (= mode 17)) 2 1))
               (ccs (cond ((memv mode '(6 11 13)) ($rd src p 2))
                          ((= mode 17) 3)
                          (else -1)))
               (total-values (* comps 2 subsets))
               (ep-bits ($bise-b er)) (ep-trits ($bise-t er)) (ep-quints ($bise-q er))
               (total-tqs (cond ((not (= ep-trits 0)) (quotient (+ total-values 4) 5))
                                ((not (= ep-quints 0)) (quotient (+ total-values 2) 3))
                                (else 0)))
               (bundle (if (not (= ep-trits 0)) 5 3))
               (mul (if (not (= ep-trits 0)) 3 5))
               (tqv (make-vector 8 0)))
          ;; read the trit/quint bundles
          (let loop ((i 0))
            (when (< i total-tqs)
              (let ((nb (if (= i (- total-tqs 1))
                            (let ((rem (- total-values (* (- total-tqs 1) bundle))))
                              (if (not (= ep-trits 0))
                                  (cond ((= rem 1) 2) ((= rem 2) 4) ((= rem 3) 5) ((= rem 4) 7) (else 8))
                                  (cond ((= rem 1) 3) ((= rem 2) 5) (else 7))))
                            (if (not (= ep-trits 0)) 8 7))))
                (vector-set! tqv i ($rd src p nb)))
              (loop (+ i 1))))
          ;; endpoints: low bits | (base-3/5 digit << bits)
          (let ((eps (make-vector total-values 0)) (accum 0) (arem 0) (nt 0))
            (let loop ((i 0))
              (when (< i total-values)
                (let ((value ($rd src p ep-bits)))
                  (when (not (= total-tqs 0))
                    (when (= arem 0) (set! accum (vector-ref tqv nt)) (set! nt (+ nt 1)) (set! arem bundle))
                    (let ((v (remainder accum mul)))
                      (set! accum (quotient accum mul)) (set! arem (- arem 1))
                      (set! value (bitwise-ior value ($shl v ep-bits)))))
                  (vector-set! eps i value))
                (loop (+ i 1))))
            ;; partition pattern + anchors
            (let* ((pat (cond ((= subsets 1) #f)
                              ((= mode 3) (vector-ref $pat3 common))
                              ((= mode 7) (vector-ref $pat7 common))
                              (else (vector-ref $pat2 common))))
                   (anchors (if (= subsets 1) #f
                                (let ((av (make-vector subsets 0)))
                                  (let sub ((s 0))
                                    (when (< s subsets)
                                      (let find ((i 0))
                                        (cond ((= i 16) #f)
                                              ((= (vector-ref pat i) s) (vector-set! av s i))
                                              (else (find (+ i 1)))))
                                      (sub (+ s 1))))
                                  av))))
              ;; weights
              (let ((weights (make-vector (if (= planes 2) 32 16) 0)))
                (cond
                 ((= mode 18)
                  (let loop ((i 0)) (when (< i 16)
                    (vector-set! weights i ($rd src p (if (= i 0) (- wb 1) wb))) (loop (+ i 1)))))
                 ((= planes 2)
                  (vector-set! weights 0 ($rd src p (- wb 1)))
                  (vector-set! weights 1 ($rd src p (- wb 1)))
                  (let loop ((i 2)) (when (< i 32) (vector-set! weights i ($rd src p wb)) (loop (+ i 1)))))
                 ((= subsets 1)
                  (vector-set! weights 0 ($rd src p (- wb 1)))
                  (let loop ((i 1)) (when (< i 16) (vector-set! weights i ($rd src p wb)) (loop (+ i 1)))))
                 (else
                  (let loop ((i 0)) (when (< i 16)
                    (let ((anchor? (let a ((s 0)) (cond ((= s subsets) #f)
                                                        ((= (vector-ref anchors s) i) #t)
                                                        (else (a (+ s 1)))))))
                      (vector-set! weights i ($rd src p (if anchor? (- wb 1) wb))))
                    (loop (+ i 1))))))
                ;; build block colors per subset/level, then scatter
                (uastc-emit! dst mode subsets comps er wb planes ccs eps pat weights))))))))

  ;; interpolate endpoints into per-subset colour ramps and write pixels
  (define (uastc-block-mode src)
    (vector-ref $hm (bitwise-and ($u8 src) 127)))

  ;; decode one 16-byte block at `src' -> 16 RGBA texels at `dst' (row-major)
  (define (uastc-block! src dst)
    (let ((mode (vector-ref $hm (bitwise-and ($u8 src) 127))))
      (cond
       ((>= mode 19)
        (let loop ((i 0)) (when (< i 16)
          ($u8! (+ dst (* i 4)) 255) ($u8! (+ dst (* i 4) 1) 0)
          ($u8! (+ dst (* i 4) 2) 255) ($u8! (+ dst (* i 4) 3) 255) (loop (+ i 1)))))
       ((= mode $solid)
        (let* ((p (vector (vector-ref $hcsz mode)))
               (r ($rd src p 8)) (g ($rd src p 8)) (b ($rd src p 8)) (a ($rd src p 8)))
          (let loop ((i 0)) (when (< i 16)
            ($u8! (+ dst (* i 4)) r) ($u8! (+ dst (* i 4) 1) g)
            ($u8! (+ dst (* i 4) 2) b) ($u8! (+ dst (* i 4) 3) a) (loop (+ i 1))))))
       (else (uastc-general! src dst mode)))))

  (define (uastc-decode! src dst w h)
    (let* ((nbx (quotient (+ w 3) 4))
           (nby (quotient (+ h 3) 4))
           (tmp 0))
      ;; a 64-byte scratch for one block, placed just past the image
      (let ((scratch (+ dst (* w h 4))))
        (let by ((byi 0))
          (when (< byi nby)
            (let bx ((bxi 0))
              (when (< bxi nbx)
                (uastc-block! (+ src (* (+ (* byi nbx) bxi) 16)) scratch)
                ;; copy the 4x4 texels into the image, clipping at edges
                (let ty ((tyi 0))
                  (when (< tyi 4)
                    (let ((py (+ (* byi 4) tyi)))
                      (when (< py h)
                        (let tx ((txi 0))
                          (when (< txi 4)
                            (let ((px (+ (* bxi 4) txi)))
                              (when (< px w)
                                (let ((s (+ scratch (* (+ (* tyi 4) txi) 4)))
                                      (d (+ dst (* (+ (* py w) px) 4))))
                                  ($u8! d ($u8 s)) ($u8! (+ d 1) ($u8 (+ s 1)))
                                  ($u8! (+ d 2) ($u8 (+ s 2))) ($u8! (+ d 3) ($u8 (+ s 3))))))
                            (tx (+ txi 1))))))
                    (ty (+ tyi 1))))
                (bx (+ bxi 1))))
            (by (+ byi 1)))))))
)
