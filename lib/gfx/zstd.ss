;; Zstandard decompression, from RFC 8878 -- the frame, the block
;; types (raw / RLE / compressed), Huffman-coded literals and the
;; three FSE-coded sequence streams, over staging memory.  KTX2 wraps
;; UASTC payloads in a zstd frame (supercompressionScheme 2); this is
;; what unwraps them.  General enough to inflate any single-frame zstd
;; stream that fits in memory.
;;
;;   (zstd-decode! src slen dst scratch)   ; -> bytes written at dst
;;
;; `scratch' is a spare region (>= one block's literal size) the
;; decoder stages decoded literals in before the sequence stage
;; interleaves them with back-references.
;;
;; Every bitstream is little-endian.  FSE table descriptions are read
;; forward from a byte; Huffman and FSE payloads are read backward from
;; the end of their range (offset counts down, a sentinel bit in the
;; last byte marks the top).  Structure mirrors the spec's educational
;; decoder; verified byte-for-byte against the zstd CLI (test/zstd.ss).
;;
;; Copyright (c) 2026 guenchi. MIT license; see LICENSE.
(library (gfx zstd)
  (export zstd-decode! zstd-frame-size)
  (import (rnrs))

  (define ($u8 at) (%mem-u8-ref at))
  (define ($u8! at v) (%mem-u8-set! at (bitwise-and v 255)))
  (define ($u16 at) (+ ($u8 at) (* 256 ($u8 (+ at 1)))))
  (define ($u24 at) (+ ($u16 at) (* 65536 ($u8 (+ at 2)))))
  (define ($u32 at) (+ ($u24 at) (* 16777216 ($u8 (+ at 3)))))

  (define ($hb v)                       ; floor(log2 v), -1 for 0
    (let loop ((v v) (n -1))
      (if (= v 0) n (loop (bitwise-arithmetic-shift-right v 1) (+ n 1)))))
  (define ($shl a n) (bitwise-arithmetic-shift-left a n))
  (define ($shr a n) (bitwise-arithmetic-shift-right a n))

  ;; read n bits LSB-first from `base' at bit position `bitoff'
  (define ($rble base n bitoff)
    (let loop ((left n) (shift 0)
               (at (+ base (quotient bitoff 8)))
               (bo (bitwise-and bitoff 7)) (res 0))
      (if (<= left 0) res
          (let* ((take (if (< left (- 8 bo)) left (- 8 bo)))
                 (chunk (bitwise-and ($shr ($u8 at) bo)
                                     (- ($shl 1 take) 1))))
            (loop (- left take) (+ shift take) (+ at 1) 0
                  (+ res ($shl chunk shift)))))))

  ;; ---- forward reader #(base bitpos) ----
  (define ($fbr base) (vector base 0))
  (define ($fbr-read r n)
    (if (= n 0) 0
        (let ((v ($rble (vector-ref r 0) n (vector-ref r 1))))
          (vector-set! r 1 (+ (vector-ref r 1) n)) v)))
  (define ($fbr-rewind r n) (vector-set! r 1 (- (vector-ref r 1) n)))
  (define ($fbr-align r) (vector-set! r 1 (* 8 (quotient (+ (vector-ref r 1) 7) 8))))
  (define ($fbr-bytes r) (quotient (+ (vector-ref r 1) 7) 8))

  ;; ---- backward reader #(base off): reads bits below off, LSB-first,
  ;; padding with zero once off goes negative ----
  (define ($bbr base len)
    (vector base (- (* len 8) (- 8 ($hb ($u8 (+ base len -1)))))))
  (define ($bbr-read r n)
    (if (= n 0) 0
        (let ((off (- (vector-ref r 1) n)))
          (vector-set! r 1 off)
          (if (>= off 0)
              ($rble (vector-ref r 0) n off)
              (let* ((ab (+ n off))
                     (res (if (> ab 0) ($rble (vector-ref r 0) ab 0) 0)))
                ($shl res (- 0 off)))))))
  (define ($bbr-off r) (vector-ref r 1))

  ;; =================== FSE ===================
  ;; decode table #(accuracyLog symv nbv nsv), indexed by state.
  (define ($fse-peek dt st) (vector-ref (vector-ref dt 1) st))
  (define ($fse-update dt st br)
    (+ (vector-ref (vector-ref dt 3) st)
       ($bbr-read br (vector-ref (vector-ref dt 2) st))))

  ;; build a decode table from a normalized-count vector (counts[0..nsym))
  (define ($fse-build counts nsym alog)
    (let* ((size ($shl 1 alog))
           (symv (make-vector size 0))
           (nbv (make-vector size 0))
           (nsv (make-vector size 0))
           (sd (make-vector nsym 0))
           (ht size))
      (let lp ((s 0))
        (when (< s nsym)
          (when (= -1 (vector-ref counts s))
            (set! ht (- ht 1))
            (vector-set! symv ht s)
            (vector-set! sd s 1))
          (lp (+ s 1))))
      (let ((step (+ ($shr size 1) ($shr size 3) 3)) (mask (- size 1)))
        (let sp ((s 0) (pos 0))
          (when (< s nsym)
            (let ((c (vector-ref counts s)))
              (if (<= c 0)
                  (sp (+ s 1) pos)
                  (begin
                    (vector-set! sd s c)
                    (let place ((i 0) (pos pos))
                      (if (= i c)
                          (sp (+ s 1) pos)
                          (begin
                            (vector-set! symv pos s)
                            (let nx ((p (bitwise-and (+ pos step) mask)))
                              (if (>= p ht)
                                  (nx (bitwise-and (+ p step) mask))
                                  (place (+ i 1) p))))))))))))
      (let cell ((i 0))
        (when (< i size)
          (let* ((s (vector-ref symv i)) (nsd (vector-ref sd s)))
            (vector-set! sd s (+ nsd 1))
            (let ((nb (- alog ($hb nsd))))
              (vector-set! nbv i nb)
              (vector-set! nsv i (- ($shl nsd nb) size))))
          (cell (+ i 1))))
      (vector alog symv nbv nsv)))

  ;; decode an FSE header (forward stream) -> #(counts nsym accuracyLog)
  (define ($fse-decode-header r)
    (let* ((alog (+ 5 ($fbr-read r 4)))
           (freqs (make-vector 256 0)))
      (let loop ((remaining ($shl 1 alog)) (symb 0))
        (if (or (<= remaining 0) (>= symb 256))
            (begin ($fbr-align r) (vector freqs symb alog))
            (let* ((bits (+ 1 ($hb (+ remaining 1))))
                   (val ($fbr-read r bits))
                   (lm (- ($shl 1 (- bits 1)) 1))
                   (thr (- (- ($shl 1 bits) 1) (+ remaining 1)))
                   (val (cond ((< (bitwise-and val lm) thr)
                               ($fbr-rewind r 1) (bitwise-and val lm))
                              ((> val lm) (- val thr))
                              (else val)))
                   (proba (- val 1))
                   (remaining (- remaining (if (< proba 0) (- proba) proba))))
              (vector-set! freqs symb proba)
              (let ((symb (+ symb 1)))
                (if (= proba 0)
                    (let outer ((rep ($fbr-read r 2)) (symb symb))
                      (let inner ((k rep) (symb symb))
                        (if (and (> k 0) (< symb 256))
                            (begin (vector-set! freqs symb 0)
                                   (inner (- k 1) (+ symb 1)))
                            (if (= rep 3)
                                (outer ($fbr-read r 2) symb)
                                (loop remaining symb)))))
                    (loop remaining symb))))))))

  (define ($nc-counts nc) (vector-ref nc 0))
  (define ($nc-nsym nc) (vector-ref nc 1))
  (define ($nc-log nc) (vector-ref nc 2))

  ;; predefined tables from the spec's normalized distributions
  (define $ll-dist
    '#(4 3 2 2 2 2 2 2 2 2 2 2 2 1 1 1
       2 2 2 2 2 2 2 2 2 3 2 1 1 1 1 1
       -1 -1 -1 -1))
  (define $of-dist
    '#(1 1 1 1 1 1 2 2 2 1 1 1 1 1 1 1
       1 1 1 1 1 1 1 1 -1 -1 -1 -1 -1))
  (define $ml-dist
    '#(1 4 3 2 2 2 2 2 2 1 1 1 1 1 1 1
       1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1
       1 1 1 1 1 1 1 1 1 1 1 1 1 1 -1 -1
       -1 -1 -1 -1 -1))
  (define ($dist->counts d)
    (let* ((n (vector-length d)) (c (make-vector n 0)))
      (let loop ((i 0)) (when (< i n) (vector-set! c i (vector-ref d i)) (loop (+ i 1))))
      c))
  (define ($predef d log) ($fse-build ($dist->counts d) (vector-length d) log))

  (define $ll-base
    '#(0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15
       16 18 20 22 24 28 32 40 48 64 128 256 512 1024 2048 4096
       8192 16384 32768 65536))
  (define $ll-bits
    '#(0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
       1 1 1 1 2 2 3 3 4 6 7 8 9 10 11 12
       13 14 15 16))
  (define $ml-base
    '#(3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18
       19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34
       35 37 39 41 43 47 51 59 67 83 99 131 259 515 1027 2051
       4099 8195 16387 32771 65539))
  (define $ml-bits
    '#(0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
       0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
       1 1 1 1 2 2 3 3 4 4 5 7 8 9 10 11
       12 13 14 15 16))

  ;; =================== Huffman literals ===================
  ;; #(maxbits symv nbv), indexed by a running state whose high bits
  ;; carry the current code.
  (define ($huf-init bits nsym)
    (let ((mx 0))
      (let m ((i 0))
        (when (< i nsym)
          (when (> (vector-ref bits i) mx) (set! mx (vector-ref bits i)))
          (m (+ i 1))))
      (let ((rc (make-vector (+ mx 1) 0)))
        (let c ((i 0))
          (when (< i nsym)
            (let ((l (vector-ref bits i)))
              (vector-set! rc l (+ 1 (vector-ref rc l))))
            (c (+ i 1))))
        (let* ((size ($shl 1 mx))
               (syms (make-vector size 0))
               (nbt (make-vector size 0))
               (ri (make-vector (+ mx 1) 0)))
          (let r ((i mx))
            (when (>= i 1)
              (vector-set! ri (- i 1)
                           (+ (vector-ref ri i)
                              (* (vector-ref rc i) ($shl 1 (- mx i)))))
              (let f ((j (vector-ref ri i)))
                (when (< j (vector-ref ri (- i 1)))
                  (vector-set! nbt j i) (f (+ j 1))))
              (r (- i 1))))
          (let a ((i 0))
            (when (< i nsym)
              (let ((l (vector-ref bits i)))
                (unless (= l 0)
                  (let ((code (vector-ref ri l)) (ln ($shl 1 (- mx l))))
                    (let f ((j code))
                      (when (< j (+ code ln)) (vector-set! syms j i) (f (+ j 1))))
                    (vector-set! ri l (+ code ln)))))
              (a (+ i 1))))
          (vector mx syms nbt)))))

  ;; weights (0..) -> code lengths, then a canonical table.  The last
  ;; symbol's weight is implicit: it completes a power of two.
  (define ($huf-from-weights weights nsym)
    (let ((ws 0))
      (let s ((i 0))
        (when (< i nsym)
          (let ((w (vector-ref weights i)))
            (when (> w 0) (set! ws (+ ws ($shl 1 (- w 1))))))
          (s (+ i 1))))
      (let* ((mx (+ 1 ($hb ws)))
             (left (- ($shl 1 mx) ws))
             (lastw (+ 1 ($hb left)))
             (n (+ nsym 1))
             (bits (make-vector n 0)))
        (vector-set! weights nsym lastw)
        (let b ((i 0))
          (when (< i n)
            (let ((w (vector-ref weights i)))
              (vector-set! bits i (if (> w 0) (- (+ mx 1) w) 0)))
            (b (+ i 1))))
        ($huf-init bits n))))

  ;; decode the huffman weight description at `at' -> #(table headerBytes)
  (define ($huf-read-weights at)
    (let ((hb ($u8 at)))
      (if (>= hb 128)
          (let* ((nsym (- hb 127)) (weights (make-vector 256 0)))
            (let loop ((i 0))
              (when (< i nsym)
                (let ((byte ($u8 (+ at 1 (quotient i 2)))))
                  (vector-set! weights i
                               (if (= 0 (bitwise-and i 1)) ($shr byte 4) (bitwise-and byte 15))))
                (loop (+ i 1))))
            (vector ($huf-from-weights weights nsym) (+ 1 (quotient (+ nsym 1) 2))))
          (let* ((r ($fbr (+ at 1)))
                 (nc ($fse-decode-header r))
                 (dt ($fse-build ($nc-counts nc) ($nc-nsym nc) ($nc-log nc)))
                 (hdr ($fbr-bytes r))
                 (bstart (+ at 1 hdr))
                 (blen (- hb hdr))
                 (weights (make-vector 256 0))
                 (br ($bbr bstart blen))
                 (log ($nc-log nc)))
            (let ((s1 ($bbr-read br log)) (s2 ($bbr-read br log)))
              (let loop ((s1 s1) (s2 s2) (i 0))
                (vector-set! weights i ($fse-peek dt s1))
                (let ((s1u ($fse-update dt s1 br)))
                  (if (< ($bbr-off br) 0)
                      (begin (vector-set! weights (+ i 1) ($fse-peek dt s2))
                             (vector ($huf-from-weights weights (+ i 2)) (+ 1 hb)))
                      (begin
                        (vector-set! weights (+ i 1) ($fse-peek dt s2))
                        (let ((s2u ($fse-update dt s2 br)))
                          (if (< ($bbr-off br) 0)
                              (begin (vector-set! weights (+ i 2) ($fse-peek dt s1u))
                                     (vector ($huf-from-weights weights (+ i 3)) (+ 1 hb)))
                              (loop s1u s2u (+ i 2)))))))))))))

  ;; decode a huffman stream (backward reader) into base[off..off+count)
  (define ($huf-decode-stream tbl br base off count)
    (let* ((mx (vector-ref tbl 0)) (syms (vector-ref tbl 1)) (nbt (vector-ref tbl 2))
           (mask (- ($shl 1 mx) 1)))
      (let loop ((i 0) (st ($bbr-read br mx)))
        (when (< i count)
          (let ((sy (vector-ref syms st)) (b (vector-ref nbt st)))
            ($u8! (+ base off i) sy)
            (loop (+ i 1) (bitwise-and (+ ($shl st b) ($bbr-read br b)) mask)))))))

  ;; =================== literals section ===================
  ;; decode literals at `at' into `litbuf'; `prev-huf' is the frame's
  ;; last Huffman table (a Treeless block, type 3, reuses it instead
  ;; of carrying its own description) -> #(litbuf litLen nextAt huf)
  (define ($literals at litbuf prev-huf)
    (let* ((b0 ($u8 at)) (type (bitwise-and b0 3)) (sizefmt (bitwise-and ($shr b0 2) 3)))
      (cond
       ((or (= type 0) (= type 1))
        (let-values (((rsize hdr)
                      (cond
                       ((= 0 (bitwise-and sizefmt 1)) (values ($shr b0 3) 1))
                       ((= sizefmt 1) (values (+ ($shr b0 4) (* 16 ($u8 (+ at 1)))) 2))
                       (else (values (+ ($shr b0 4) (* 16 ($u16 (+ at 1)))) 3)))))
          (if (= type 0)
              (begin
                (let cp ((i 0)) (when (< i rsize) ($u8! (+ litbuf i) ($u8 (+ at hdr i))) (cp (+ i 1))))
                (vector litbuf rsize (+ at hdr rsize) prev-huf))
              (let ((v ($u8 (+ at hdr))))
                (let cp ((i 0)) (when (< i rsize) ($u8! (+ litbuf i) v) (cp (+ i 1))))
                (vector litbuf rsize (+ at hdr 1) prev-huf)))))
       (else
        ;; header fields assembled from bytes -- a $u32 is a bignum
        ;; past 2^30 and bitwise ops on bignums trap
        (let*-values
            (((regen comp hdr streams4?)
              (let ((b0 ($u8 at)) (b1 ($u8 (+ at 1))) (b2 ($u8 (+ at 2))))
                (cond
                 ((= sizefmt 0) (let ((x ($u24 at))) (values (bitwise-and ($shr x 4) 1023) (bitwise-and ($shr x 14) 1023) 3 #f)))
                 ((= sizefmt 1) (let ((x ($u24 at))) (values (bitwise-and ($shr x 4) 1023) (bitwise-and ($shr x 14) 1023) 3 #t)))
                 ((= sizefmt 2)
                  (let ((b3 ($u8 (+ at 3))))
                    (values (+ ($shr b0 4) ($shl b1 4) ($shl (bitwise-and b2 3) 12))
                            (+ ($shr b2 2) ($shl b3 6))
                            4 #t)))
                 (else
                  (let ((b3 ($u8 (+ at 3))) (b4 ($u8 (+ at 4))))
                    (values (+ ($shr b0 4) ($shl b1 4) ($shl (bitwise-and b2 63) 12))
                            (+ ($shr b2 6) ($shl b3 2) ($shl b4 10))
                            5 #t)))))))
          (let* ((tstart (+ at hdr))
                 ;; type 3 (Treeless): no table description, reuse the
                 ;; frame's previous one
                 (tw (if (= type 3)
                         (begin
                           (unless prev-huf
                             (error 'zstd "treeless literals with no prior table"))
                           (vector prev-huf 0))
                         ($huf-read-weights tstart)))
                 (tbl (vector-ref tw 0))
                 (tbytes (vector-ref tw 1))
                 (pstart (+ tstart tbytes))
                 (plen (- comp tbytes)))
            (if (not streams4?)
                (begin
                  ($huf-decode-stream tbl ($bbr pstart plen) litbuf 0 regen)
                  (vector litbuf regen (+ at hdr comp) tbl))
                (let* ((j1 ($u16 pstart)) (j2 ($u16 (+ pstart 2))) (j3 ($u16 (+ pstart 4)))
                       (p0 (+ pstart 6)) (total (- plen 6))
                       (j4 (- total (+ j1 j2 j3)))
                       (seg (quotient (+ regen 3) 4))
                       (last (- regen (* 3 seg))))
                  ($huf-decode-stream tbl ($bbr p0 j1) litbuf 0 seg)
                  ($huf-decode-stream tbl ($bbr (+ p0 j1) j2) litbuf seg seg)
                  ($huf-decode-stream tbl ($bbr (+ p0 j1 j2) j3) litbuf (* 2 seg) seg)
                  ($huf-decode-stream tbl ($bbr (+ p0 j1 j2 j3) j4) litbuf (* 3 seg) last)
                  (vector litbuf regen (+ at hdr comp) tbl)))))))))

  ;; =================== sequences ===================
  ;; `prev' is the frame's previous decode table for this stream --
  ;; mode 3 (Repeat) reuses it across blocks
  (define ($seq-table mode dist deflog at prev)
    (cond
     ((= mode 0) (values ($predef dist deflog) at))
     ((= mode 1) (values (vector 0 (vector ($u8 at)) (vector 0) (vector 0)) (+ at 1)))
     ((= mode 2)
      (let* ((r ($fbr at))
             (nc ($fse-decode-header r))
             (dt ($fse-build ($nc-counts nc) ($nc-nsym nc) ($nc-log nc))))
        (values dt (+ at ($fbr-bytes r)))))
     (else
      (unless prev (error 'zstd "repeat FSE mode with no prior table"))
      (values prev at))))

  ;; pll/pof/pml are the frame's previous FSE tables (Repeat mode);
  ;; ir0..ir2 the offset history, which persists across blocks.
  ;; returns #(dpos' llt oft mlt r0 r1 r2)
  (define ($sequences at endat litbuf litlen dpos pll pof pml ir0 ir1 ir2)
    (let ((b0 ($u8 at)))
      (if (= b0 0)
          (begin
            (let cp ((i 0)) (when (< i litlen) ($u8! (+ dpos i) ($u8 (+ litbuf i))) (cp (+ i 1))))
            (vector (+ dpos litlen) pll pof pml ir0 ir1 ir2))
          (let-values
              (((nseq nat)
                (cond ((< b0 128) (values b0 (+ at 1)))
                      ((< b0 255) (values (+ (* (- b0 128) 256) ($u8 (+ at 1))) (+ at 2)))
                      (else (values (+ 32512 ($u16 (+ at 1))) (+ at 3))))))
            (let* ((modes ($u8 nat))
                   (llmode ($shr modes 6))
                   (ofmode (bitwise-and ($shr modes 4) 3))
                   (mlmode (bitwise-and ($shr modes 2) 3))
                   (tat (+ nat 1)))
              (let*-values (((llt tat) ($seq-table llmode $ll-dist 6 tat pll))
                            ((oft tat) ($seq-table ofmode $of-dist 5 tat pof))
                            ((mlt tat) ($seq-table mlmode $ml-dist 6 tat pml)))
                (let* ((br ($bbr tat (- endat tat)))
                       (lls ($bbr-read br (vector-ref llt 0)))
                       (ofs ($bbr-read br (vector-ref oft 0)))
                       (mls ($bbr-read br (vector-ref mlt 0))))
                  (let loop ((n 0) (lls lls) (ofs ofs) (mls mls)
                             (dpos dpos) (litpos 0)
                             (r0 ir0) (r1 ir1) (r2 ir2))
                    (if (= n nseq)
                        (let ((rem (- litlen litpos)))
                          (let cp ((i 0)) (when (< i rem) ($u8! (+ dpos i) ($u8 (+ litbuf litpos i))) (cp (+ i 1))))
                          (vector (+ dpos rem) llt oft mlt r0 r1 r2))
                        (let* ((llc ($fse-peek llt lls))
                               (mlc ($fse-peek mlt mls))
                               (ofc ($fse-peek oft ofs))
                               (offv (+ ($shl 1 ofc) ($bbr-read br ofc)))
                               (mlen (+ (vector-ref $ml-base mlc) ($bbr-read br (vector-ref $ml-bits mlc))))
                               (llen (+ (vector-ref $ll-base llc) ($bbr-read br (vector-ref $ll-bits llc)))))
                          (let-values
                              (((offset nr0 nr1 nr2)
                                (if (> offv 3)
                                    (values (- offv 3) (- offv 3) r0 r1)
                                    (if (not (= llen 0))
                                        (cond ((= offv 1) (values r0 r0 r1 r2))
                                              ((= offv 2) (values r1 r1 r0 r2))
                                              (else (values r2 r2 r0 r1)))
                                        (cond ((= offv 1) (values r1 r1 r0 r2))
                                              ((= offv 2) (values r2 r2 r0 r1))
                                              (else (values (- r0 1) (- r0 1) r0 r1)))))))
                            (let cp ((i 0)) (when (< i llen) ($u8! (+ dpos i) ($u8 (+ litbuf litpos i))) (cp (+ i 1))))
                            (let ((ms (- (+ dpos llen) offset)))
                              (let cp ((i 0)) (when (< i mlen) ($u8! (+ dpos llen i) ($u8 (+ ms i))) (cp (+ i 1))))
                              (let ((dpos (+ dpos llen mlen)) (litpos (+ litpos llen)))
                                (if (= (+ n 1) nseq)
                                    (loop (+ n 1) lls ofs mls dpos litpos nr0 nr1 nr2)
                                    (let* ((lls ($fse-update llt lls br))
                                           (mls ($fse-update mlt mls br))
                                           (ofs ($fse-update oft ofs br)))
                                      (loop (+ n 1) lls ofs mls dpos litpos nr0 nr1 nr2))))))))))))))))

  ;; =================== frame / blocks ===================
  (define ($frame-content-at src)
    (unless (= #xFD2FB528 ($u32 src)) (error 'zstd "not a zstd frame"))
    (let* ((fhd ($u8 (+ src 4)))
           (dictflag (bitwise-and fhd 3))
           (cs-flag ($shr fhd 6))
           (single? (not (= 0 (bitwise-and fhd 32))))
           (p (+ src 5))
           (p (if single? p (+ p 1)))
           (p (+ p (cond ((= dictflag 0) 0) ((= dictflag 1) 1) ((= dictflag 2) 2) (else 4))))
           (p (+ p (cond ((= cs-flag 0) (if single? 1 0)) ((= cs-flag 1) 2) ((= cs-flag 2) 4) (else 8)))))
      p))

  (define (zstd-frame-size src)
    (let* ((fhd ($u8 (+ src 4)))
           (cs-flag ($shr fhd 6))
           (dictflag (bitwise-and fhd 3))
           (single? (not (= 0 (bitwise-and fhd 32))))
           (p (+ src 5))
           (p (if single? p (+ p 1)))
           (p (+ p (cond ((= dictflag 0) 0) ((= dictflag 1) 1) ((= dictflag 2) 2) (else 4)))))
      (cond ((= cs-flag 0) (if single? ($u8 p) 0))
            ((= cs-flag 1) (+ 256 ($u16 p)))
            ((= cs-flag 2) ($u32 p))
            (else ($u32 p)))))

  (define (zstd-decode! src slen dst scratch)
    ;; the entropy state -- the last Huffman table and the three FSE
    ;; tables -- and the offset history persist across a frame's blocks
    (let ((cat ($frame-content-at src)))
      (let loop ((at cat) (dpos dst)
                 (huf #f) (llt #f) (oft #f) (mlt #f)
                 (r0 1) (r1 4) (r2 8))
        (let* ((hd ($u24 at))
               (lastblk (bitwise-and hd 1))
               (btype (bitwise-and ($shr hd 1) 3))
               (bsize ($shr hd 3))
               (bat (+ at 3)))
          (cond
           ((= btype 0)
            (let cp ((i 0)) (when (< i bsize) ($u8! (+ dpos i) ($u8 (+ bat i))) (cp (+ i 1))))
            (if (= lastblk 1) (- (+ dpos bsize) dst)
                (loop (+ bat bsize) (+ dpos bsize) huf llt oft mlt r0 r1 r2)))
           ((= btype 1)
            (let ((v ($u8 bat)))
              (let cp ((i 0)) (when (< i bsize) ($u8! (+ dpos i) v) (cp (+ i 1))))
              (if (= lastblk 1) (- (+ dpos bsize) dst)
                  (loop (+ bat 1) (+ dpos bsize) huf llt oft mlt r0 r1 r2))))
           ((= btype 2)
            (let* ((lit ($literals bat scratch huf))
                   (litbuf (vector-ref lit 0))
                   (litlen (vector-ref lit 1))
                   (seqat (vector-ref lit 2))
                   (nhuf (vector-ref lit 3))
                   (sq ($sequences seqat (+ bat bsize) litbuf litlen dpos
                                   llt oft mlt r0 r1 r2))
                   (ndpos (vector-ref sq 0)))
              (if (= lastblk 1) (- ndpos dst)
                  (loop (+ bat bsize) ndpos nhuf
                        (vector-ref sq 1) (vector-ref sq 2) (vector-ref sq 3)
                        (vector-ref sq 4) (vector-ref sq 5) (vector-ref sq 6)))))
           (else (error 'zstd "reserved block type"))))))))
