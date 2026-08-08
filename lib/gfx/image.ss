;; PNG and TGA in pure Scheme -- the ground floor of image IO for the
;; graphics pipeline.  No host codec, no createImageBitmap: the bytes
;; are decoded here, so the same file yields the same pixels on every
;; backend (wasm, the JS target, the Chez host) and in a worker with
;; no DOM at all.
;;
;;   (png-info    src slen)            ; -> width height channels
;;   (png-decode! src slen dst)        ; -> width height; RGBA8 at dst
;;   (png-encode! pix w h ch dst)      ; -> bytes written at dst
;;   (png-encode-size w h ch)          ; -> that count, ahead of time
;;   (tga-info    src slen)            ; -> width height bpp image-type
;;   (tga-decode! src slen dst)        ; -> width height; RGBA8 at dst
;;   (inflate!      src slen dst dlen) ; raw DEFLATE  (RFC 1951)
;;   (zlib-inflate! src slen dst dlen) ; zlib wrapper (RFC 1950)
;;   (crc32   src slen)                ; -> hi lo   (two 16-bit halves)
;;   (adler32 src slen)                ; -> hi lo
;;
;; `src' is a source in one of two shapes and every entry point takes
;; both: an integer staging-memory base, or a bytevector (whose byte i
;; is at position i, so `slen' may be #f for "all of it").  Output
;; always lands in staging memory -- a decoded image is meant to be
;; uploaded, and back-references during inflate must be able to read
;; what was already written.
;;
;; Decoded output is always RGBA8, whatever the source said: one
;; output shape for a wide set of inputs.  A caller sizing a buffer
;; needs w*h*4 bytes and nothing else.
;;
;; Sizes and offsets are counted with `+' and `*'; only genuinely
;; bit-shaped quantities reach bitwise operators, and never above
;; 2^29 -- see the CRC32 note below and docs/limits.md.
;;
;; What this does NOT do, by name and on purpose:
;;
;;   * Adam7 interlacing is refused ("interlaced PNG is not
;;     supported"), not silently mis-decoded.
;;   * 16-bit samples are refused ("16-bit PNG samples are not
;;     supported"); so are sub-byte (1/2/4-bit) samples.
;;   * png-encode! writes stored (uncompressed) DEFLATE blocks.  The
;;     file is a fully conforming PNG that any decoder reads, it is
;;     just larger than one a compressing encoder would write.  Doing
;;     the correct thing first is deliberate: Huffman coding on the
;;     way out is an addition here, not a rewrite.
;;
;; Copyright (c) 2026 guenchi. MIT license; see LICENSE.
(library (gfx image)
  (export png-info png-decode! png-encode! png-encode-size
          tga-info tga-decode!
          inflate! zlib-inflate! crc32 adler32)
  (import (rnrs))

  (define ($shl a n) (bitwise-arithmetic-shift-left a n))
  (define ($shr a n) (bitwise-arithmetic-shift-right a n))

  ;; ---- the source -------------------------------------------------
  ;; One reader serves both shapes.  Positions are absolute: a staging
  ;; address, or an index into the bytevector.
  (define $src-bv #f)                   ; bytevector | #f (staging)
  (define $src-start 0)
  (define $src-end 0)

  (define ($src-init! src slen)
    (if (bytevector? src)
        (begin (set! $src-bv src)
               (set! $src-start 0)
               (set! $src-end (if slen slen (bytevector-length src))))
        (begin (set! $src-bv #f)
               (set! $src-start src)
               (set! $src-end (+ src slen)))))

  (define ($u8 at)
    (when (or (< at $src-start) (>= at $src-end))
      (error 'image "truncated input"))
    (if $src-bv (bytevector-u8-ref $src-bv at) (%mem-u8-ref at)))

  (define ($u16be at) (+ (* 256 ($u8 at)) ($u8 (+ at 1))))
  ;; a PNG chunk length is 31 bits wide; built by arithmetic so the
  ;; value never has to survive a bitwise operator
  (define ($u32be at)
    (+ (* 16777216 ($u8 at)) (* 65536 ($u8 (+ at 1)))
       (* 256 ($u8 (+ at 2))) ($u8 (+ at 3))))
  (define ($u16le at) (+ ($u8 at) (* 256 ($u8 (+ at 1)))))

  ;; ---- CRC32 (IEEE, as PNG chunks carry it) -----------------------
  ;; The register is 32 bits and bitwise operators here trap at 2^29,
  ;; so it is carried as two 16-bit halves and so is the table.  Every
  ;; operand below is strictly under 2^16.
  (define $crc-hi (make-vector 256 0))
  (define $crc-lo (make-vector 256 0))
  (define ($crc-build!)
    ;; the reversed polynomial 0xEDB88320 = 60856 * 65536 + 33568
    (let sym ((n 0))
      (when (< n 256)
        (let step ((k 0) (hi 0) (lo n))
          (if (= k 8)
              (begin (vector-set! $crc-hi n hi) (vector-set! $crc-lo n lo))
              (let ((nhi (quotient hi 2))
                    (nlo (+ (quotient lo 2) (* 32768 (remainder hi 2)))))
                (if (= 1 (remainder lo 2))
                    (step (+ k 1) (bitwise-xor nhi 60856) (bitwise-xor nlo 33568))
                    (step (+ k 1) nhi nlo)))))
        (sym (+ n 1)))))
  ($crc-build!)

  ;; CRC of the source range [at, at+len), as (values hi lo)
  (define ($crc at len)
    (let loop ((i 0) (hi 65535) (lo 65535))
      (if (= i len)
          (values (bitwise-xor hi 65535) (bitwise-xor lo 65535))
          (let* ((idx (bitwise-xor (bitwise-and lo 255) ($u8 (+ at i))))
                 (shi (quotient hi 256))
                 (slo (+ (quotient lo 256) (* 256 (remainder hi 256)))))
            (loop (+ i 1)
                  (bitwise-xor shi (vector-ref $crc-hi idx))
                  (bitwise-xor slo (vector-ref $crc-lo idx)))))))

  (define (crc32 src slen)
    ($src-init! src slen)
    ($crc $src-start (- $src-end $src-start)))

  ;; ---- Adler32 (the zlib trailer) ---------------------------------
  ;; s1 and s2 stay under 65521 by construction, so this one needs no
  ;; splitting -- and no bitwise operator at all.
  (define ($adler at len)
    (let loop ((i 0) (s1 1) (s2 0))
      (if (= i len)
          (values s2 s1)
          (let ((s1 (remainder (+ s1 ($u8 (+ at i))) 65521)))
            (loop (+ i 1) s1 (remainder (+ s2 s1) 65521))))))

  (define (adler32 src slen)
    ($src-init! src slen)
    ($adler $src-start (- $src-end $src-start)))

  ;; the same checksum over freshly inflated bytes, which live in
  ;; staging memory whatever shape the source had.  Aiming the source
  ;; at them and putting it back keeps one implementation of Adler32
  ;; rather than two that could drift.
  (define ($adler-of-output at len)
    (let ((bv $src-bv) (s0 $src-start) (s1 $src-end))
      (set! $src-bv #f) (set! $src-start at) (set! $src-end (+ at len))
      (let-values (((hi lo) ($adler at len)))
        (set! $src-bv bv) (set! $src-start s0) (set! $src-end s1)
        (values hi lo))))

  ;; ---- the inflate input stream -----------------------------------
  ;; A DEFLATE stream is read strictly forward, which lets the reader
  ;; span a list of disjoint source ranges -- exactly what a PNG's
  ;; several IDAT chunks are.  Segments are a flat vector of
  ;; start/end pairs.
  (define $segs (vector 0 0))
  (define $segn 1)
  (define $segi 0)
  (define $at 0)
  (define $atend 0)
  (define $phantom 0)
  (define $bbuf 0)
  (define $bcnt 0)

  (define ($stream-init! segs)
    (set! $segs segs)
    (set! $segn (quotient (vector-length segs) 2))
    (set! $segi 0)
    (set! $at (vector-ref segs 0))
    (set! $atend (vector-ref segs 1))
    (set! $phantom 0)
    (set! $bbuf 0)
    (set! $bcnt 0))

  ;; Past the last segment this yields zeros for a short while: a
  ;; decoder legitimately holds a few bits of lookahead at the end of
  ;; the final block.  Past that lookahead the stream really is short,
  ;; and saying so here beats reporting it as a bad Huffman code.
  (define ($next-byte)
    (let advance ()
      (if (< $at $atend)
          (let ((v ($u8 $at))) (set! $at (+ $at 1)) v)
          (if (< (+ $segi 1) $segn)
              (begin (set! $segi (+ $segi 1))
                     (set! $at (vector-ref $segs (* 2 $segi)))
                     (set! $atend (vector-ref $segs (+ (* 2 $segi) 1)))
                     (advance))
              (begin (set! $phantom (+ $phantom 1))
                     (when (> $phantom 4)
                       (error 'image "truncated deflate stream"))
                     0)))))

  (define ($bit)
    (when (= $bcnt 0)
      (set! $bbuf ($next-byte))
      (set! $bcnt 8))
    (let ((b (bitwise-and $bbuf 1)))
      (set! $bbuf ($shr $bbuf 1))
      (set! $bcnt (- $bcnt 1))
      b))

  ;; n bits, LSB-first; n <= 16 here, so the accumulator stays small
  (define ($bits n)
    (let loop ((i 0) (v 0) (m 1))
      (if (= i n) v (loop (+ i 1) (+ v (* m ($bit))) (* m 2)))))

  (define ($align!) (set! $bcnt 0) (set! $bbuf 0))

  ;; ---- the inflate output -----------------------------------------
  (define $dst-start 0)
  (define $dst-end 0)
  (define $dpos 0)

  (define ($out! v)
    (when (>= $dpos $dst-end)
      (error 'image "inflate output exceeds destination"))
    (%mem-u8-set! $dpos v)
    (set! $dpos (+ $dpos 1)))

  ;; ---- canonical Huffman ------------------------------------------
  ;; counts[len] and the symbols in canonical order; decoding walks
  ;; one bit at a time, which needs no table proportional to 2^15 and
  ;; keeps every intermediate under 2^15.
  (define $maxbits 15)

  (define ($construct lens from n)
    (let ((counts (make-vector (+ $maxbits 1) 0))
          (symbols (make-vector (if (= n 0) 1 n) 0)))
      (let c ((i 0))
        (when (< i n)
          (let ((l (vector-ref lens (+ from i))))
            (when (> l $maxbits) (error 'image "code length out of range"))
            (vector-set! counts l (+ 1 (vector-ref counts l))))
          (c (+ i 1))))
      ;; over-subscribed sets decode nothing sensible; refuse them here
      (let k ((len 1) (left 1))
        (when (<= len $maxbits)
          (let ((left (- (* 2 left) (vector-ref counts len))))
            (when (< left 0) (error 'image "over-subscribed huffman code"))
            (k (+ len 1) left))))
      (let ((offs (make-vector (+ $maxbits 2) 0)))
        (let o ((len 1))
          (when (<= len $maxbits)
            (vector-set! offs (+ len 1)
                         (+ (vector-ref offs len) (vector-ref counts len)))
            (o (+ len 1))))
        (let s ((i 0))
          (when (< i n)
            (let ((l (vector-ref lens (+ from i))))
              (unless (= l 0)
                (vector-set! symbols (vector-ref offs l) i)
                (vector-set! offs l (+ 1 (vector-ref offs l)))))
            (s (+ i 1)))))
      (vector counts symbols)))

  (define ($decode h)
    (let ((counts (vector-ref h 0)) (symbols (vector-ref h 1)))
      (let loop ((len 1) (code 0) (first 0) (index 0))
        (if (> len $maxbits)
            (error 'image "invalid huffman code")
            (let* ((code (+ (* 2 code) ($bit)))
                   (count (vector-ref counts len)))
              ;; `code' is shifted by the (* 2 code) at the head of the
              ;; next iteration, not here -- doing both is one shift
              ;; too many and decodes garbage
              (if (< (- code first) count)
                  (vector-ref symbols (+ index (- code first)))
                  (loop (+ len 1) code
                        (* 2 (+ first count)) (+ index count))))))))

  ;; ---- DEFLATE ----------------------------------------------------
  (define $len-base
    '#(3 4 5 6 7 8 9 10 11 13 15 17 19 23 27 31 35 43 51 59
       67 83 99 115 131 163 195 227 258))
  (define $len-extra
    '#(0 0 0 0 0 0 0 0 1 1 1 1 2 2 2 2 3 3 3 3
       4 4 4 4 5 5 5 5 0))
  (define $dist-base
    '#(1 2 3 4 5 7 9 13 17 25 33 49 65 97 129 193 257 385 513 769
       1025 1537 2049 3073 4097 6145 8193 12289 16385 24577))
  (define $dist-extra
    '#(0 0 0 0 1 1 2 2 3 3 4 4 5 5 6 6 7 7 8 8
       9 9 10 10 11 11 12 12 13 13))
  (define $cl-order
    '#(16 17 18 0 8 7 9 6 10 5 11 4 12 3 13 2 14 1 15))

  (define ($fixed-lit)
    (let ((lens (make-vector 288 0)))
      (let l ((i 0))
        (when (< i 288)
          (vector-set! lens i
                       (cond ((< i 144) 8) ((< i 256) 9) ((< i 280) 7) (else 8)))
          (l (+ i 1))))
      ($construct lens 0 288)))
  (define ($fixed-dist)
    (let ((lens (make-vector 30 0)))
      (let l ((i 0)) (when (< i 30) (vector-set! lens i 5) (l (+ i 1))))
      ($construct lens 0 30)))
  (define $fixed-lit-h ($fixed-lit))
  (define $fixed-dist-h ($fixed-dist))

  (define ($stored!)
    ($align!)
    ;; the four header bytes are sequenced by hand: argument order
    ;; inside a `+' is not something to bet a byte stream on
    (let* ((l0 ($next-byte)) (l1 ($next-byte))
           (n0 ($next-byte)) (n1 ($next-byte))
           (len (+ l0 (* 256 l1)))
           (nlen (+ n0 (* 256 n1))))
      (unless (= (+ len nlen) 65535)
        (error 'image "stored block length mismatch"))
      (let cp ((i 0))
        (when (< i len) ($out! ($next-byte)) (cp (+ i 1))))))

  (define ($codes! lit dist)
    (let loop ()
      (let ((sym ($decode lit)))
        (cond
         ((< sym 256) ($out! sym) (loop))
         ((= sym 256) #t)
         (else
          (let ((i (- sym 257)))
            (when (>= i 29) (error 'image "invalid length code"))
            (let* ((len (+ (vector-ref $len-base i)
                           ($bits (vector-ref $len-extra i))))
                   (dsym ($decode dist)))
              (when (>= dsym 30) (error 'image "invalid distance code"))
              (let ((d (+ (vector-ref $dist-base dsym)
                          ($bits (vector-ref $dist-extra dsym)))))
                (when (> d (- $dpos $dst-start))
                  (error 'image "back-reference precedes output"))
                ;; read through $dpos as it advances: an overlapping
                ;; copy (run-length) is the intended behaviour
                (let cp ((k 0))
                  (when (< k len)
                    ($out! (%mem-u8-ref (- $dpos d)))
                    (cp (+ k 1))))
                (loop)))))))))

  (define ($dynamic!)
    (let* ((hlit (+ 257 ($bits 5)))
           (hdist (+ 1 ($bits 5)))
           (hclen (+ 4 ($bits 4)))
           (total (+ hlit hdist))
           (clens (make-vector 19 0)))
      (let l ((i 0))
        (when (< i hclen)
          (vector-set! clens (vector-ref $cl-order i) ($bits 3))
          (l (+ i 1))))
      (let ((clh ($construct clens 0 19))
            (lens (make-vector total 0)))
        (let loop ((i 0))
          (when (< i total)
            (let ((sym ($decode clh)))
              (cond
               ((< sym 16) (vector-set! lens i sym) (loop (+ i 1)))
               (else
                (let-values
                    (((v n)
                      (cond
                       ((= sym 16)
                        (when (= i 0)
                          (error 'image "code length repeat with no predecessor"))
                        (values (vector-ref lens (- i 1)) (+ 3 ($bits 2))))
                       ((= sym 17) (values 0 (+ 3 ($bits 3))))
                       (else (values 0 (+ 11 ($bits 7)))))))
                  (when (> (+ i n) total)
                    (error 'image "code length run overflows"))
                  (let r ((k 0) (i i))
                    (if (= k n)
                        (loop i)
                        (begin (vector-set! lens i v)
                               (r (+ k 1) (+ i 1))))))))))
          )
        ($codes! ($construct lens 0 hlit) ($construct lens hlit hdist)))))

  (define ($inflate-blocks!)
    (let loop ()
      (let* ((final ($bit)) (btype ($bits 2)))
        (cond ((= btype 0) ($stored!))
              ((= btype 1) ($codes! $fixed-lit-h $fixed-dist-h))
              ((= btype 2) ($dynamic!))
              (else (error 'image "invalid deflate block type")))
        (if (= final 1) (- $dpos $dst-start) (loop)))))

  (define ($inflate-into! dst dlen)      ; the stream is already open
    (set! $dst-start dst)
    (set! $dst-end (+ dst dlen))
    (set! $dpos dst)
    ($inflate-blocks!))

  (define (inflate! src slen dst dlen)
    ($src-init! src slen)
    ($stream-init! (vector $src-start $src-end))
    ($inflate-into! dst dlen))

  ;; the four trailer bytes sit immediately after the final block,
  ;; byte-aligned; reading them through the segment reader is what
  ;; makes a multi-segment (multi-IDAT) stream come out right
  (define ($zlib-check-trailer! dst n)
    ($align!)
    (let* ((a3 ($next-byte)) (a2 ($next-byte))
           (a1 ($next-byte)) (a0 ($next-byte))
           (want-hi (+ (* 256 a3) a2))
           (want-lo (+ (* 256 a1) a0)))
      (let-values (((hi lo) ($adler-of-output dst n)))
        (unless (and (= hi want-hi) (= lo want-lo))
          (error 'image "zlib adler32 mismatch")))))

  (define ($zlib-head! cmf flg)
    (unless (= 8 (bitwise-and cmf 15))
      (error 'image "zlib stream is not deflate"))
    (unless (= 0 (remainder (+ (* 256 cmf) flg) 31))
      (error 'image "zlib header check failed"))
    (unless (= 0 (bitwise-and flg 32))
      (error 'image "zlib preset dictionary is not supported")))

  ;; Header, body and trailer all come through the one segment reader,
  ;; so a PNG is free to cut its zlib stream anywhere -- including
  ;; between the two header bytes, which a one-byte IDAT chunk does.
  (define ($zlib-inflate-segs! segs dst dlen)
    ($stream-init! segs)
    (let* ((cmf ($next-byte)) (flg ($next-byte)))
      ($zlib-head! cmf flg))
    (let ((n ($inflate-into! dst dlen)))
      ($zlib-check-trailer! dst n)
      n))

  (define (zlib-inflate! src slen dst dlen)
    ($src-init! src slen)
    ($zlib-inflate-segs! (vector $src-start $src-end) dst dlen))

  ;; ---- PNG --------------------------------------------------------
  (define ($png-sig? at)
    (and (= 137 ($u8 at)) (= 80 ($u8 (+ at 1))) (= 78 ($u8 (+ at 2)))
         (= 71 ($u8 (+ at 3))) (= 13 ($u8 (+ at 4))) (= 10 ($u8 (+ at 5)))
         (= 26 ($u8 (+ at 6))) (= 10 ($u8 (+ at 7)))))

  (define ($type= at a b c d)
    (and (= a ($u8 at)) (= b ($u8 (+ at 1)))
         (= c ($u8 (+ at 2))) (= d ($u8 (+ at 3)))))

  (define ($channels ct)
    (cond ((= ct 0) 1)                  ; grey
          ((= ct 2) 3)                  ; truecolour
          ((= ct 3) 1)                  ; palette index
          ((= ct 4) 2)                  ; grey + alpha
          ((= ct 6) 4)                  ; truecolour + alpha
          (else (error 'image "unknown PNG colour type"))))

  ;; Walk the chunk list once and report what the file is made of:
  ;;   #(ihdr plte-at plte-n trns-at trns-n idat-ranges idat-count)
  ;; where ihdr is #(w h bit-depth colour-type compression filter
  ;; interlace) and idat-ranges is a list of (start . end) pairs in
  ;; file order.
  ;; Every chunk's CRC is verified on the way past, including the ones
  ;; this decoder has no use for -- a file that fails here is corrupt
  ;; whether or not the corruption is in a chunk we read.
  (define ($png-scan at)
    (unless ($png-sig? at) (error 'image "not a PNG file"))
    (let loop ((p (+ at 8)) (ihdr #f)
               (plte-at 0) (plte-n 0) (trns-at 0) (trns-n 0)
               (idats '()) (nidat 0))
      (if (>= p $src-end)
          (error 'image "PNG ended without IEND")
          (let* ((len ($u32be p))
                 (tp (+ p 4))
                 (data (+ p 8))
                 (crc-at (+ data len)))
            (when (> (+ crc-at 4) $src-end) (error 'image "truncated PNG chunk"))
            (let-values (((hi lo) ($crc tp (+ len 4))))
              (unless (and (= hi ($u16be crc-at)) (= lo ($u16be (+ crc-at 2))))
                (error 'image "bad PNG chunk CRC")))
            (let ((next (+ crc-at 4)))
              (cond
               (($type= tp 73 72 68 82)  ; IHDR
                (unless (= len 13) (error 'image "malformed IHDR"))
                (loop next (vector ($u32be data) ($u32be (+ data 4))
                                   ($u8 (+ data 8)) ($u8 (+ data 9))
                                   ($u8 (+ data 10)) ($u8 (+ data 11))
                                   ($u8 (+ data 12)))
                      plte-at plte-n trns-at trns-n idats nidat))
               (($type= tp 80 76 84 69)  ; PLTE
                (loop next ihdr data len trns-at trns-n idats nidat))
               (($type= tp 116 82 78 83) ; tRNS
                (loop next ihdr plte-at plte-n data len idats nidat))
               (($type= tp 73 68 65 84)  ; IDAT
                (loop next ihdr plte-at plte-n trns-at trns-n
                      (cons (cons data (+ data len)) idats) (+ nidat 1)))
               (($type= tp 73 69 78 68)  ; IEND
                (unless ihdr (error 'image "PNG has no IHDR"))
                (when (= nidat 0) (error 'image "PNG has no IDAT"))
                (vector ihdr plte-at plte-n trns-at trns-n
                        (reverse idats) nidat))
               (else
                (loop next ihdr plte-at plte-n trns-at trns-n idats nidat))))))))

  ;; the sizes and shapes this decoder handles, named rejections for
  ;; the rest
  (define ($png-accept ihdr)
    (let ((bd (vector-ref ihdr 2)) (ct (vector-ref ihdr 3))
          (il (vector-ref ihdr 6)))
      (unless (= 0 (vector-ref ihdr 4))
        (error 'image "unknown PNG compression method"))
      (unless (= 0 (vector-ref ihdr 5))
        (error 'image "unknown PNG filter method"))
      (unless (= il 0)
        (error 'image "interlaced PNG (Adam7) is not supported"))
      (when (= bd 16)
        (error 'image "16-bit PNG samples are not supported"))
      (unless (= bd 8)
        (error 'image "sub-byte PNG samples are not supported"))
      ($channels ct)))

  (define (png-info src slen)
    ($src-init! src slen)
    (let* ((s ($png-scan $src-start))
           (ihdr (vector-ref s 0))
           (ch ($png-accept ihdr)))
      (values (vector-ref ihdr 0) (vector-ref ihdr 1) ch)))

  ;; Paeth, exactly as the PNG specification states it: the tie-break
  ;; order a, b, c is part of the definition, not an accident.
  (define ($paeth a b c)
    (let* ((p (- (+ a b) c))
           (pa (abs (- p a))) (pb (abs (- p b))) (pc (abs (- p c))))
      (if (and (<= pa pb) (<= pa pc)) a (if (<= pb pc) b c))))

  ;; undo the per-scanline filters in place; `raw' holds h rows of
  ;; (1 + stride) bytes, the leading byte naming the filter
  (define ($defilter! raw h stride bpp)
    (let row ((y 0))
      (when (< y h)
        (let* ((p (+ raw (* y (+ stride 1))))
               (ft (%mem-u8-ref p))
               (cur (+ p 1))
               (prev (- cur (+ stride 1))))
          (cond
           ((= ft 0) #t)
           ((= ft 1)
            (let l ((i bpp))
              (when (< i stride)
                (%mem-u8-set! (+ cur i)
                              (bitwise-and (+ (%mem-u8-ref (+ cur i))
                                              (%mem-u8-ref (+ cur i (- bpp))))
                                           255))
                (l (+ i 1)))))
           ((= ft 2)
            (when (> y 0)
              (let l ((i 0))
                (when (< i stride)
                  (%mem-u8-set! (+ cur i)
                                (bitwise-and (+ (%mem-u8-ref (+ cur i))
                                                (%mem-u8-ref (+ prev i)))
                                             255))
                  (l (+ i 1))))))
           ((= ft 3)
            (let l ((i 0))
              (when (< i stride)
                (let ((a (if (>= i bpp) (%mem-u8-ref (+ cur i (- bpp))) 0))
                      (b (if (> y 0) (%mem-u8-ref (+ prev i)) 0)))
                  (%mem-u8-set! (+ cur i)
                                (bitwise-and (+ (%mem-u8-ref (+ cur i))
                                                (quotient (+ a b) 2))
                                             255)))
                (l (+ i 1)))))
           ((= ft 4)
            (let l ((i 0))
              (when (< i stride)
                (let ((a (if (>= i bpp) (%mem-u8-ref (+ cur i (- bpp))) 0))
                      (b (if (> y 0) (%mem-u8-ref (+ prev i)) 0))
                      (c (if (and (> y 0) (>= i bpp))
                             (%mem-u8-ref (+ prev i (- bpp))) 0)))
                  (%mem-u8-set! (+ cur i)
                                (bitwise-and (+ (%mem-u8-ref (+ cur i))
                                                ($paeth a b c))
                                             255)))
                (l (+ i 1)))))
           (else (error 'image "unknown PNG filter type")))
          (row (+ y 1))))))

  ;; ---- filtered samples -> RGBA8 ----------------------------------
  (define ($expand-grey! raw dst w h stride trns)
    (let row ((y 0))
      (when (< y h)
        (let ((s (+ raw (* y (+ stride 1)) 1)) (d (+ dst (* y w 4))))
          (let px ((x 0))
            (when (< x w)
              (let ((v (%mem-u8-ref (+ s x))))
                (%mem-u8-set! (+ d (* x 4)) v)
                (%mem-u8-set! (+ d (* x 4) 1) v)
                (%mem-u8-set! (+ d (* x 4) 2) v)
                (%mem-u8-set! (+ d (* x 4) 3) (if (= v trns) 0 255)))
              (px (+ x 1)))))
        (row (+ y 1)))))

  (define ($expand-grey-alpha! raw dst w h stride)
    (let row ((y 0))
      (when (< y h)
        (let ((s (+ raw (* y (+ stride 1)) 1)) (d (+ dst (* y w 4))))
          (let px ((x 0))
            (when (< x w)
              (let ((v (%mem-u8-ref (+ s (* x 2)))))
                (%mem-u8-set! (+ d (* x 4)) v)
                (%mem-u8-set! (+ d (* x 4) 1) v)
                (%mem-u8-set! (+ d (* x 4) 2) v)
                (%mem-u8-set! (+ d (* x 4) 3) (%mem-u8-ref (+ s (* x 2) 1))))
              (px (+ x 1)))))
        (row (+ y 1)))))

  (define ($expand-rgb! raw dst w h stride tr tg tb)
    (let row ((y 0))
      (when (< y h)
        (let ((s (+ raw (* y (+ stride 1)) 1)) (d (+ dst (* y w 4))))
          (let px ((x 0))
            (when (< x w)
              (let ((r (%mem-u8-ref (+ s (* x 3))))
                    (g (%mem-u8-ref (+ s (* x 3) 1)))
                    (b (%mem-u8-ref (+ s (* x 3) 2))))
                (%mem-u8-set! (+ d (* x 4)) r)
                (%mem-u8-set! (+ d (* x 4) 1) g)
                (%mem-u8-set! (+ d (* x 4) 2) b)
                (%mem-u8-set! (+ d (* x 4) 3)
                              (if (and (= r tr) (= g tg) (= b tb)) 0 255)))
              (px (+ x 1)))))
        (row (+ y 1)))))

  (define ($expand-rgba! raw dst w h stride)
    (let row ((y 0))
      (when (< y h)
        (let ((s (+ raw (* y (+ stride 1)) 1)) (d (+ dst (* y w 4))))
          (let px ((x 0))
            (when (< x (* w 4))
              (%mem-u8-set! (+ d x) (%mem-u8-ref (+ s x)))
              (px (+ x 1)))))
        (row (+ y 1)))))

  ;; palette entries and their alphas are copied into vectors first:
  ;; the source may be a bytevector, and the inner loop should not
  ;; have to ask which shape it is w*h times
  ;; an 8-bit index reaches 256 entries, and a longer PLTE or tRNS is
  ;; read only as far as that: the count is clamped, not trusted
  (define ($palette plte-at plte-n trns-at trns-n)
    (let* ((n (min 256 (quotient plte-n 3)))
           (trns-n (min 256 trns-n))
           (r (make-vector 256 0)) (g (make-vector 256 0))
           (b (make-vector 256 0)) (a (make-vector 256 255)))
      (when (= n 0) (error 'image "palette PNG with no PLTE"))
      (let l ((i 0))
        (when (< i n)
          (vector-set! r i ($u8 (+ plte-at (* i 3))))
          (vector-set! g i ($u8 (+ plte-at (* i 3) 1)))
          (vector-set! b i ($u8 (+ plte-at (* i 3) 2)))
          (l (+ i 1))))
      (let l ((i 0))
        (when (< i trns-n)
          (vector-set! a i ($u8 (+ trns-at i)))
          (l (+ i 1))))
      (vector r g b a n)))

  (define ($expand-palette! raw dst w h stride pal)
    (let ((pr (vector-ref pal 0)) (pg (vector-ref pal 1))
          (pb (vector-ref pal 2)) (pa (vector-ref pal 3))
          (n (vector-ref pal 4)))
      (let row ((y 0))
        (when (< y h)
          (let ((s (+ raw (* y (+ stride 1)) 1)) (d (+ dst (* y w 4))))
            (let px ((x 0))
              (when (< x w)
                (let ((i (%mem-u8-ref (+ s x))))
                  (when (>= i n) (error 'image "palette index out of range"))
                  (%mem-u8-set! (+ d (* x 4)) (vector-ref pr i))
                  (%mem-u8-set! (+ d (* x 4) 1) (vector-ref pg i))
                  (%mem-u8-set! (+ d (* x 4) 2) (vector-ref pb i))
                  (%mem-u8-set! (+ d (* x 4) 3) (vector-ref pa i)))
                (px (+ x 1)))))
          (row (+ y 1))))))

  ;; (png-decode! src slen dst [scratch [scratch-len]]) -> w h
  ;;
  ;; `scratch' holds the filtered scanlines the zlib stream inflates
  ;; to -- h * (1 + w*channels) bytes.  Left out, it is taken to be
  ;; the region directly above the RGBA output, so a caller with one
  ;; big buffer need not think about it; passed explicitly, the RGBA
  ;; output needs only w*h*4 bytes.  `scratch-len' bounds it.
  (define (png-decode! src slen dst . rest)
    ($src-init! src slen)
    (let* ((s ($png-scan $src-start))
           (ihdr (vector-ref s 0))
           (ch ($png-accept ihdr))
           (w (vector-ref ihdr 0))
           (h (vector-ref ihdr 1))
           (ct (vector-ref ihdr 3))
           (stride (* w ch))
           (rawlen (* h (+ stride 1)))
           (scratch (if (and (pair? rest) (car rest))
                        (car rest)
                        (+ dst (* w h 4))))
           (slimit (if (and (pair? rest) (pair? (cdr rest)) (cadr rest))
                       (cadr rest)
                       rawlen)))
      (when (or (= w 0) (= h 0)) (error 'image "PNG has a zero dimension"))
      (when (< slimit rawlen)
        (error 'image "PNG scanline scratch is too small"))
      (let* ((segs (make-vector (* 2 (vector-ref s 6)) 0)))
        (let l ((k 0) (ss (vector-ref s 5)))
          (when (pair? ss)
            (vector-set! segs (* 2 k) (car (car ss)))
            (vector-set! segs (+ (* 2 k) 1) (cdr (car ss)))
            (l (+ k 1) (cdr ss))))
        (let ((n ($zlib-inflate-segs! segs scratch rawlen)))
          (unless (= n rawlen)
            (error 'image "PNG image data is short"))))
      ($defilter! scratch h stride ch)
      (cond
       ((= ct 0)
        ($expand-grey! scratch dst w h stride
                       ;; tRNS for grey is one 16-bit sample; at depth
                       ;; 8 only its low byte can ever match
                       (if (>= (vector-ref s 4) 2)
                           ($u8 (+ (vector-ref s 3) 1))
                           -1)))
       ((= ct 2)
        (if (>= (vector-ref s 4) 6)
            ($expand-rgb! scratch dst w h stride
                          ($u8 (+ (vector-ref s 3) 1))
                          ($u8 (+ (vector-ref s 3) 3))
                          ($u8 (+ (vector-ref s 3) 5)))
            ($expand-rgb! scratch dst w h stride -1 -1 -1)))
       ((= ct 3)
        ($expand-palette! scratch dst w h stride
                          ($palette (vector-ref s 1) (vector-ref s 2)
                                    (vector-ref s 3) (vector-ref s 4))))
       ((= ct 4) ($expand-grey-alpha! scratch dst w h stride))
       (else ($expand-rgba! scratch dst w h stride)))
      (values w h)))

  ;; ---- PNG encoding -----------------------------------------------
  ;; Stored DEFLATE blocks: no Huffman coding on the way out, a fully
  ;; conforming stream, and the filter byte of every row is None.  The
  ;; size is knowable in closed form, which is what png-encode-size
  ;; answers.
  (define $store-max 65535)

  (define ($raw-len w h ch) (* h (+ (* w ch) 1)))
  (define ($zlib-len raw)
    ;; 2-byte header + ceil(raw/65535) five-byte block headers (at
    ;; least one, so an empty payload still terminates) + 4-byte adler
    (+ 2 (* 5 (max 1 (quotient (+ raw (- $store-max 1)) $store-max)))
       raw 4))

  (define (png-encode-size w h ch)
    (unless (or (= ch 3) (= ch 4))
      (error 'image "png-encode! writes 3- or 4-channel images"))
    (+ 8                                ; signature
       25                               ; IHDR
       (+ 12 ($zlib-len ($raw-len w h ch)))
       12))                             ; IEND

  (define $wpos 0)
  (define $wend 0)
  (define ($w8! v)
    (when (>= $wpos $wend) (error 'image "PNG output exceeds destination"))
    (%mem-u8-set! $wpos (bitwise-and v 255))
    (set! $wpos (+ $wpos 1)))
  (define ($w32be! v)
    ($w8! (quotient v 16777216))
    ($w8! (remainder (quotient v 65536) 256))
    ($w8! (remainder (quotient v 256) 256))
    ($w8! (remainder v 256)))
  (define ($wcrc! from)
    ;; from = the position of the chunk's type field; the CRC covers
    ;; the type and the data, and is read back out of staging memory
    (set! $src-bv #f)
    (set! $src-start from)
    (set! $src-end $wpos)
    (let-values (((hi lo) ($crc from (- $wpos from))))
      ($w8! (quotient hi 256)) ($w8! (remainder hi 256))
      ($w8! (quotient lo 256)) ($w8! (remainder lo 256))))

  (define (png-encode! pix w h ch dst . rest)
    (let ((need (png-encode-size w h ch)))
      (when (or (= w 0) (= h 0)) (error 'image "cannot encode a zero dimension"))
      (let ((cap (if (and (pair? rest) (car rest)) (car rest) need)))
        (when (< cap need) (error 'image "PNG output buffer is too small"))
        (set! $wpos dst)
        (set! $wend (+ dst cap)))
      ;; signature
      ($w8! 137) ($w8! 80) ($w8! 78) ($w8! 71)
      ($w8! 13) ($w8! 10) ($w8! 26) ($w8! 10)
      ;; IHDR
      ($w32be! 13)
      (let ((tp $wpos))
        ($w8! 73) ($w8! 72) ($w8! 68) ($w8! 82)
        ($w32be! w) ($w32be! h)
        ($w8! 8) ($w8! (if (= ch 4) 6 2)) ($w8! 0) ($w8! 0) ($w8! 0)
        ($wcrc! tp))
      ;; IDAT
      (let* ((stride (* w ch))
             (raw ($raw-len w h ch)))
        ($w32be! ($zlib-len raw))
        (let ((tp $wpos))
          ($w8! 73) ($w8! 68) ($w8! 65) ($w8! 84)
          ($w8! 120) ($w8! 1)           ; CM=8 CINFO=7, FCHECK making %31=0
          ;; the raw stream is (filter byte, row) repeated; stored
          ;; blocks cut it at 65535 bytes regardless of row edges, so
          ;; one cursor walks the logical stream and the block
          ;; bookkeeping rides alongside
          (let block ((done 0) (s1 1) (s2 0) (y 0) (col 0))
            (if (>= done raw)
                (begin ($w8! (quotient s2 256)) ($w8! (remainder s2 256))
                       ($w8! (quotient s1 256)) ($w8! (remainder s1 256)))
                (let* ((left (- raw done))
                       (n (if (> left $store-max) $store-max left))
                       (last (if (= n left) 1 0)))
                  ($w8! last)
                  ($w8! (remainder n 256)) ($w8! (quotient n 256))
                  (let ((inv (- 65535 n)))
                    ($w8! (remainder inv 256)) ($w8! (quotient inv 256)))
                  (let byte ((k 0) (s1 s1) (s2 s2) (y y) (col col))
                    (if (= k n)
                        (block (+ done n) s1 s2 y col)
                        (let ((v (if (= col 0)
                                     0
                                     (%mem-u8-ref
                                      (+ pix (* y stride) (- col 1))))))
                          ($w8! v)
                          (let* ((s1 (remainder (+ s1 v) 65521))
                                 (s2 (remainder (+ s2 s1) 65521))
                                 (col (+ col 1)))
                            (if (> col stride)
                                (byte (+ k 1) s1 s2 (+ y 1) 0)
                                (byte (+ k 1) s1 s2 y col)))))))))
          ($wcrc! tp)))
      ;; IEND
      ($w32be! 0)
      (let ((tp $wpos))
        ($w8! 73) ($w8! 69) ($w8! 78) ($w8! 68)
        ($wcrc! tp))
      (- $wpos dst)))

  ;; ---- TGA --------------------------------------------------------
  ;; Truecolour only: type 2 (uncompressed) and type 10 (run-length),
  ;; 24 or 32 bits per pixel, stored B G R [A].  The descriptor byte's
  ;; origin bits decide where row 0 of the file lands in the output,
  ;; which is always top-down RGBA8.
  (define ($tga-header at)
    (let ((idlen ($u8 at))
          (cmtype ($u8 (+ at 1)))
          (imtype ($u8 (+ at 2)))
          (w ($u16le (+ at 12)))
          (h ($u16le (+ at 14)))
          (bpp ($u8 (+ at 16)))
          (desc ($u8 (+ at 17))))
      (vector idlen cmtype imtype w h bpp desc)))

  (define ($tga-accept hd)
    (let ((cmtype (vector-ref hd 1)) (imtype (vector-ref hd 2))
          (bpp (vector-ref hd 5)))
      (unless (= cmtype 0)
        (error 'image "colour-mapped TGA is not supported"))
      (unless (or (= imtype 2) (= imtype 10))
        (error 'image "only truecolour TGA (type 2 or 10) is supported"))
      (unless (or (= bpp 24) (= bpp 32))
        (error 'image "only 24- or 32-bit TGA pixels are supported"))
      (when (or (= 0 (vector-ref hd 3)) (= 0 (vector-ref hd 4)))
        (error 'image "TGA has a zero dimension"))))

  (define (tga-info src slen)
    ($src-init! src slen)
    (let ((hd ($tga-header $src-start)))
      ($tga-accept hd)
      (values (vector-ref hd 3) (vector-ref hd 4)
              (vector-ref hd 5) (vector-ref hd 2))))

  (define (tga-decode! src slen dst)
    ($src-init! src slen)
    (let* ((hd ($tga-header $src-start))
           (accepted ($tga-accept hd))    ; raises before anything else runs
           (w (vector-ref hd 3))
           (h (vector-ref hd 4))
           (bpp (vector-ref hd 5))
           (desc (vector-ref hd 6))
           (bytes (quotient bpp 8))
           (top? (not (= 0 (bitwise-and desc 32))))
           (right? (not (= 0 (bitwise-and desc 16))))
           (total (* w h))
           (p (+ $src-start 18 (vector-ref hd 0))))
      ;; k counts pixels in file order; the origin flags decide where
      ;; each one goes, so nothing is written twice or left unwritten
      (let ((put!
             (lambda (k r g b a)
               (let* ((row (quotient k w))
                      (col (remainder k w))
                      (y (if top? row (- h 1 row)))
                      (x (if right? (- w 1 col) col))
                      (d (+ dst (* (+ (* y w) x) 4))))
                 (%mem-u8-set! d r)
                 (%mem-u8-set! (+ d 1) g)
                 (%mem-u8-set! (+ d 2) b)
                 (%mem-u8-set! (+ d 3) a)))))
        (if (= (vector-ref hd 2) 2)
            (let loop ((k 0) (p p))
              (when (< k total)
                (put! k ($u8 (+ p 2)) ($u8 (+ p 1)) ($u8 p)
                      (if (= bytes 4) ($u8 (+ p 3)) 255))
                (loop (+ k 1) (+ p bytes))))
            (let loop ((k 0) (p p))
              (when (< k total)
                (let ((head ($u8 p)))
                  (if (>= head 128)
                      ;; a run: the count is stored one less than it is
                      (let ((n (+ 1 (- head 128)))
                            (r ($u8 (+ p 3))) (g ($u8 (+ p 2)))
                            (b ($u8 (+ p 1)))
                            (a (if (= bytes 4) ($u8 (+ p 4)) 255)))
                        (when (> (+ k n) total)
                          (error 'image "TGA run overflows the image"))
                        (let run ((i 0))
                          (when (< i n) (put! (+ k i) r g b a) (run (+ i 1))))
                        (loop (+ k n) (+ p 1 bytes)))
                      (let ((n (+ head 1)))
                        (when (> (+ k n) total)
                          (error 'image "TGA packet overflows the image"))
                        (let raw ((i 0))
                          (when (< i n)
                            (let ((q (+ p 1 (* i bytes))))
                              (put! (+ k i) ($u8 (+ q 2)) ($u8 (+ q 1))
                                    ($u8 q)
                                    (if (= bytes 4) ($u8 (+ q 3)) 255)))
                            (raw (+ i 1))))
                        (loop (+ k n) (+ p 1 (* n bytes))))))))))
      (values w h)))
)
