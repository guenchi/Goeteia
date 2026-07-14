;; KTX2 + Basis Universal ETC1S/BasisLZ, from the specifications --
;; no C++ transcoder, no dependency.  A .ktx2 file lands in staging
;; memory (fetch or bytes), ktx-parse reads the container, and the
;; ETC1S decoder reconstructs the codebooks and slices entirely in
;; Scheme; transcoders then repack blocks for whatever the GPU
;; speaks: ETC1 (bit-identical repack), BC1, or plain RGBA8 -- the
;; universal fallback that needs no extension at all.
;;
;;   (define k (ktx-parse base len))
;;   (ktx-width k) (ktx-height k) (ktx-level-count k)
;;   (ktx-transcode! k level dst 'rgba)   ; | 'etc1 | 'bc1
;;
;; Verified block-for-block against the reference transcoder's
;; unpack output (test/ktx.ss carries golden pixels).
;;
;; Copyright (c) 2026 guenchi. MIT license; see LICENSE.
(library (gfx ktx)
  (export ktx-parse ktx? ktx-width ktx-height ktx-level-count
          ktx-scheme ktx-etc1s?
          ktx-level-width ktx-level-height
          ktx-transcode! ktx-transcode-bytes)
  (import (rnrs))

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

  (define (ktx-etc1s? k)
    (and (= (ktx-scheme k) 1) (= ($ktx-dfd-color k) 163)))

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
              (fill (make-vector 17 0)))
          (let put ((i 0))
            (when (< i n)
              (let ((l (vector-ref sizes i)))
                (when (> l 0)
                  (vector-set! syms (+ (vector-ref offs l)
                                       (vector-ref fill l))
                               i)
                  (vector-set! fill l (+ 1 (vector-ref fill l)))))
              (put (+ i 1))))
          (vector counts firsts syms offs)))))

  (define ($huff-decode b t)
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
                  (walk (+ l 1) code)))))))

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
         (else (error 'ktx "unknown format" fmt)))))))
