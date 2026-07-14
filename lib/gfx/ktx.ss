;; KTX2 + Basis Universal ETC1S/BasisLZ and UASTC, from the specs --
;; no C++ transcoder, no dependency.  A .ktx2 file lands in staging
;; memory (fetch or bytes), ktx-parse reads the container, and the
;; ETC1S decoder reconstructs the codebooks and slices entirely in
;; Scheme; transcoders then repack blocks for whatever the GPU
;; speaks: ETC1 (bit-identical repack), BC1, or plain RGBA8 -- the
;; universal fallback that needs no extension at all.  UASTC blocks
;; (DFD color model 166), raw or zstd-supercompressed, decode to RGBA
;; through (gfx zstd) + (gfx uastc); ktx-upload! picks the path.
;;
;;   (define k (ktx-parse base len))
;;   (ktx-width k) (ktx-height k) (ktx-level-count k)
;;   (ktx-transcode! k level dst 'rgba)      ; ETC1S | 'etc1 | 'bc1
;;   (ktx-uastc-level! k level dst)          ; UASTC -> RGBA
;;
;; Verified block-for-block against the reference transcoder's unpack
;; output (test/ktx.ss ETC1S, test/ktx-uastc.ss UASTC raw + zstd).
;;
;; What this does NOT do yet: the P-frame video codec, global selector
;; codebooks, and cube/array/3D textures -- one 2D image with its mip
;; chain is the whole of it.
;;
;; Copyright (c) 2026 guenchi. MIT license; see LICENSE.
(library (gfx ktx)
  (export ktx-parse ktx? ktx-width ktx-height ktx-level-count
          ktx-scheme ktx-etc1s? ktx-uastc?
          ktx-level-width ktx-level-height
          ktx-transcode! ktx-transcode-bytes ktx-uastc-level!
          ktx-fetch! ktx-upload! ktx-stream! ktx-alpha?)
  (import (rnrs) (web js) (gfx gl) (gfx fx) (gfx zstd) (gfx uastc))

  ;; browser loader: fetch, one bulk copy into staging, parse, k
  (define (ktx-fetch! url k)
    (js-eval "globalThis.__goeteia_glb = (ab, base) => { new Uint8Array(globalThis.__goeteia_mem.buffer).set(new Uint8Array(ab), base); return 0 }")
    (js-method
     (js-method (js-call (js-get (js-global) "fetch") (js-undefined) url)
                "then"
                (lambda (resp) (js-method resp "arrayBuffer")))
     "then"
     (lambda (ab)
       (let* ((len (js->number (js-get ab "byteLength")))
              (base (fx-alloc! len)))
         (js-call (js-get (js-global) "__goeteia_glb") (js-undefined)
                  ab base)
         (k (ktx-parse base len))
         (js-undefined)))))

  ;; ---- streaming: the mip chain arrives smallest-first ----
  ;; KTX2 stores level data smallest mip at the lowest offset, so a
  ;; prefix of the file is a usable texture: metadata + codebooks +
  ;; every level but the biggest.  Three ranged requests -- a 1KB
  ;; head for the level index, the prefix (everything below level
  ;; 0's offset), then the rest -- with TEXTURE_BASE_LEVEL walking
  ;; down as levels land.  cb fires (slot k phase) with phase
  ;; 'preview when the small mips are up and 'full at the end; a
  ;; server without Range support answers 200 and the whole thing
  ;; degrades to one load and a single 'full
  (define ($ktx-range! url from to k)
    (js-eval "globalThis.__goeteia_range = globalThis.__goeteia_range || ((url, from, to, cb) => { fetch(url, { headers: { Range: 'bytes=' + from + '-' + to } }).then(r => { const cr = r.headers.get('Content-Range'); const total = cr ? Number(cr.split('/')[1]) : -1; return r.arrayBuffer().then(ab => cb(r.status, total, ab)); }); return 0 })")
    (js-eval "globalThis.__goeteia_glb = globalThis.__goeteia_glb || ((ab, base) => { new Uint8Array(globalThis.__goeteia_mem.buffer).set(new Uint8Array(ab), base); return 0 })")
    (js-call (js-get (js-global) "__goeteia_range") (js-undefined)
             url from to
             (lambda (status total ab)
               (k (js->number status) (js->number total) ab)
               (js-undefined))))

  (define ($ktx-put! ab base)
    (js-call (js-get (js-global) "__goeteia_glb") (js-undefined)
             ab base))

  ;; upload levels [from, to) of k into slot, compressed
  (define ($ktx-upload-range! k slot gfmt fmt tmp from to)
    (let lvl ((l from))
      (when (< l to)
        (ktx-transcode! k l tmp fmt)
        (gl-compressed-level! slot l gfmt
                              (ktx-level-width k l)
                              (ktx-level-height k l)
                              tmp (ktx-transcode-bytes k l fmt))
        (lvl (+ l 1)))))

  (define (ktx-stream! url cb)
    ($ktx-range!
     url 0 1023
     (lambda (status total ab)
       (if (not (= status 206))
           ;; no ranges: the whole file just arrived
           (let* ((len (js->number (js-get ab "byteLength")))
                  (base (fx-alloc! len)))
             ($ktx-put! ab base)
             (let* ((k (ktx-parse base len))
                    (slot (ktx-upload! k)))
               (cb slot k 'full)))
           (let* ((base (fx-alloc! total)))
             ($ktx-put! ab base)
             (let* ((levels (let ((n ($k-u32 (+ base 40))))
                              (if (= n 0) 1 n)))
                    (cut ($k-u64 (+ base 80))))  ; level 0 sits last
               (if (< levels 2)
                   ($ktx-range!
                    url 1024 (- total 1)
                    (lambda (s2 t2 ab2)
                      ($ktx-put! ab2 (+ base 1024))
                      (let* ((k (ktx-parse base total))
                             (slot (ktx-upload! k)))
                        (cb slot k 'full))))
                   ($ktx-range!
                    url 1024 (- cut 1)
                    (lambda (s2 t2 ab2)
                      ($ktx-put! ab2 (+ base 1024))
                      (let* ((k (ktx-parse base cut))
                             (fam (if (ktx-alpha? k)
                                      0
                                      (gl-compressed-family)))
                             (n (ktx-level-count k)))
                        (if (= fam 0)
                            ;; rgba fallback: the smallest usable
                            ;; level previews, level 0 replaces it
                            (let* ((bytes (ktx-transcode-bytes
                                           k 1 'rgba))
                                   (tmp (fx-alloc! bytes))
                                   (slot (fx-texture!)))
                              (ktx-transcode! k 1 tmp 'rgba)
                              (gl-texture-data!
                               slot tmp (ktx-level-width k 1)
                               (ktx-level-height k 1))
                              (cb slot k 'preview)
                              ($ktx-range!
                               url cut (- total 1)
                               (lambda (s3 t3 ab3)
                                 ($ktx-put! ab3 (+ base cut))
                                 (let ((tmp0 (fx-alloc!
                                              (ktx-transcode-bytes
                                               k 0 'rgba))))
                                   (ktx-transcode! k 0 tmp0 'rgba)
                                   (gl-texture-data!
                                    slot tmp0 (ktx-level-width k 0)
                                    (ktx-level-height k 0))
                                   (cb slot k 'full)))))
                            (let* ((fmt (if (= fam 2) 'etc1 'bc1))
                                   (gfmt (if (= fam 2) 0 1))
                                   (tmp (fx-alloc!
                                         (ktx-transcode-bytes
                                          k 0 fmt)))
                                   (slot (fx-slot!)))
                              (gl-texture-compressed! slot n)
                              ($ktx-upload-range! k slot gfmt fmt
                                                  tmp 1 n)
                              (gl-texture-base-level! slot 1)
                              (cb slot k 'preview)
                              ($ktx-range!
                               url cut (- total 1)
                               (lambda (s3 t3 ab3)
                                 ($ktx-put! ab3 (+ base cut))
                                 ($ktx-upload-range! k slot gfmt fmt
                                                     tmp 0 1)
                                 (gl-texture-base-level! slot 0)
                                 (cb slot k 'full)))))))))))))))

  ;; transcode every level for whatever the context speaks and
  ;; upload the chain; returns the texture slot.  Family 2 keeps the
  ;; blocks as ETC1, 1 repacks BC1, 0 decodes level 0 to RGBA
  (define (ktx-upload! k)
    (if (ktx-uastc? k)
        ;; UASTC decodes to RGBA (level 0) and uploads uncompressed
        (let* ((w (ktx-level-width k 0)) (h (ktx-level-height k 0))
               (tmp (fx-alloc! (* w h 4)))
               (slot (fx-texture!)))
          (ktx-uastc-level! k 0 tmp)
          (gl-texture-data! slot tmp w h)
          slot)
        (ktx-upload-basis! k)))

  (define (ktx-upload-basis! k)
    (let ((fam (if (ktx-alpha? k) 0 (gl-compressed-family)))
          (n (ktx-level-count k)))
      (if (= fam 0)
          (let* ((bytes (ktx-transcode-bytes k 0 'rgba))
                 (tmp (fx-alloc! bytes))
                 (slot (fx-texture!)))
            (ktx-transcode! k 0 tmp 'rgba)
            (gl-texture-data! slot tmp (ktx-level-width k 0)
                              (ktx-level-height k 0))
            slot)
          (let* ((fmt (if (= fam 2) 'etc1 'bc1))
                 (gfmt (if (= fam 2) 0 1))
                 (tmp (fx-alloc! (ktx-transcode-bytes k 0 fmt)))
                 (slot (fx-slot!)))
            (gl-texture-compressed! slot n)
            (let lvl ((l 0))
              (when (< l n)
                (ktx-transcode! k l tmp fmt)
                (gl-compressed-level! slot l gfmt
                                      (ktx-level-width k l)
                                      (ktx-level-height k l)
                                      tmp
                                      (ktx-transcode-bytes k l fmt))
                (lvl (+ l 1))))
            slot))))

  ;; ---- little-endian reads from staging ----
  (define ($k-u16 at)
    (+ (%mem-u8-ref at) (* 256 (%mem-u8-ref (+ at 1)))))
  (define ($k-u32 at)
    (+ ($k-u16 at) (* 65536 ($k-u16 (+ at 2)))))
  ;; 64-bit offsets: files past 1GB don't fit fixnums anyway; read
  ;; the low word and insist the high word is zero
  (define ($k-u64 at)
    (let ((hi ($k-u32 (+ at 4))))
      (unless (= hi 0) (error 'ktx "file too large"))
      ($k-u32 at)))

  (define-record-type (ktx $make-ktx ktx?)
    (fields (immutable base $ktx-base)
            (immutable vkformat $ktx-vkformat)
            (immutable width ktx-width)
            (immutable height ktx-height)
            (immutable levels ktx-level-count)
            (immutable scheme ktx-scheme)   ; 0 none, 1 BasisLZ
            (immutable dfd-color $ktx-dfd-color) ; 163 ETC1S, 166 UASTC
            ;; level index: #(byteOffset byteLength uncompressed) each
            (immutable lindex $ktx-lindex)
            ;; BasisLZ global data, decoded once at parse:
            ;; #(endpoints selectors imagedescs) | #f
            (immutable sgd $ktx-sgd)))

  ;; does the file carry alpha slices?  (they are second slices per
  ;; image, ETC1S grayscale -- R=G=B carries the coverage)
  (define (ktx-alpha? k)
    (let ((sgd ($ktx-sgd k)))
      (and sgd
           (> (vector-ref (vector-ref (vector-ref sgd 3) 0) 3) 0)
           #t)))

  (define (ktx-etc1s? k)
    (and (= (ktx-scheme k) 1) (= ($ktx-dfd-color k) 163)))

  ;; UASTC LDR 4x4 (DFD color model 166), raw or zstd-supercompressed
  (define (ktx-uastc? k)
    (= ($ktx-dfd-color k) 166))

  (define (ktx-level-width k l)
    (let ((w (ktx-width k)))
      (let shrink ((w w) (l l))
        (if (= l 0) (if (< w 1) 1 w) (shrink (quotient w 2) (- l 1))))))
  (define (ktx-level-height k l)
    (let ((h (ktx-height k)))
      (let shrink ((h h) (l l))
        (if (= l 0) (if (< h 1) 1 h) (shrink (quotient h 2) (- l 1))))))

  ;; the 12 identifier bytes: "«KTX 20»\r\n\x1A\n"
  (define $k-magic '(#xAB #x4B #x54 #x58 #x20 #x32 #x30 #xBB
                     #x0D #x0A #x1A #x0A))

  (define (ktx-parse base len)
    (let check ((ms $k-magic) (i 0))
      (when (pair? ms)
        (unless (= (%mem-u8-ref (+ base i)) (car ms))
          (error 'ktx "not a KTX2 file"))
        (check (cdr ms) (+ i 1))))
    (let* ((vkfmt ($k-u32 (+ base 12)))
           (w ($k-u32 (+ base 20)))
           (h ($k-u32 (+ base 24)))
           (depth ($k-u32 (+ base 28)))
           (layers ($k-u32 (+ base 32)))
           (faces ($k-u32 (+ base 36)))
           (levels (let ((n ($k-u32 (+ base 40)))) (if (= n 0) 1 n)))
           (scheme ($k-u32 (+ base 44)))
           (dfd-off ($k-u32 (+ base 48)))
           (sgd-off ($k-u64 (+ base 64)))
           (sgd-len ($k-u64 (+ base 72)))
           (lindex (make-vector levels #f)))
      (unless (and (= depth 0) (< layers 2) (= faces 1))
        (error 'ktx "arrays/cubes/3D not supported yet"))
      (let lvl ((l 0))
        (when (< l levels)
          (let ((at (+ base 80 (* l 24))))
            (vector-set! lindex l
                         (vector ($k-u64 at)
                                 ($k-u64 (+ at 8))
                                 ($k-u64 (+ at 16)))))
          (lvl (+ l 1))))
      ;; the DFD's colorModel: byte 12 of the first sample-less
      ;; header words -- vendor 0, descriptor type 0, colorModel at
      ;; dfd + 4 (total size u32) + 8
      (let ((color (%mem-u8-ref (+ base dfd-off 12))))
        ($make-ktx base vkfmt w h levels scheme color lindex
                   (and (= scheme 1)
                        ($basis-sgd (+ base sgd-off) sgd-len levels))))))

  ;; ================= the BasisLZ / ETC1S decoder =================
  ;; From the Khronos bitstream specification and the reference
  ;; transcoder's constants.  Every stream is LSB-first bits.

  ;; ---- bit reader: #(ptr end buf count); buf stays under 2^30 so
  ;; it never leaves fixnum range (refill caps at 30 live bits, and
  ;; no read needs more than 16)
  (define ($br at end) (vector at end 0 0))
  (define ($br-refill! b n)
    (let fill ()
      (when (and (< (vector-ref b 3) n) (<= (vector-ref b 3) 22))
        (let ((c (if (< (vector-ref b 0) (vector-ref b 1))
                     (%mem-u8-ref (vector-ref b 0))
                     0)))
          (vector-set! b 0 (+ (vector-ref b 0) 1))
          (vector-set! b 2 (+ (vector-ref b 2)
                              (bitwise-arithmetic-shift-left
                               c (vector-ref b 3))))
          (vector-set! b 3 (+ (vector-ref b 3) 8)))
        (fill))))
  (define ($br-bits b n)
    ($br-refill! b n)
    (let ((v (bitwise-and (vector-ref b 2)
                          (- (bitwise-arithmetic-shift-left 1 n) 1))))
      (vector-set! b 2 (bitwise-arithmetic-shift-right
                        (vector-ref b 2) n))
      (vector-set! b 3 (- (vector-ref b 3) n))
      v))
  ;; peek n bits (up to 16) without consuming, and drop k after a
  ;; table hit -- the fast-table decode's two halves
  (define ($br-peek b n)
    ($br-refill! b n)
    (bitwise-and (vector-ref b 2)
                 (- (bitwise-arithmetic-shift-left 1 n) 1)))
  (define ($br-drop! b k)
    (vector-set! b 2 (bitwise-arithmetic-shift-right (vector-ref b 2) k))
    (vector-set! b 3 (- (vector-ref b 3) k)))
  (define ($br-vlc b chunk)             ; basis variable-length count
    (let loop ((shift 0) (out 0))
      (let* ((v ($br-bits b (+ chunk 1)))
             (out (+ out (bitwise-arithmetic-shift-left
                          (bitwise-and
                           v (- (bitwise-arithmetic-shift-left 1 chunk)
                                1))
                          shift))))
        (if (= 0 (bitwise-arithmetic-shift-right v chunk))
            out
            (loop (+ shift chunk) out)))))

  ;; ---- canonical huffman ----
  ;; codes assign canonically by (length, symbol) and arrive
  ;; MSB-first on the wire (the writer bit-reverses, the reader is
  ;; LSB-first: the reversal cancels).  Decode walks lengths:
  ;; #(counts firsts syms) -- counts[len], first code per len,
  ;; symbols sorted by (len, sym)
  (define ($huff-build sizes n)
    (let ((counts (make-vector 17 0)))
      (let cnt ((i 0))
        (when (< i n)
          (let ((l (vector-ref sizes i)))
            (when (> l 0)
              (vector-set! counts l (+ 1 (vector-ref counts l)))))
          (cnt (+ i 1))))
      (let ((firsts (make-vector 17 0))
            (offs (make-vector 17 0))
            (total (let sum ((l 1) (t 0))
                     (if (> l 16) t
                         (sum (+ l 1) (+ t (vector-ref counts l)))))))
        (let codes ((l 1) (code 0) (off 0))
          (when (<= l 16)
            (vector-set! firsts l code)
            (vector-set! offs l off)
            (codes (+ l 1)
                   (bitwise-arithmetic-shift-left
                    (+ code (vector-ref counts l)) 1)
                   (+ off (vector-ref counts l)))))
        (let ((syms (make-vector (if (= total 0) 1 total) 0))
              (fill (make-vector 17 0))
              ;; the 10-bit fast table: entry = sym*32 + len for a
              ;; code of at most 10 bits, -1 to fall back to the
              ;; length walk.  The reader consumes bits low-first
              ;; while a code reads high-first, so a code's table
              ;; slots are its bit-reversal with the high bits free
              (fast (make-vector 1024 -1)))
          (let put ((i 0))
            (when (< i n)
              (let ((l (vector-ref sizes i)))
                (when (> l 0)
                  (let ((slot (+ (vector-ref offs l)
                                 (vector-ref fill l))))
                    (vector-set! syms slot i)
                    (vector-set! fill l (+ 1 (vector-ref fill l)))
                    (when (<= l 10)
                      ;; this symbol's canonical code, MSB-first
                      (let* ((code (+ (vector-ref firsts l)
                                      (- slot (vector-ref offs l))))
                             (rev (let rv ((j 0) (r 0))
                                    (if (= j l)
                                        r
                                        (rv (+ j 1)
                                            (+ (bitwise-arithmetic-shift-left
                                                r 1)
                                               (bitwise-and
                                                (bitwise-arithmetic-shift-right
                                                 code j)
                                                1))))))
                             (val (+ (* i 32) l)))
                        (let hi ((h 0))
                          (when (< h (bitwise-arithmetic-shift-left
                                      1 (- 10 l)))
                            (vector-set!
                             fast
                             (+ rev (bitwise-arithmetic-shift-left h l))
                             val)
                            (hi (+ h 1)))))))))
              (put (+ i 1))))
          (vector counts firsts syms offs fast)))))

  (define ($huff-decode b t)
    (let ((e (vector-ref (vector-ref t 4) ($br-peek b 10))))
      (if (>= e 0)
          (begin ($br-drop! b (bitwise-and e 31))
                 (quotient e 32))
          ;; an 11+ bit code: the length walk, from the top
          (let walk ((l 1) (code 0))
            (if (> l 16)
                (error 'ktx "bad huffman code")
                (let ((code (+ (bitwise-arithmetic-shift-left code 1)
                               ($br-bits b 1))))
                  (let ((c (vector-ref (vector-ref t 0) l)))
                    (if (and (> c 0)
                             (< (- code (vector-ref (vector-ref t 1) l)) c)
                             (>= (- code (vector-ref (vector-ref t 1) l)) 0))
                        (vector-ref (vector-ref t 2)
                                    (+ (vector-ref (vector-ref t 3) l)
                                       (- code
                                          (vector-ref (vector-ref t 1) l))))
                        (walk (+ l 1) code)))))))))

  ;; the code-length-code symbol order (spec constant)
  (define $huff-cl-order
    '#(17 18 19 20 0 8 7 9 6 10 5 11 4 12 3 13 2 14 1 15 16))

  (define ($huff-read b)                ; read_huffman_table
    (let ((total ($br-bits b 14)))
      (if (= total 0)
          #f
          (let ((clsizes (make-vector 21 0))
                (ncl ($br-bits b 5)))
            (let rd ((i 0))
              (when (< i ncl)
                (vector-set! clsizes (vector-ref $huff-cl-order i)
                             ($br-bits b 3))
                (rd (+ i 1))))
            (let ((clt ($huff-build clsizes 21))
                  (sizes (make-vector total 0)))
              (let fill ((cur 0))
                (when (< cur total)
                  (let ((c ($huff-decode b clt)))
                    (cond
                     ((<= c 16)
                      (vector-set! sizes cur c)
                      (fill (+ cur 1)))
                     ((= c 17) (fill (+ cur 3 ($br-bits b 3))))
                     ((= c 18) (fill (+ cur 11 ($br-bits b 7))))
                     (else
                      (let ((rpt (if (= c 19)
                                     (+ 3 ($br-bits b 2))
                                     (+ 7 ($br-bits b 7))))
                            (prev (vector-ref sizes (- cur 1))))
                        (let rep ((r 0) (cur cur))
                          (if (= r rpt)
                              (fill cur)
                              (begin
                                (vector-set! sizes cur prev)
                                (rep (+ r 1) (+ cur 1)))))))))))
              ($huff-build sizes total))))))

  ;; ---- the codebooks and slice tables, decoded once at parse ----
  ;; sgd: #(colors intens selrows imagedescs slice-tables histsize
  ;;        endpoint-count selector-count)
  (define ($basis-sgd at len levels)
    (let* ((epc ($k-u16 at))
           (selc ($k-u16 (+ at 2)))
           (eplen ($k-u32 (+ at 4)))
           (sellen ($k-u32 (+ at 8)))
           (tablen ($k-u32 (+ at 12)))
           (descs (make-vector levels #f))
           (blob (+ at 20 (* levels 20))))
      (let d ((l 0))
        (when (< l levels)
          (let ((e (+ at 20 (* l 20))))
            (when (> (bitwise-and ($k-u32 e) 2) 0)
              (error 'ktx "P-frame video not supported"))
            (vector-set! descs l
                         (vector ($k-u32 (+ e 4)) ($k-u32 (+ e 8))
                                 ($k-u32 (+ e 12)) ($k-u32 (+ e 16)))))
          (d (+ l 1))))
      ;; endpoints: three color-delta models split by predecessor
      ;; magnitude, one inten model, DPCM with mod-32/mod-8 wrap
      (let* ((eb ($br blob (+ blob eplen)))
             (cd0 ($huff-read eb))
             (cd1 ($huff-read eb))
             (cd2 ($huff-read eb))
             (it ($huff-read eb))
             (gray (= 1 ($br-bits eb 1)))
             (colors (make-vector epc 0))
             (intens (make-vector epc 0)))
        (let ep ((i 0) (pr 16) (pg 16) (pb 16) (pi 0))
          (when (< i epc)
            (let* ((inten (bitwise-and (+ pi ($huff-decode eb it)) 7))
                   (pick (lambda (p)
                           (cond ((<= p 9) cd0)
                                 ((<= p 21) cd1)
                                 (else cd2))))
                   (r (bitwise-and (+ pr ($huff-decode eb (pick pr)))
                                   31))
                   (g (if gray r
                          (bitwise-and (+ pg ($huff-decode eb (pick pg)))
                                       31)))
                   (bl (if gray r
                           (bitwise-and
                            (+ pb ($huff-decode eb (pick pb))) 31))))
              (vector-set! intens i inten)
              (vector-set! colors i
                           (+ r (* 32 g) (* 1024 bl)))
              (ep (+ i 1) r g bl inten))))
        ;; selectors: raw 4x8-bit rows, or XOR-delta huffman
        (let* ((sb ($br (+ blob eplen) (+ blob eplen sellen)))
               (selrows (make-vector (* selc 4) 0)))
          (unless (= 0 ($br-bits sb 2))
            (error 'ktx "global selector codebooks not supported"))
          (if (= 1 ($br-bits sb 1))     ; uncompressed
              (let s ((i 0))
                (when (< i (* selc 4))
                  (vector-set! selrows i ($br-bits sb 8))
                  (s (+ i 1))))
              (let ((dm ($huff-read sb)))
                (let row ((r 0))
                  (when (< r 4)
                    (vector-set! selrows r ($br-bits sb 8))
                    (row (+ r 1))))
                (let s ((i 4))
                  (when (< i (* selc 4))
                    (vector-set! selrows i
                                 (bitwise-xor
                                  ($huff-decode sb dm)
                                  (vector-ref selrows (- i 4))))
                    (s (+ i 1))))))
          ;; slice tables: four models plus the history buffer size
          (let* ((tb ($br (+ blob eplen sellen)
                          (+ blob eplen sellen tablen)))
                 (predm ($huff-read tb))
                 (deltam ($huff-read tb))
                 (selm ($huff-read tb))
                 (rlem ($huff-read tb))
                 (hist ($br-bits tb 13)))
            (vector colors intens selrows descs
                    (vector predm deltam selm rlem)
                    hist epc selc))))))

  ;; ---- ETC1 intensity modifiers (selector 0..3 direct) ----
  (define $etc1-inten
    '#(#(-8 -2 2 8) #(-17 -5 5 17) #(-29 -9 9 29) #(-42 -13 13 42)
       #(-60 -18 18 60) #(-80 -24 24 80) #(-106 -33 33 106)
       #(-183 -47 47 183)))
  (define ($x5 v) (bitwise-ior (bitwise-arithmetic-shift-left v 3)
                               (bitwise-arithmetic-shift-right v 2)))
  (define ($clamp8 v) (if (< v 0) 0 (if (> v 255) 255 v)))

  ;; basis selector -> raw ETC1 selector bits
  (define $sel->etc1 '#(3 2 0 1))

  ;; ---- the slice: per-block (endpoint, selector) state machine,
  ;; emitting straight into the caller's block writer ----
  (define ($slice-decode! sgd at len nbx nby emit!)
    (let* ((tabs (vector-ref sgd 4))
           (predm (vector-ref tabs 0))
           (deltam (vector-ref tabs 1))
           (selm (vector-ref tabs 2))
           (rlem (vector-ref tabs 3))
           (histsize (vector-ref sgd 5))
           (epc (vector-ref sgd 6))
           (selc (vector-ref sgd 7))
           (b ($br at (+ at len)))
           (hist (make-vector (if (= histsize 0) 1 histsize) 0))
           (rover (vector (quotient histsize 2)))
           (uprow (make-vector nbx 0))   ; previous row's endpoints
           (saved (make-vector (quotient (+ nbx 1) 2) 0))
           (hist-add!
            (lambda (v)
              (vector-set! hist (vector-ref rover 0) v)
              (vector-set! rover 0 (+ 1 (vector-ref rover 0)))
              (when (= (vector-ref rover 0) histsize)
                (vector-set! rover 0 (quotient histsize 2)))))
           (hist-use!
            (lambda (i)
              (when (> i 0)
                (let ((a (vector-ref hist (quotient i 2)))
                      (v (vector-ref hist i)))
                  (vector-set! hist (quotient i 2) v)
                  (vector-set! hist i a))))))
      (let loop ((by 0) (bx 0)
                 (cur-pred 0)            ; the 2x2 group's pred bits
                 (prev-pred 0)           ; last pred symbol (repeats)
                 (pred-rpt 0)
                 (left 0)                ; left block's endpoint
                 (prev-ep 0)             ; previous block's endpoint
                 (ul 0)                  ; upper-left endpoint
                 (sel-rle 0))
        (when (< by nby)
          (if (= bx nbx)
              (loop (+ by 1) 0 cur-pred prev-pred pred-rpt
                    left prev-ep 0 sel-rle)
              ;; the group's pred bits: read at even/even, restore
              ;; the saved top nibble on odd rows
              (let-values
                  (((cur-pred prev-pred pred-rpt)
                    (cond
                     ((and (= 0 (bitwise-and bx 1))
                           (= 0 (bitwise-and by 1)))
                      (if (> pred-rpt 0)
                          (begin
                            (vector-set! saved (quotient bx 2)
                                         (bitwise-arithmetic-shift-right
                                          prev-pred 4))
                            (values prev-pred prev-pred
                                    (- pred-rpt 1)))
                          (let ((s ($huff-decode b predm)))
                            (if (= s 256)
                                (let ((n (+ ($br-vlc b 4) 2)))
                                  (vector-set!
                                   saved (quotient bx 2)
                                   (bitwise-arithmetic-shift-right
                                    prev-pred 4))
                                  (values prev-pred prev-pred n))
                                (begin
                                  (vector-set!
                                   saved (quotient bx 2)
                                   (bitwise-arithmetic-shift-right
                                    s 4))
                                  (values s s pred-rpt))))))
                     ((and (= 0 (bitwise-and bx 1))
                           (= 1 (bitwise-and by 1)))
                      (values (vector-ref saved (quotient bx 2))
                              prev-pred pred-rpt))
                     (else (values cur-pred prev-pred pred-rpt)))))
                (let* ((pred (bitwise-and
                              (bitwise-arithmetic-shift-right
                               cur-pred (* 2 (bitwise-and bx 1)))
                              3))
                       (up (vector-ref uprow bx))
                       (ep (cond
                            ((= pred 0) left)
                            ((= pred 1) up)
                            ((= pred 2) ul)
                            (else
                             (let ((e (+ prev-ep
                                         ($huff-decode b deltam))))
                               (if (>= e epc) (- e epc) e))))))
                  ;; the selector, through the history buffer
                  (let-values
                      (((sel sel-rle)
                        (if (> sel-rle 0)
                            (values (vector-ref hist 0) (- sel-rle 1))
                            (let ((s ($huff-decode b selm)))
                              (if (= s (+ selc histsize))
                                  (let* ((run ($huff-decode b rlem))
                                         (n (if (= run 63)
                                                (+ ($br-vlc b 7) 3)
                                                (+ run 3))))
                                    (values (vector-ref hist 0)
                                            (- n 1)))
                                  (if (>= s selc)
                                      (let ((v (vector-ref
                                                hist (- s selc))))
                                        (hist-use! (- s selc))
                                        (values v sel-rle))
                                      (begin
                                        (hist-add! s)
                                        (values s sel-rle))))))))
                    (emit! bx by ep sel)
                    (let ((old-up up))
                      (vector-set! uprow bx ep)
                      (loop by (+ bx 1) cur-pred prev-pred pred-rpt
                            ep ep old-up sel-rle)))))))))
    #t)

  ;; ---- block writers ----
  (define ($blk-rgba! sgd dst w h)
    (lambda (bx by ep sel)
      (let* ((c (vector-ref (vector-ref sgd 0) ep))
             (r ($x5 (bitwise-and c 31)))
             (g ($x5 (bitwise-and (quotient c 32) 31)))
             (bl ($x5 (quotient c 1024)))
             (tab (vector-ref $etc1-inten
                              (vector-ref (vector-ref sgd 1) ep)))
             (rows (vector-ref sgd 2))
             (rbase (* sel 4)))
        (let py ((y 0))
          (when (< y 4)
            (let ((row (vector-ref rows (+ rbase y)))
                  (gy (+ (* by 4) y)))
              (when (< gy h)
                (let px ((x 0))
                  (when (< x 4)
                    (let ((gx (+ (* bx 4) x)))
                      (when (< gx w)
                        (let* ((s (bitwise-and
                                   (bitwise-arithmetic-shift-right
                                    row (* x 2))
                                   3))
                               (m (vector-ref tab s))
                               (at (+ dst (* (+ (* gy w) gx) 4))))
                          (%mem-u8-set! at ($clamp8 (+ r m)))
                          (%mem-u8-set! (+ at 1) ($clamp8 (+ g m)))
                          (%mem-u8-set! (+ at 2) ($clamp8 (+ bl m)))
                          (%mem-u8-set! (+ at 3) 255))))
                    (px (+ x 1))))))
            (py (+ y 1)))))))

  ;; alpha rides its own grayscale slice: same decode, but only the
  ;; A byte of the already-written RGBA pixels updates
  (define ($blk-alpha! sgd dst w h)
    (lambda (bx by ep sel)
      (let* ((c (vector-ref (vector-ref sgd 0) ep))
             (r ($x5 (bitwise-and c 31)))
             (tab (vector-ref $etc1-inten
                              (vector-ref (vector-ref sgd 1) ep)))
             (rows (vector-ref sgd 2))
             (rbase (* sel 4)))
        (let py ((y 0))
          (when (< y 4)
            (let ((row (vector-ref rows (+ rbase y)))
                  (gy (+ (* by 4) y)))
              (when (< gy h)
                (let px ((x 0))
                  (when (< x 4)
                    (let ((gx (+ (* bx 4) x)))
                      (when (< gx w)
                        (let* ((s (bitwise-and
                                   (bitwise-arithmetic-shift-right
                                    row (* x 2))
                                   3))
                               (m (vector-ref tab s)))
                          (%mem-u8-set!
                           (+ dst (* (+ (* gy w) gx) 4) 3)
                           ($clamp8 (+ r m))))))
                    (px (+ x 1))))))
            (py (+ y 1)))))))

  (define ($blk-etc1! sgd dst nbx)
    (lambda (bx by ep sel)
      (let* ((c (vector-ref (vector-ref sgd 0) ep))
             (r5 (bitwise-and c 31))
             (g5 (bitwise-and (quotient c 32) 31))
             (b5 (quotient c 1024))
             (in (vector-ref (vector-ref sgd 1) ep))
             (rows (vector-ref sgd 2))
             (rbase (* sel 4))
             (at (+ dst (* (+ (* by nbx) bx) 8))))
        (%mem-u8-set! at (* r5 8))       ; R1<<3, dR = 0
        (%mem-u8-set! (+ at 1) (* g5 8))
        (%mem-u8-set! (+ at 2) (* b5 8))
        ;; flip 0, diff 1, cw2 = cw1 = inten
        (%mem-u8-set! (+ at 3) (+ 64 (* in 8) in))
        (%mem-u8-set! (+ at 4) 0) (%mem-u8-set! (+ at 5) 0)
        (%mem-u8-set! (+ at 6) 0) (%mem-u8-set! (+ at 7) 0)
        (let px ((x 0))
          (when (< x 4)
            (let ((row-shift (* x 2)))
              (let py ((y 0))
                (when (< y 4)
                  (let* ((row (vector-ref rows (+ rbase y)))
                         (bs (bitwise-and
                              (bitwise-arithmetic-shift-right
                               row row-shift)
                              3))
                         (raw (vector-ref $sel->etc1 bs))
                         (bi (+ (* x 4) y))
                         (bofs (- 7 (quotient bi 8)))
                         (bit (bitwise-and bi 7)))
                    ;; LSB plane in bytes 6..7, MSB plane in 4..5
                    (%mem-u8-set!
                     (+ at bofs)
                     (bitwise-ior (%mem-u8-ref (+ at bofs))
                                  (bitwise-arithmetic-shift-left
                                   (bitwise-and raw 1) bit)))
                    (%mem-u8-set!
                     (+ at (- bofs 2))
                     (bitwise-ior (%mem-u8-ref (+ at (- bofs 2)))
                                  (bitwise-arithmetic-shift-left
                                   (bitwise-arithmetic-shift-right
                                    raw 1)
                                   bit))))
                  (py (+ y 1)))))
            (px (+ x 1)))))))

  ;; BC1: endpoints from the block's brightest and darkest ETC1S
  ;; colors, midpoints on BC1's interpolants -- the simple path (the
  ;; reference uses baked optimal tables; this trades a little PSNR
  ;; for no tables at all)
  (define ($blk-bc1! sgd dst nbx)
    (lambda (bx by ep sel)
      (let* ((c (vector-ref (vector-ref sgd 0) ep))
             (r ($x5 (bitwise-and c 31)))
             (g ($x5 (bitwise-and (quotient c 32) 31)))
             (bl ($x5 (quotient c 1024)))
             (tab (vector-ref $etc1-inten
                              (vector-ref (vector-ref sgd 1) ep)))
             (p565 (lambda (m)
                     (+ (* 2048 (bitwise-arithmetic-shift-right
                                 ($clamp8 (+ r m)) 3))
                        (* 32 (bitwise-arithmetic-shift-right
                               ($clamp8 (+ g m)) 2))
                        (bitwise-arithmetic-shift-right
                         ($clamp8 (+ bl m)) 3))))
             (hi (p565 (vector-ref tab 3)))
             (lo (p565 (vector-ref tab 0)))
             (rows (vector-ref sgd 2))
             (rbase (* sel 4))
             (at (+ dst (* (+ (* by nbx) bx) 8))))
        (let-values (((c0 c1 map)
                      (cond
                       ((> hi lo) (values hi lo '#(1 3 2 0)))
                       ((< hi lo) (values lo hi '#(0 2 3 1)))
                       (else (values hi lo '#(0 0 0 0))))))
          (%mem-u8-set! at (remainder c0 256))
          (%mem-u8-set! (+ at 1) (quotient c0 256))
          (%mem-u8-set! (+ at 2) (remainder c1 256))
          (%mem-u8-set! (+ at 3) (quotient c1 256))
          (let py ((y 0))
            (when (< y 4)
              (let ((row (vector-ref rows (+ rbase y))))
                (%mem-u8-set!
                 (+ at 4 y)
                 (let px ((x 0) (out 0))
                   (if (= x 4)
                       out
                       (px (+ x 1)
                           (+ out
                              (bitwise-arithmetic-shift-left
                               (vector-ref
                                map
                                (bitwise-and
                                 (bitwise-arithmetic-shift-right
                                  row (* x 2))
                                 3))
                               (* x 2))))))))
              (py (+ y 1))))))))

  ;; ---- the public transcode ----
  (define (ktx-transcode-bytes k l fmt)
    (let ((bw (quotient (+ (ktx-level-width k l) 3) 4))
          (bh (quotient (+ (ktx-level-height k l) 3) 4)))
      (case fmt
        ((rgba) (* (ktx-level-width k l) (ktx-level-height k l) 4))
        ((etc1 bc1) (* bw bh 8))
        (else (error 'ktx "unknown format" fmt)))))

  (define (ktx-transcode! k l dst fmt)
    (unless (ktx-etc1s? k)
      (error 'ktx "only ETC1S/BasisLZ files transcode"))
    (let* ((sgd ($ktx-sgd k))
           (lv (vector-ref ($ktx-lindex k) l))
           (desc (vector-ref (vector-ref sgd 3) l))
           (at (+ ($ktx-base k) (vector-ref lv 0) (vector-ref desc 0)))
           (len (vector-ref desc 1))
           (w (ktx-level-width k l))
           (h (ktx-level-height k l))
           (nbx (quotient (+ w 3) 4))
           (nby (quotient (+ h 3) 4)))
      ($slice-decode!
       sgd at len nbx nby
       (case fmt
         ((rgba) ($blk-rgba! sgd dst w h))
         ((etc1) ($blk-etc1! sgd dst nbx))
         ((bc1) ($blk-bc1! sgd dst nbx))
         (else (error 'ktx "unknown format" fmt))))
      ;; the alpha slice, when present and the target can carry it
      (when (and (eq? fmt 'rgba)
                 (> (vector-ref desc 3) 0))
        ($slice-decode!
         sgd
         (+ ($ktx-base k) (vector-ref lv 0) (vector-ref desc 2))
         (vector-ref desc 3)
         nbx nby
         ($blk-alpha! sgd dst w h)))))

  ;; decode a UASTC level to RGBA at `dst' (w*h*4 bytes).  A zstd frame
  ;; (supercompressionScheme 2) is inflated to the raw blocks first.
  (define (ktx-uastc-level! k l dst)
    (let* ((lv (vector-ref ($ktx-lindex k) l))
           (off (+ ($ktx-base k) (vector-ref lv 0)))
           (clen (vector-ref lv 1))
           (ulen (vector-ref lv 2))
           (w (ktx-level-width k l))
           (h (ktx-level-height k l)))
      (if (= (ktx-scheme k) 2)
          (let* ((blocks (fx-alloc! ulen))
                 (scratch (fx-alloc! (+ ulen 65536))))
            (zstd-decode! off clen blocks scratch)
            (uastc-decode! blocks dst w h))
          (uastc-decode! off dst w h)))))
