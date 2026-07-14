;; EXT_meshopt_compression, decoded from the meshoptimizer sources --
;; the vertex and index codecs gltfpack emits, and the octahedral /
;; quaternion / exponential filters, all in pure Scheme over staging
;; memory.  A compressed bufferView's bytes come in, the decoded
;; interleaved data goes out, and (gfx gltf) can then read it like any
;; uncompressed asset.
;;
;;   (meshopt-vertex! src slen dst count stride)   ; ATTRIBUTES
;;   (meshopt-index! src slen dst count stride)     ; TRIANGLES
;;   (meshopt-filter-oct! dst count stride)         ; then, in place
;;
;; Verified byte-for-byte against the reference meshopt_decoder on
;; gltfpack output (test/meshopt.ss).
;;
;; Note: gltfpack always also emits KHR_mesh_quantization (integer
;; vertex formats -- normalized shorts/bytes for positions, uvs and
;; normals).  That is a SEPARATE extension: this decoder unpacks the
;; meshopt streams faithfully, but the (gfx gltf) mesh pipeline still
;; reads floats, so a fully quantized asset needs that extension too
;; before it renders correctly end-to-end.  The codec here is complete;
;; quantization dequant is the follow-up.
;;
;; Copyright (c) 2026 guenchi. MIT license; see LICENSE.
(library (gfx meshopt)
  (export meshopt-vertex! meshopt-index! meshopt-index-sequence!
          meshopt-filter-oct! meshopt-filter-quat! meshopt-filter-exp!)
  (import (rnrs))

  (define ($u8 at) (%mem-u8-ref at))
  (define ($u8! at v) (%mem-u8-set! at (bitwise-and v 255)))
  (define ($unzig v)                    ; (-(v&1)) ^ (v>>1)
    (bitwise-xor (- 0 (bitwise-and v 1))
                 (bitwise-arithmetic-shift-right v 1)))

  ;; ---- the vertex codec (ATTRIBUTES) ----
  ;; version 0: no control bytes, every byte-plane a type-0 zigzag
  ;; delta; version 1 adds per-column control bytes and channels.
  ;; We decode both; the golden exercises version 0
  (define $bits-v0 '#(0 2 4 8))
  (define $bits-v1 '#(0 1 2 4 8))

  ;; decode one 16-value byte group into out[0..15] from src; returns
  ;; the advanced source pointer.  bits in {0,1,2,4,8}
  (define ($mo-group src out bits)
    (cond
     ((= bits 0)
      (let z ((i 0)) (when (< i 16) (vector-set! out i 0) (z (+ i 1))))
      src)
     ((= bits 8)
      (let c ((i 0))
        (when (< i 16)
          (vector-set! out i ($u8 (+ src i))) (c (+ i 1))))
      (+ src 16))
     (else
      (let* ((fixed (quotient (* bits 16) 8))
             (sentinel (- (bitwise-arithmetic-shift-left 1 bits) 1))
             (per (quotient 8 bits)))    ; values per fixed byte
        (let val ((i 0) (ov (+ src fixed)))
          (if (= i 16)
              ov
              (let* ((bi (+ src (quotient i per)))
                     (byte (if (= bits 1)
                               ($mo-rev8 ($u8 bi))
                               ($u8 bi)))
                     (slot (remainder i per))
                     (shift (- 8 bits (* slot bits)))
                     (enc (bitwise-and
                           (bitwise-arithmetic-shift-right byte shift)
                           sentinel)))
                (if (= enc sentinel)
                    (begin (vector-set! out i ($u8 ov))
                           (val (+ i 1) (+ ov 1)))
                    (begin (vector-set! out i enc)
                           (val (+ i 1) ov))))))))))

  ;; reverse the 8 bits of a byte (1-bit groups are stored reversed)
  (define ($mo-rev8 b)
    (let loop ((i 0) (r 0) (b b))
      (if (= i 8)
          r
          (loop (+ i 1)
                (bitwise-ior (bitwise-arithmetic-shift-left r 1)
                             (bitwise-and b 1))
                (bitwise-arithmetic-shift-right b 1)))))

  ;; decode one byte-plane of `va` values (va a multiple of 16) into
  ;; plane[0..va-1]; header selects each group's bit width.  Returns
  ;; the advanced source pointer
  (define ($mo-bytes src plane va bits-table)
    (let* ((ngroups (quotient va 16))
           (hsize (quotient (+ ngroups 3) 4))
           (grp (make-vector 16 0)))
      (let g ((gi 0) (data (+ src hsize)))
        (if (= gi ngroups)
            data
            (let* ((hb ($u8 (+ src (quotient gi 4))))
                   (sel (bitwise-and
                         (bitwise-arithmetic-shift-right
                          hb (* (remainder gi 4) 2))
                         3))
                   (bits (vector-ref bits-table sel))
                   (data2 ($mo-group data grp bits)))
              (let put ((i 0))
                (when (< i 16)
                  (vector-set! plane (+ (* gi 16) i) (vector-ref grp i))
                  (put (+ i 1))))
              (g (+ gi 1) data2))))))

  (define (meshopt-vertex! src slen dst count stride)
    (let* ((header ($u8 src))
           (version (bitwise-and header 15)))
      (unless (= (bitwise-and header #xF0) #xA0)
        (error 'meshopt "bad vertex header"))
      (unless (<= version 1) (error 'meshopt "vertex version" version))
      (let* ((tail-size (+ stride (if (= version 0) 0 (quotient stride 4))))
             (tail (+ src slen tail-size (- 0 tail-size) (- slen slen)))
             (tail-at (+ src (- slen tail-size)))
             (last (make-vector stride 0))
             (chans (make-vector (quotient stride 4) 0))
             (blk (min (bitwise-and (quotient 8192 stride) -16) 256)))
        ;; seed the last vertex (and channels for v1) from the tail
        (let s ((i 0)) (when (< i stride)
                         (vector-set! last i ($u8 (+ tail-at i)))
                         (s (+ i 1))))
        (when (= version 1)
          (let c ((i 0)) (when (< i (quotient stride 4))
                           (vector-set! chans i
                                        ($u8 (+ tail-at stride i)))
                           (c (+ i 1)))))
        (let block ((voff 0) (data (+ src 1)))
          (if (>= voff count)
              #t
              (let* ((bs (min blk (- count voff)))
                     (va (bitwise-and (+ bs 15) -16))
                     (obase (+ dst (* voff stride))))
                (block (+ voff blk)
                       ($mo-block data dst obase bs va stride last chans
                                  version))))))))

  ;; a plane buffer reused across columns (max va = 256)
  (define $mo-plane (make-vector 256 0))
  (define $mo-plane2 (make-vector 256 0))
  (define $mo-plane3 (make-vector 256 0))
  (define $mo-plane4 (make-vector 256 0))

  (define ($mo-block data dst obase bs va stride last chans version)
    (let* ((csize (if (= version 0) 0 (quotient stride 4)))
           (ctrl-at data))
      (let col ((k 0) (data (+ data csize)))
        (if (>= k stride)
            (begin
              ;; refresh last vertex = the block's final decoded one
              (let r ((b 0))
                (when (< b stride)
                  (vector-set! last b ($u8 (+ obase (* (- bs 1) stride) b)))
                  (r (+ b 1))))
              data)
            ;; version 0: four independent byte-planes, each type 0.
            ;; version 1: a control byte per column drives the four
            ;; planes, then the column's channel type reconstitutes
            (let* ((cb (if (= version 0) 0 ($u8 (+ ctrl-at (quotient k 4))))))
              (let plane ((j 0) (data data))
                (if (= j 4)
                    ;; the four planes are filled; delta-decode them
                    (begin
                      ($mo-deltas dst obase bs va stride k last
                                  (if (= version 0) 0
                                      (vector-ref chans (quotient k 4))))
                      (col (+ k 4) data))
                    (let ((ctrl (if (= version 0) 0
                                    (bitwise-and
                                     (bitwise-arithmetic-shift-right cb (* j 2))
                                     3)))
                          (pl (vector-ref (vector $mo-plane $mo-plane2
                                                  $mo-plane3 $mo-plane4)
                                          j)))
                      (cond
                       ((and (= version 1) (= ctrl 2)) ; zero
                        (let z ((i 0)) (when (< i va)
                                         (vector-set! pl i 0) (z (+ i 1))))
                        (plane (+ j 1) data))
                       ((and (= version 1) (= ctrl 3)) ; literal
                        (let c ((i 0)) (when (< i bs)
                                         (vector-set! pl i ($u8 (+ data i)))
                                         (c (+ i 1))))
                        (plane (+ j 1) (+ data bs)))
                       (else
                        (let* ((tbl (if (= version 0) $bits-v0
                                        (list->vector
                                         (let sub ((v (vector->list $bits-v1))
                                                   (n ctrl))
                                           (if (= n 0) v (sub (cdr v) (- n 1)))))))
                               (data2 ($mo-bytes data pl va tbl)))
                          (plane (+ j 1) data2))))))))))))

  ;; reconstitute AoS bytes for the 4-byte column at k from the four
  ;; SoA planes; channel type 0 = per-byte zigzag delta (v0 and the
  ;; common v1 case)
  (define ($mo-deltas dst obase bs va stride k last chan)
    (let ((ctype (bitwise-and chan 3)))
      (cond
       ((= ctype 0)
        ;; each of the four bytes is its own type-0 stream
        (let byte ((j 0))
          (when (< j 4)
            (let ((pl (vector-ref (vector $mo-plane $mo-plane2
                                          $mo-plane3 $mo-plane4) j)))
              (let d ((i 0) (p (vector-ref last (+ k j))))
                (if (= i bs)
                    #f
                    (let ((np (bitwise-and
                               (+ p ($unzig (vector-ref pl i))) 255)))
                      ($u8! (+ obase (* i stride) k j) np)
                      (d (+ i 1) np)))))
            (byte (+ j 1)))))
       ((= ctype 1)
        ;; two 16-bit little-endian streams (bytes 0..1 and 2..3)
        (let pair ((h 0))
          (when (< h 2)
            (let* ((lo (vector-ref (vector $mo-plane $mo-plane3)
                                   h))
                   (hi (vector-ref (vector $mo-plane2 $mo-plane4)
                                   h))
                   (b0 (+ k (* h 2))))
              (let d ((i 0)
                      (p (+ (vector-ref last b0)
                            (* 256 (vector-ref last (+ b0 1))))))
                (if (= i bs)
                    #f
                    (let* ((v (+ (vector-ref lo i)
                                 (* 256 (vector-ref hi i))))
                           (np (bitwise-and (+ p ($unzig v)) 65535)))
                      ($u8! (+ obase (* i stride) b0) np)
                      ($u8! (+ obase (* i stride) b0 1)
                            (bitwise-arithmetic-shift-right np 8))
                      (d (+ i 1) np)))))
            (pair (+ h 1)))))
       (else
        ;; type 2: one 32-bit XOR-rotate stream over the whole column
        (let* ((rot (bitwise-and (- 32 (bitwise-arithmetic-shift-right chan 4))
                                 31)))
          (let d ((i 0)
                  (p (+ (vector-ref last k)
                        (* 256 (vector-ref last (+ k 1)))
                        (* 65536 (vector-ref last (+ k 2)))
                        (* 16777216 (vector-ref last (+ k 3))))))
            (unless (= i bs)
              (let* ((v (+ (vector-ref $mo-plane i)
                           (* 256 (vector-ref $mo-plane2 i))
                           (* 65536 (vector-ref $mo-plane3 i))
                           (* 16777216 (vector-ref $mo-plane4 i))))
                     (vr (bitwise-and
                          (bitwise-ior
                           (bitwise-arithmetic-shift-left v rot)
                           (bitwise-arithmetic-shift-right v (- 32 rot)))
                          #xFFFFFFFF))
                     (np (bitwise-xor p vr)))
                (let w ((j 0))
                  (when (< j 4)
                    ($u8! (+ obase (* i stride) k j)
                          (bitwise-arithmetic-shift-right np (* j 8)))
                    (w (+ j 1))))
                (d (+ i 1) np)))))))))

  ;; ---- the index codec (TRIANGLES) ----
  (define (meshopt-index! src slen dst count stride)
    (let* ((header ($u8 src))
           (version (bitwise-and header 15)))
      (unless (= (bitwise-and header #xF0) #xE0)
        (error 'meshopt "bad index header"))
      (let* ((fecmax (if (>= version 1) 13 15))
             (efifo (make-vector 32 0))   ; 16 edges * 2
             (vfifo (make-vector 16 0))
             (eoff (vector 0)) (voff (vector 0))
             (code (+ src 1))
             (code-end (+ src 1 (quotient count 3)))
             (data (vector code-end))
             (aux (- (+ src slen) 16))
             (state (vector 0 0))         ; next, last
             (out (vector 0)))            ; output write cursor (index #)
        (letrec ((emit (lambda (a b c)
          (let ((o (vector-ref out 0)))
            (if (= stride 2)
                (begin ($mo-w16 (+ dst (* o 2)) a)
                       ($mo-w16 (+ dst (* (+ o 1) 2)) b)
                       ($mo-w16 (+ dst (* (+ o 2) 2)) c))
                (begin ($mo-w32 (+ dst (* o 4)) a)
                       ($mo-w32 (+ dst (* (+ o 1) 4)) b)
                       ($mo-w32 (+ dst (* (+ o 2) 4)) c)))
            (vector-set! out 0 (+ o 3)))))
                 (pushe (lambda (a b)
          (let ((o (vector-ref eoff 0)))
            (vector-set! efifo (* o 2) a)
            (vector-set! efifo (+ (* o 2) 1) b)
            (vector-set! eoff 0 (bitwise-and (+ o 1) 15)))))
                 (pushv (lambda (v)
          (let ((o (vector-ref voff 0)))
            (vector-set! vfifo o v)
            (vector-set! voff 0 (bitwise-and (+ o 1) 15)))))
                 (rdv (lambda (i)
          (vector-ref vfifo (bitwise-and (- (vector-ref voff 0) 1 i) 15))))
                 (decodev (lambda ()                 ; LEB128 + zigzag delta
          (let loop ((v 0) (sh 0))
            (let ((b ($u8 (vector-ref data 0))))
              (vector-set! data 0 (+ (vector-ref data 0) 1))
              (let ((v (bitwise-ior
                        v (bitwise-arithmetic-shift-left
                           (bitwise-and b 127) sh))))
                (if (< b 128)
                    (let ((nl (+ (vector-ref state 1) ($unzig v))))
                      (vector-set! state 1 nl) nl)
                    (loop v (+ sh 7))))))))) ; close decodev lambda+binding
        (let tri ((t 0))
          (when (< t (quotient count 3))
            (let ((ct ($u8 (+ code t))))
              (cond
               ((< ct #xF0)
                (let* ((fe (bitwise-arithmetic-shift-right ct 4))
                       (fec (bitwise-and ct 15))
                       (ei (bitwise-and (- (vector-ref eoff 0) 1 fe) 15))
                       (a (vector-ref efifo (* ei 2)))
                       (b (vector-ref efifo (+ (* ei 2) 1))))
                  (let ((c (cond
                            ((< fec fecmax)
                             ;; the edge-FIFO path reads vertexfifo at
                             ;; (voff-1-fec), i.e. rdv fec -- unlike
                             ;; the codeaux/reset paths' (voff-feb)
                             (if (= fec 0)
                                 (let ((n (vector-ref state 0)))
                                   (vector-set! state 0 (+ n 1))
                                   (pushv n) n)
                                 (rdv fec)))
                            ((= fec 13)
                             (let ((c (- (vector-ref state 1) 1)))
                               (vector-set! state 1 c) (pushv c) c))
                            ((= fec 14)
                             (let ((c (+ (vector-ref state 1) 1)))
                               (vector-set! state 1 c) (pushv c) c))
                            (else
                             (let ((c (decodev))) (pushv c) c)))))
                    (pushe c b) (pushe a c) (emit a b c))))
               ((< ct #xFE)
                (let* ((codeaux ($u8 (+ aux (bitwise-and ct 15))))
                       (feb (bitwise-arithmetic-shift-right codeaux 4))
                       (fec (bitwise-and codeaux 15))
                       (a (vector-ref state 0)))
                  (vector-set! state 0 (+ a 1))
                  (let* ((b (if (= feb 0)
                                (let ((n (vector-ref state 0)))
                                  (vector-set! state 0 (+ n 1)) n)
                                (rdv (- feb 1))))
                         (c (if (= fec 0)
                                (let ((n (vector-ref state 0)))
                                  (vector-set! state 0 (+ n 1)) n)
                                (rdv (- fec 1)))))
                    (emit a b c)
                    (pushv a)
                    (when (= feb 0) (pushv b))
                    (when (= fec 0) (pushv c))
                    (pushe b a) (pushe c b) (pushe a c))))
               (else
                (let ((codeaux ($u8 (vector-ref data 0))))
                  (vector-set! data 0 (+ (vector-ref data 0) 1))
                  (when (= codeaux 0)
                    (vector-set! state 0 0)
                    (let z ((i 0)) (when (< i 16)
                                     (vector-set! vfifo i 0) (z (+ i 1)))))
                  (let* ((fea (if (= ct #xFE) 0 15))
                         (feb (bitwise-arithmetic-shift-right codeaux 4))
                         (fec (bitwise-and codeaux 15))
                         (a (if (= fea 0)
                                (let ((n (vector-ref state 0)))
                                  (vector-set! state 0 (+ n 1)) n)
                                0))
                         (b (if (= feb 0)
                                (let ((n (vector-ref state 0)))
                                  (vector-set! state 0 (+ n 1)) n)
                                (rdv (- feb 1))))
                         (c (if (= fec 0)
                                (let ((n (vector-ref state 0)))
                                  (vector-set! state 0 (+ n 1)) n)
                                (rdv (- fec 1)))))
                    (let ((a (if (= fea 15) (decodev) a))
                          (b (if (= feb 15) (decodev) b))
                          (c (if (= fec 15) (decodev) c)))
                      (emit a b c)
                      (pushv a)
                      (when (or (= feb 0) (= feb 15)) (pushv b))
                      (when (or (= fec 0) (= fec 15)) (pushv c))
                      (pushe b a) (pushe c b) (pushe a c)))))))
            (tri (+ t 1))))))))

  (define ($mo-w16 at v)
    ($u8! at v) ($u8! (+ at 1) (bitwise-arithmetic-shift-right v 8)))
  (define ($mo-w32 at v)
    ($u8! at v) ($u8! (+ at 1) (bitwise-arithmetic-shift-right v 8))
    ($u8! (+ at 2) (bitwise-arithmetic-shift-right v 16))
    ($u8! (+ at 3) (bitwise-arithmetic-shift-right v 24)))

  ;; the dual-baseline index sequence (INDICES)
  (define (meshopt-index-sequence! src slen dst count stride)
    (let ((last (vector 0 0))
          (data (vector (+ src 1))))
      (let each ((i 0))
        (when (< i count)
          (let loop ((v 0) (sh 0))
            (let ((b ($u8 (vector-ref data 0))))
              (vector-set! data 0 (+ (vector-ref data 0) 1))
              (let ((v (bitwise-ior v (bitwise-arithmetic-shift-left
                                       (bitwise-and b 127) sh))))
                (if (< b 128)
                    (let* ((base (bitwise-and v 1))
                           (vv (bitwise-arithmetic-shift-right v 1))
                           (nl (+ (vector-ref last base) ($unzig vv))))
                      (vector-set! last base nl)
                      (if (= stride 2)
                          ($mo-w16 (+ dst (* i 2)) nl)
                          ($mo-w32 (+ dst (* i 4)) nl)))
                    (loop v (+ sh 7))))))
          (each (+ i 1))))))

  ;; ---- the filters, in place after vertex decode ----
  (define ($s16 at)                     ; signed 16-bit LE
    (let ((v (+ ($u8 at) (* 256 ($u8 (+ at 1))))))
      (if (>= v 32768) (- v 65536) v)))
  (define ($s8 v) (if (>= v 128) (- v 256) v))
  (define ($iround x)
    (if (fl<? x 0.0)
        (- 0 (%fl->fx (fl+ (fl- 0.0 x) 0.5)))
        (%fl->fx (fl+ x 0.5))))

  ;; octahedral normals/tangents: stride 4 (int8) or 8 (int16)
  (define (meshopt-filter-oct! dst count stride)
    (let* ((bytes (quotient stride 4))    ; 1 or 2 per component
           (maxv (fixnum->flonum
                  (- (bitwise-arithmetic-shift-left 1 (- (* bytes 8) 1)) 1))))
      (let each ((i 0))
        (when (< i count)
          (let* ((at (+ dst (* i stride)))
                 (rd (lambda (c) (if (= bytes 1)
                                     (fixnum->flonum
                                      ($s8 ($u8 (+ at c))))
                                     (fixnum->flonum ($s16 (+ at (* c 2)))))))
                 (x (rd 0)) (y (rd 1))
                 (z (fl- (fl- (rd 2) (flabs x)) (flabs y)))
                 (tt (if (fl<? z 0.0) z 0.0))
                 (x (fl+ x (if (fl<? x 0.0) (fl- 0.0 tt) tt)))
                 (y (fl+ y (if (fl<? y 0.0) (fl- 0.0 tt) tt)))
                 (l (flsqrt (fl+ (fl+ (fl* x x) (fl* y y)) (fl* z z))))
                 (s (fl/ maxv l))
                 (wr (lambda (c v)
                       (if (= bytes 1)
                           ($u8! (+ at c) ($iround (fl* v s)))
                           ($mo-w16 (+ at (* c 2)) ($iround (fl* v s)))))))
            (wr 0 x) (wr 1 y) (wr 2 z))
          (each (+ i 1))))))

  (define (flabs x) (if (fl<? x 0.0) (fl- 0.0 x) x))

  ;; quaternions: stride 8, max-component reconstruction
  (define (meshopt-filter-quat! dst count stride)
    (let ((scale (fl/ 32767.0 (flsqrt 2.0))))
      (let each ((i 0))
        (when (< i count)
          (let* ((at (+ dst (* i 8)))
                 (i3 ($s16 (+ at 6)))
                 (sf (bitwise-ior i3 3))
                 (s (fixnum->flonum sf))
                 (x (fixnum->flonum ($s16 at)))
                 (y (fixnum->flonum ($s16 (+ at 2))))
                 (z (fixnum->flonum ($s16 (+ at 4))))
                 (ww (fl- (fl* (fl* s s) 2.0)
                          (fl+ (fl+ (fl* x x) (fl* y y)) (fl* z z))))
                 (w (flsqrt (if (fl<? ww 0.0) 0.0 ww)))
                 (ss (fl/ scale s))
                 (qc (bitwise-and i3 3))
                 (put (lambda (slot v)
                        ($mo-w16 (+ at (* (bitwise-and slot 3) 2))
                                 (let ((n ($iround (fl* v ss))))
                                   (if (< n 0) (+ n 65536) n))))))
            (put (+ qc 1) x) (put (+ qc 2) y) (put (+ qc 3) z)
            (put qc w))
          (each (+ i 1))))))

  ;; exponential: an independent exponent (high byte) + signed
  ;; 24-bit mantissa per 32-bit component -- read as separate bytes
  ;; so the mantissa (< 2^24) stays inside fixnum range
  (define (meshopt-filter-exp! dst count stride)
    (let ((n (quotient (* count stride) 4)))
      (let each ((i 0))
        (when (< i n)
          (let* ((at (+ dst (* i 4)))
                 (mm (+ ($u8 at) (* 256 ($u8 (+ at 1)))
                        (* 65536 ($u8 (+ at 2)))))
                 (m (if (>= mm #x800000) (- mm #x1000000) mm))
                 (e ($s8 ($u8 (+ at 3))))
                 (r (fl* (fixnum->flonum m) (flexpt 2.0 (fixnum->flonum e)))))
            (%mem-f32-set! at r))
          (each (+ i 1))))))

  (define (flexpt b e)                  ; 2^e for integer e via squaring
    (if (fl<? e 0.0)
        (fl/ 1.0 (flexpt b (fl- 0.0 e)))
        (let loop ((k (%fl->fx e)) (acc 1.0))
          (if (= k 0) acc (loop (- k 1) (fl* acc b)))))))
