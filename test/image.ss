;; expect: #t
;; (gfx image): PNG decode and encode, TGA decode, and the DEFLATE
;; engine underneath them -- against files built here byte by byte, so
;; every assertion below is about a literal whose meaning is written
;; out beside it.  test/image-real.ss carries the same code against
;; real 512x512 assets.
(import (rnrs) (gfx image))

(let ((need (- 800000 (* 65536 (%mem-size)))))
  (when (> need 0) (%mem-grow (quotient (+ need 65535) 65536))))

;; ---- staging map (bytes) ----------------------------------------
(define SRC   8192)                     ; a fixture, as loaded
(define DST  65536)                     ; RGBA8 out of a decode
(define SCR 200000)                     ; filtered-scanline scratch
(define GEN 320000)                     ; pixels handed to the encoder
(define ENC 440000)                     ; the encoder's PNG
(define DST2 560000)                    ; RGBA8 out of decoding that
(define SCR2 680000)

(define (load! base bs)                 ; -> byte count
  (let put ((b bs) (i 0))
    (if (pair? b)
        (begin (%mem-u8-set! (+ base i) (car b)) (put (cdr b) (+ i 1)))
        i)))

(define fails '())

;; a check is a macro so the expression it names is evaluated inside a
;; guard: a decoder that raises names the check it broke instead of
;; taking the whole run down with an opaque trap
(define-syntax chk
  (syntax-rules ()
    ((_ name body)
     (let ((ok (guard (e ((error? e)
                          (display "  RAISED ") (display name)
                          (display ": ") (display (condition-message e))
                          (newline) #f)
                         (#t (display "  RAISED ") (display name)
                             (display " (non-condition)") (newline) #f))
                 body)))
       (unless ok
         (display "  FAIL ") (display name) (newline)
         (set! fails (cons name fails)))
       ok))))

;; the same shelter for a definition that runs the decoder before any
;; check can see it
(define (attempt thunk)
  (guard (e ((error? e)
             (display "  RAISED: ") (display (condition-message e))
             (newline) #f)
            (#t #f))
    (thunk)))

;; ---- the checksums, before anything that leans on them ----------
(chk "crc32 of \"IEND\""
     (let-values (((hi lo) (crc32 (bytevector 73 69 78 68) #f)))
       (and (= hi 44610) (= lo 24706))))     ; 0xAE426082
(chk "adler32 of \"abc\""
     (let-values (((hi lo) (adler32 (bytevector 97 98 99) #f)))
       (and (= hi 589) (= lo 295))))         ; 0x024D0127

(define (rgba base w x y)
  (let ((o (+ base (* 4 (+ (* y w) x)))))
    (list (%mem-u8-ref o) (%mem-u8-ref (+ o 1))
          (%mem-u8-ref (+ o 2)) (%mem-u8-ref (+ o 3)))))

;; compare the decoded image against a flat list of RGBA bytes
(define (pixels=? base want)
  (let loop ((w want) (i 0))
    (cond ((null? w) #t)
          ((= (%mem-u8-ref (+ base i)) (car w)) (loop (cdr w) (+ i 1)))
          (else (display "    byte ") (display i)
                (display ": got ") (display (%mem-u8-ref (+ base i)))
                (display " want ") (display (car w)) (newline)
                #f))))

(define (mem=? a b n)
  (let loop ((i 0))
    (cond ((= i n) #t)
          ((= (%mem-u8-ref (+ a i)) (%mem-u8-ref (+ b i))) (loop (+ i 1)))
          (else (display "    byte ") (display i) (display " differs")
                (newline) #f))))

;; `attempt' hands back #f when the library raised, and `=' on #f is
;; a trap no guard can catch -- so every numeric check on such a value
;; asks whether it is a number first
(define (num=? a b) (and (number? a) (= a b)))

;; the message of whatever the thunk raises -- a rejection has to be
;; named, not merely "an error happened"
(define (err-msg thunk)
  (guard (e ((error? e) (condition-message e))
            (#t "raised a non-condition"))
    (thunk)
    "no error raised"))

;; load a fixture, then report the message its decode raised
(define (msg-of bytes proc)
  (let ((n (load! SRC bytes)))
    (err-msg (lambda () (proc n)))))

;; ================= PNG: a 3x2 truecolour file =====================
;; Written out in full; the offsets in the comments are into the file.
;;   0..7    89 50 4E 47 0D 0A 1A 0A   the PNG signature
;;   8..11   00 00 00 0D               IHDR length = 13
;;  12..15   49 48 44 52               "IHDR"
;;  16..19   00 00 00 03               width  = 3
;;  20..23   00 00 00 02               height = 2
;;  24       08                        bit depth 8
;;  25       02                        colour type 2 (truecolour)
;;  26,27,28 00 00 00                  deflate / adaptive filtering / no interlace
;;  29..32   12 16 F1 4D               IHDR CRC32
;;  33..36   00 00 00 1F               IDAT length = 31
;;  37..40   49 44 41 54               "IDAT"
;;  41,42    78 01                     zlib: CM=8 CINFO=7, FCHECK so (78*256+01)%31=0
;;  43       01                        BFINAL=1, BTYPE=00 (stored)
;;  44,45    14 00                     LEN  = 20
;;  46,47    EB FF                     NLEN = ~LEN
;;  48..67   the 20 raw bytes: per row a filter byte 0 (None) then 3 RGB pixels
;;  68..71   47 6D 07 5A               zlib adler32 of those 20 bytes
;;  72..75   82 42 B6 7C               IDAT CRC32
;;  76..87   00 00 00 00 49 45 4E 44 AE 42 60 82   IEND, length 0
(define (fix-3x2)
  '(137 80 78 71 13 10 26 10 0 0 0 13
    73 72 68 82 0 0 0 3 0 0 0 2
    8 2 0 0 0 18 22 241 77 0 0 0
    31 73 68 65 84 120 1 1 20 0 235 255
    0 255 0 0 0 255 0 0 0 255 0 255
    255 0 0 255 255 16 32 48 71 109 7 90
    130 66 182 124 0 0 0 0 73 69 78 68
    174 66 96 130))

;; the six pixels, as RGBA8: row 0 red green blue, row 1 yellow cyan
;; and one arbitrary colour, every alpha opaque
(define (want-3x2)
  '(255 0 0 255   0 255 0 255   0 0 255 255
    255 255 0 255 0 255 255 255 16 32 48 255))

(define n3x2 (load! SRC (fix-3x2)))

(define info-3x2
  (attempt (lambda ()
             (let-values (((w h ch) (png-info SRC n3x2)))
               (list w h ch)))))

(define dec-3x2
  (attempt (lambda ()
             (let-values (((w h) (png-decode! SRC n3x2 DST SCR)))
               (list w h)))))

(chk "3x2 png-info" (equal? info-3x2 '(3 2 3)))
(chk "3x2 dimensions" (equal? dec-3x2 '(3 2)))
(chk "3x2 pixels" (pixels=? DST (want-3x2)))
(chk "3x2 pixel accessor" (equal? (rgba DST 3 2 1) '(16 32 48 255)))

;; the same file handed over as a bytevector rather than a staging
;; base -- same answer, which is the whole point of taking both
(define bv-3x2
  (let* ((bs (fix-3x2)) (bv (make-bytevector n3x2 0)))
    (let put ((b bs) (i 0))
      (when (pair? b)
        (bytevector-u8-set! bv i (car b))
        (put (cdr b) (+ i 1))))
    bv))

(define dec-3x2-bv
  (attempt (lambda ()
             (let-values (((w h) (png-decode! bv-3x2 #f DST2 SCR2)))
               (list w h)))))
(chk "3x2 from a bytevector" (and (equal? dec-3x2-bv '(3 2))
                                  (pixels=? DST2 (want-3x2))))

;; scratch left out: the decoder puts the filtered scanlines directly
;; above the RGBA output it is about to write
(define dec-3x2-nos
  (attempt (lambda ()
             (let-values (((w h) (png-decode! SRC n3x2 DST2)))
               (list w h)))))
(chk "decode with the default scratch placement"
     (and (equal? dec-3x2-nos '(3 2)) (pixels=? DST2 (want-3x2))))

;; the zlib stream of that same file, standing alone: the wrapper is
;; a public entry point, not only something png-decode! calls
(define (fix-zlib-3x2)
  '(120 1 1 20 0 235 255
    0 255 0 0 0 255 0 0 0 255
    0 255 255 0 0 255 255 16 32 48
    71 109 7 90))
(define (want-zlib-3x2)
  '(0 255 0 0 0 255 0 0 0 255
    0 255 255 0 0 255 255 16 32 48))
(define nz (load! SRC (fix-zlib-3x2)))
(define nz-out (attempt (lambda () (zlib-inflate! SRC nz DST 64))))
(chk "zlib-inflate! returns the raw length" (num=? nz-out 20))
(chk "zlib-inflate! bytes" (pixels=? DST (want-zlib-3x2)))
;; the trailer is checked, not skipped
(define nzbad (load! SRC (fix-zlib-3x2)))
(%mem-u8-set! (+ SRC 30) 91)            ; last adler byte was 90
(chk "zlib-inflate! rejects a wrong trailer"
     (string=? (err-msg (lambda () (zlib-inflate! SRC nzbad DST 64)))
               "zlib adler32 mismatch"))

;; the same 3x2 image whose zlib header is split across two one-byte
;; IDAT chunks -- legal PNG, and the reason the header is read through
;; the segment reader rather than at an absolute offset
(define (fix-split-header)
  '(137 80 78 71 13 10 26 10 0 0 0 13
    73 72 68 82 0 0 0 3 0 0 0 2
    8 2 0 0 0 18 22 241 77 0 0 0
    1 73 68 65 84 120 118 230 132 230 0 0
    0 1 73 68 65 84 1 95 63 77 126 0
    0 0 29 73 68 65 84 1 20 0 235 255
    0 255 0 0 0 255 0 0 0 255 0 255
    255 0 0 255 255 16 32 48 71 109 7 90
    80 12 45 73 0 0 0 0 73 69 78 68
    174 66 96 130))
(define nsh (load! SRC (fix-split-header)))
(define dec-sh
  (attempt (lambda ()
             (let-values (((w h) (png-decode! SRC nsh DST SCR)))
               (list w h)))))
(chk "zlib header split across one-byte IDATs"
     (and (equal? dec-sh '(3 2)) (pixels=? DST (want-3x2))))

;; ================= every scanline filter ==========================
;; 3 wide, 5 tall, truecolour; row y carries filter type y, so one
;; decode exercises None, Sub, Up, Average and Paeth.
(define (fix-filters)
  '(137 80 78 71 13 10 26 10 0 0 0 13
    73 72 68 82 0 0 0 3 0 0 0 5
    8 2 0 0 0 15 19 193 245 0 0 0
    61 73 68 65 84 120 1 1 50 0 205 255
    0 10 20 30 40 50 60 70 80 90 1 11
    22 33 33 33 33 33 33 33 2 189 128 67
    6 226 202 188 176 164 3 157 183 209 225 238
    245 255 0 1 4 4 88 172 5 5 132 192
    64 192 93 37 17 86 163 152 126 240 0 0
    0 0 73 69 78 68 174 66 96 130))

(define (want-filters)
  '(10 20 30 255   40 50 60 255   70 80 90 255
    11 22 33 255   44 55 66 255   77 88 99 255
    200 150 100 255 50 25 12 255  9 8 7 255
    1 2 3 255      250 251 252 255 128 129 130 255
    5 90 175 255   255 0 128 255  64 64 64 255))

(define nfil (load! SRC (fix-filters)))
(define dec-fil
  (attempt (lambda ()
             (let-values (((w h) (png-decode! SRC nfil DST SCR)))
               (list w h)))))
(chk "filters dimensions" (equal? dec-fil '(3 5)))
(chk "filters 0..4 by row" (pixels=? DST (want-filters)))

;; ================= Paeth, where the tie-break decides =============
;; The row above is chosen so that three pixels of the Paeth row hit
;; ties: at byte 3 the left and the upper-left predictors are equally
;; far (pa = pc = 10, pb = 20) and at byte 9 the same again, while at
;; byte 6 the upper and upper-left tie (pb = pc = 10, pa = 20).  The
;; specification's `<=' comparisons pick a and b there; a decoder
;; written with `<' picks c both times, and only these pixels can
;; tell the two apart.
;;   row 0  filter 0   5 6 7 | 8 9 10 | 11 12 13 | 14 15 16
;;   row 1  filter 0   100 200 30 | 90 150 40 | 70 20 210 | 60 5 250
;;   row 2  filter 4   120 33 44 | 100 55 66 | 90 77 88 | 99 111 122
(define (fix-paeth)
  '(137 80 78 71 13 10 26 10 0 0 0 13
    73 72 68 82 0 0 0 4 0 0 0 3
    8 2 0 0 0 59 150 57 145 0 0 0
    50 73 68 65 84 120 1 1 39 0 216 255
    0 5 6 7 8 9 10 11 12 13 14 15
    16 0 100 200 30 90 150 40 70 20 210 60
    5 250 4 20 89 14 236 22 22 20 57 134
    9 34 34 127 129 7 255 82 34 185 153 0
    0 0 0 73 69 78 68 174 66 96 130))

(define (want-paeth)
  '(5 6 7 255      8 9 10 255     11 12 13 255   14 15 16 255
    100 200 30 255 90 150 40 255  70 20 210 255  60 5 250 255
    120 33 44 255  100 55 66 255  90 77 88 255   99 111 122 255))

(define npae (load! SRC (fix-paeth)))
(define dec-pae
  (attempt (lambda ()
             (let-values (((w h) (png-decode! SRC npae DST SCR)))
               (list w h)))))
(chk "paeth fixture dimensions" (equal? dec-pae '(4 3)))
(chk "paeth tie-breaks follow the specification"
     (pixels=? DST (want-paeth)))

;; ================= palette with tRNS ==============================
;; PLTE holds four colours; tRNS gives the first three alphas 0, 128
;; and 255 and says nothing about the fourth, which is opaque by
;; default.  Row 1 runs the indices backwards.
(define (fix-palette)
  '(137 80 78 71 13 10 26 10 0 0 0 13
    73 72 68 82 0 0 0 4 0 0 0 2
    8 3 0 0 0 72 118 141 81 0 0 0
    12 80 76 84 69 255 0 0 0 255 0 0
    0 255 17 34 51 254 56 168 149 0 0 0
    3 116 82 78 83 0 128 255 236 247 179 24
    0 0 0 21 73 68 65 84 120 1 1 10
    0 245 255 0 0 1 2 3 0 3 2 1
    0 0 70 0 13 141 163 154 25 0 0 0
    0 73 69 78 68 174 66 96 130))

(define (want-palette)
  '(255 0 0 0     0 255 0 128   0 0 255 255   17 34 51 255
    17 34 51 255  0 0 255 255   0 255 0 128   255 0 0 0))

(define npal (load! SRC (fix-palette)))
(define dec-pal
  (attempt (lambda ()
             (let-values (((w h) (png-decode! SRC npal DST SCR)))
               (list w h)))))
(chk "palette dimensions" (equal? dec-pal '(4 2)))
(chk "palette + tRNS" (pixels=? DST (want-palette)))
(chk "palette png-info channels"
     (let-values (((w h ch) (png-info SRC npal))) (= ch 1)))

;; ================= greyscale, greyscale+alpha, RGBA ===============
;; grey with tRNS naming the value 200 as transparent
(define (fix-grey)
  '(137 80 78 71 13 10 26 10 0 0 0 13
    73 72 68 82 0 0 0 4 0 0 0 1
    8 0 0 0 0 220 87 80 17 0 0 0
    2 116 82 78 83 0 200 227 44 135 186 0
    0 0 16 73 68 65 84 120 1 1 5 0
    250 255 0 10 200 90 255 4 56 2 44 185
    3 107 98 0 0 0 0 73 69 78 68 174
    66 96 130))
(define (want-grey)
  '(10 10 10 255   200 200 200 0   90 90 90 255   255 255 255 255))

(define ngrey (load! SRC (fix-grey)))
(define dec-grey
  (attempt (lambda ()
             (let-values (((w h) (png-decode! SRC ngrey DST SCR)))
               (list w h)))))
(chk "grey dimensions" (equal? dec-grey '(4 1)))
(chk "grey + tRNS" (pixels=? DST (want-grey)))

(define (fix-grey-alpha)
  '(137 80 78 71 13 10 26 10 0 0 0 13
    73 72 68 82 0 0 0 2 0 0 0 2
    8 4 0 0 0 216 191 197 175 0 0 0
    21 73 68 65 84 120 1 1 10 0 245 255
    0 10 255 20 0 0 30 128 40 64 11 112
    2 36 176 48 67 229 0 0 0 0 73 69
    78 68 174 66 96 130))
(define (want-grey-alpha)
  '(10 10 10 255   20 20 20 0
    30 30 30 128   40 40 40 64))

(define nga (load! SRC (fix-grey-alpha)))
(chk "grey+alpha"
     (let-values (((w h) (png-decode! SRC nga DST SCR)))
       (and (= w 2) (= h 2) (pixels=? DST (want-grey-alpha)))))

(define (fix-rgba)
  '(137 80 78 71 13 10 26 10 0 0 0 13
    73 72 68 82 0 0 0 2 0 0 0 2
    8 6 0 0 0 114 182 13 36 0 0 0
    29 73 68 65 84 120 1 1 18 0 237 255
    0 1 2 3 4 5 6 7 8 0 9 10
    11 12 250 251 252 253 12 168 4 61 9 235
    133 81 0 0 0 0 73 69 78 68 174 66
    96 130))
(define (want-rgba) '(1 2 3 4  5 6 7 8  9 10 11 12  250 251 252 253))

(define nrgba (load! SRC (fix-rgba)))
(chk "rgba passes through"
     (let-values (((w h) (png-decode! SRC nrgba DST SCR)))
       (and (= w 2) (= h 2) (pixels=? DST (want-rgba)))))

;; ================= dynamic Huffman, IDAT split in two =============
;; zlib -9 chose a dynamic block for this 24x8 image, and the stream
;; is cut in half across two IDAT chunks: the inflate reader has to
;; walk off the end of the first chunk mid-symbol and pick up in the
;; second.
(define (fix-dyn)
  '(137 80 78 71 13 10 26 10 0 0 0 13
    73 72 68 82 0 0 0 24 0 0 0 8
    8 2 0 0 0 108 195 168 52 0 0 0
    36 73 68 65 84 120 218 173 208 177 21 0
    65 4 64 193 143 64 168 4 165 40 77 123
    202 186 119 219 2 217 196 3 226 147 145 227
    178 19 230 165 211 105 16 24 46 0 0 0
    36 73 68 65 84 163 229 59 145 69 168 104
    80 75 13 214 225 209 182 20 106 41 93 45
    105 59 113 240 252 196 193 243 19 23 207 191
    62 240 164 101 59 189 48 211 16 0 0 0
    0 73 69 78 68 174 66 96 130))

(define ndyn (load! SRC (fix-dyn)))
(define dec-dyn
  (attempt (lambda ()
             (let-values (((w h) (png-decode! SRC ndyn DST SCR)))
               (list w h)))))
(chk "dynamic huffman dimensions" (equal? dec-dyn '(24 8)))
(chk "dynamic huffman corner pixels"
     (and (equal? (rgba DST 24 0 0) '(0 1 7 255))
          (equal? (rgba DST 24 23 7) '(2 1 2 255))
          (equal? (rgba DST 24 11 3) '(127 15 7 255))
          (equal? (rgba DST 24 5 1) '(127 200 2 255))))

;; FNV-1a over the whole RGBA buffer, carried as two 16-bit halves
;; because a 32-bit product cannot go through a bitwise operator here
(define (fnv base len)
  (let loop ((i 0) (hi 33052) (lo 40389))    ; 0x811C9DC5
    (if (= i len)
        (list hi lo)
        (let* ((lo (bitwise-xor lo (%mem-u8-ref (+ base i))))
               (t (* lo 403))                ; prime 0x01000193 = 256*65536+403
               (rlo (remainder t 65536))
               (carry (quotient t 65536))
               (rhi (remainder (+ (* lo 256) (* hi 403) carry) 65536)))
          (loop (+ i 1) rhi rlo)))))

(chk "dynamic huffman whole-image hash"
     (equal? (fnv DST (* 24 8 4)) '(45982 21413)))

;; ================= DEFLATE across a block boundary ================
;; Two fixed-Huffman blocks written by hand.  Block 1 is eight
;; literals; block 2 is BFINAL and opens with a <length 8, distance 8>
;; back-reference that reaches into block 1's output, then a second
;; one that overlaps what it has just written, then a literal.
(define (fix-two-blocks)
  '(114 116 114 118 113 117 115 247 0 12 70 195 232 40 0))

(define (want-two-blocks)               ; "ABCDEFGHABCDEFGHABCDEFGHZ"
  '(65 66 67 68 69 70 71 72
    65 66 67 68 69 70 71 72
    65 66 67 68 69 70 71 72 90))

(define ntb (load! SRC (fix-two-blocks)))
(define ntb-out (attempt (lambda () (inflate! SRC ntb DST 64))))
(chk "cross-block back-reference length" (num=? ntb-out 25))
(chk "cross-block back-reference bytes" (pixels=? DST (want-two-blocks)))

;; a stored block on its own, and the same one with its NLEN field
;; corrupted: LEN and ~LEN are a redundant pair and the decoder is
;; meant to notice when they disagree
;;   byte 0   01        BFINAL=1, BTYPE=00 (stored); the rest of the
;;                      byte is discarded when the reader realigns
;;   1,2      04 00     LEN  = 4
;;   3,4      FB FF     NLEN = 65531; LEN + NLEN = 65535
;;   5..8     41 42 43 44   "ABCD"
(define (fix-stored) '(1 4 0 251 255 65 66 67 68))
(define nst (load! SRC (fix-stored)))
(define nst-out (attempt (lambda () (inflate! SRC nst DST 64))))
(chk "a bare stored block inflates"
     (and (num=? nst-out 4) (pixels=? DST '(65 66 67 68))))

(define (fix-stored-bad-nlen) '(1 4 0 250 255 65 66 67 68))
(chk "a stored block with a wrong NLEN is refused by name"
     (string=? (msg-of (fix-stored-bad-nlen)
                       (lambda (n) (inflate! SRC n DST 64)))
               "stored block length mismatch"))

;; ================= encode, then decode again ======================
;; A stored-block PNG is still a PNG: what comes back has to be what
;; went in, byte for byte.
(define nfil2 (load! SRC (fix-filters)))
(attempt (lambda ()
           (let-values (((w h) (png-decode! SRC nfil2 DST SCR)))
             (list w h))))

(define enc-n (attempt (lambda () (png-encode! DST 3 5 4 ENC))))
(chk "png-encode-size agrees with png-encode!"
     (num=? enc-n (png-encode-size 3 5 4)))
(chk "round trip 3x5 rgba"
     (let-values (((w h) (png-decode! ENC enc-n DST2 SCR2)))
       (and (= w 3) (= h 5) (pixels=? DST2 (want-filters)))))

;; the same pixels as 3-channel input: alpha comes back opaque
(define (pack-rgb! from to n)
  (let loop ((i 0))
    (when (< i n)
      (%mem-u8-set! (+ to (* i 3)) (%mem-u8-ref (+ from (* i 4))))
      (%mem-u8-set! (+ to (* i 3) 1) (%mem-u8-ref (+ from (* i 4) 1)))
      (%mem-u8-set! (+ to (* i 3) 2) (%mem-u8-ref (+ from (* i 4) 2)))
      (loop (+ i 1)))))
(pack-rgb! DST GEN 15)
(define enc3-n (attempt (lambda () (png-encode! GEN 3 5 3 ENC))))
(chk "round trip 3x5 rgb"
     (and (num=? enc3-n (png-encode-size 3 5 3))
          (let-values (((w h) (png-decode! ENC enc3-n DST2 SCR2)))
            (and (= w 3) (= h 5) (pixels=? DST2 (want-filters))))))

;; 200x120 RGBA: 96120 raw bytes, so the encoder has to emit more than
;; one stored block and get the BFINAL flag on the right one
(define BW 200)
(define BH 120)
(define (fill-gradient!)
  (let row ((y 0))
    (when (< y BH)
      (let col ((x 0))
        (when (< x BW)
          (let ((o (+ GEN (* 4 (+ (* y BW) x)))))
            (%mem-u8-set! o (remainder (* x 3) 256))
            (%mem-u8-set! (+ o 1) (remainder (* y 5) 256))
            (%mem-u8-set! (+ o 2) (remainder (+ x y) 256))
            (%mem-u8-set! (+ o 3) (remainder (+ (* x 7) (* y 11)) 256)))
          (col (+ x 1))))
      (row (+ y 1)))))
(fill-gradient!)
(define big-n (attempt (lambda () (png-encode! GEN BW BH 4 ENC))))
(chk "multi-block encode size" (num=? big-n (png-encode-size BW BH 4)))
(chk "round trip 200x120 rgba"
     (let-values (((w h) (png-decode! ENC big-n DST2 SCR2)))
       (and (= w BW) (= h BH) (mem=? GEN DST2 (* BW BH 4)))))

;; the encoder refuses a buffer that cannot hold the file
(chk "encode into a short buffer is refused"
     (string=? (err-msg (lambda () (png-encode! GEN BW BH 4 ENC 100)))
               "PNG output buffer is too small"))

;; ================= named rejections ===============================
;; a byte flipped inside IDAT's payload: the chunk CRC catches it
(define nbad (load! SRC (fix-3x2)))
(%mem-u8-set! (+ SRC 48) 254)           ; was 0, the first filter byte
(chk "bad chunk CRC"
     (string=? (err-msg (lambda () (png-decode! SRC nbad DST SCR)))
               "bad PNG chunk CRC"))

;; the same file cut short
(define ncut (load! SRC (fix-3x2)))
(chk "truncated file"
     (string=? (err-msg (lambda () (png-decode! SRC 40 DST SCR)))
               "truncated PNG chunk"))

;; correct CRCs everywhere, but shapes this decoder does not do
(define (fix-interlaced)
  '(137 80 78 71 13 10 26 10 0 0 0 13
    73 72 68 82 0 0 0 4 0 0 0 4
    8 2 0 0 1 81 148 57 191 0 0 0
    27 73 68 65 84 120 1 1 16 0 239 255
    0 0 10 20 0 0 10 20 0 0 10 20
    0 0 10 20 3 128 0 121 115 191 13 222
    0 0 0 0 73 69 78 68 174 66 96 130))
(chk "interlaced PNG is refused by name"
     (string=? (msg-of (fix-interlaced)
                       (lambda (n) (png-decode! SRC n DST SCR)))
               "interlaced PNG (Adam7) is not supported"))

(define (fix-16bit)
  '(137 80 78 71 13 10 26 10 0 0 0 13
    73 72 68 82 0 0 0 2 0 0 0 2
    16 2 0 0 0 173 68 70 48 0 0 0
    37 73 68 65 84 120 1 1 26 0 229 255
    0 1 2 3 4 5 6 7 8 9 10 11
    12 0 1 2 3 4 5 6 7 8 9 10
    11 12 6 232 0 157 17 68 240 103 0 0
    0 0 73 69 78 68 174 66 96 130))
(chk "16-bit PNG is refused by name"
     (string=? (msg-of (fix-16bit)
                       (lambda (n) (png-decode! SRC n DST SCR)))
               "16-bit PNG samples are not supported"))

(define (fix-4bit)
  '(137 80 78 71 13 10 26 10 0 0 0 13
    73 72 68 82 0 0 0 4 0 0 0 1
    4 3 0 0 0 11 18 18 254 0 0 0
    6 80 76 84 69 1 2 3 4 5 6 149
    83 111 72 0 0 0 14 73 68 65 84 120
    1 1 3 0 252 255 0 1 16 0 21 0
    18 157 174 63 197 0 0 0 0 73 69 78
    68 174 66 96 130))
(chk "sub-byte PNG is refused by name"
     (string=? (msg-of (fix-4bit)
                       (lambda (n) (png-decode! SRC n DST SCR)))
               "sub-byte PNG samples are not supported"))

;; every chunk CRC correct, the zlib trailer wrong: the checksum
;; inside the compressed stream is checked too, not just around it
(define (fix-bad-adler)
  '(137 80 78 71 13 10 26 10 0 0 0 13
    73 72 68 82 0 0 0 3 0 0 0 2
    8 2 0 0 0 18 22 241 77 0 0 0
    31 73 68 65 84 120 1 1 20 0 235 255
    0 255 0 0 0 255 0 0 0 255 0 255
    255 0 0 255 255 16 32 48 71 109 7 91
    245 69 134 234 0 0 0 0 73 69 78 68
    174 66 96 130))
(chk "wrong zlib adler32 is refused by name"
     (string=? (msg-of (fix-bad-adler)
                       (lambda (n) (png-decode! SRC n DST SCR)))
               "zlib adler32 mismatch"))

;; a scratch region too small for the scanlines is named, not silently
;; overrun
(define nsc (load! SRC (fix-filters)))
(chk "short scanline scratch is refused"
     (string=? (err-msg (lambda () (png-decode! SRC nsc DST SCR 10)))
               "PNG scanline scratch is too small"))

;; not a PNG at all
(chk "a non-PNG is refused"
     (string=? (msg-of '(1 2 3 4 5 6 7 8 9 10 11 12)
                       (lambda (n) (png-info SRC n)))
               "not a PNG file"))

;; ================= TGA ============================================
;; type 2, 24-bit, descriptor 0 -> origin bottom-left, so the file's
;; first row is the image's LAST row
(define (fix-tga2)
  '(0 0 2 0 0 0 0 0 0 0 0 0
    3 0 2 0 24 0 0 0 255 0 255 0
    255 0 0 30 20 10 60 50 40 90 80 70))
(define (want-tga2)
  '(10 20 30 255  40 50 60 255  70 80 90 255
    255 0 0 255   0 255 0 255   0 0 255 255))

(define nt2 (load! SRC (fix-tga2)))
(chk "tga type 2 info"
     (let-values (((w h bpp tp) (tga-info SRC nt2)))
       (equal? (list w h bpp tp) '(3 2 24 2))))
(chk "tga type 2, bottom-left origin"
     (let-values (((w h) (tga-decode! SRC nt2 DST)))
       (and (= w 3) (= h 2) (pixels=? DST (want-tga2)))))

;; type 2, 32-bit, descriptor 0x20 -> origin top-left, no flip
(define (fix-tga2-32)
  '(0 0 2 0 0 0 0 0 0 0 0 0
    2 0 2 0 32 32 3 2 1 4 7 6
    5 8 11 10 9 12 252 251 250 253))
(define (want-tga2-32)
  '(1 2 3 4  5 6 7 8  9 10 11 12  250 251 252 253))

(define nt2b (load! SRC (fix-tga2-32)))
(chk "tga type 2, 32-bit, top-left origin"
     (let-values (((w h) (tga-decode! SRC nt2b DST)))
       (and (= w 2) (= h 2) (pixels=? DST (want-tga2-32)))))
(chk "tga 32-bit info"
     (let-values (((w h bpp tp) (tga-info SRC nt2b)))
       (equal? (list w h bpp tp) '(2 2 32 2))))

;; type 10, run-length: a run of five pixels that crosses the row
;; boundary, then a three-pixel raw packet; origin bottom-left
(define (fix-tga10)
  '(0 0 10 0 0 0 0 0 0 0 0 0
    4 0 2 0 24 0 132 9 9 9 2 50
    100 200 3 2 1 253 254 255))
(define (want-tga10)
  ;; file order is P P P P P Q R S; with the bottom-left origin the
  ;; first four land in output row 1 and the rest in row 0
  '(9 9 9 255      200 100 50 255  1 2 3 255      255 254 253 255
    9 9 9 255      9 9 9 255       9 9 9 255      9 9 9 255))

(define nt10 (load! SRC (fix-tga10)))
(chk "tga type 10 info"
     (let-values (((w h bpp tp) (tga-info SRC nt10)))
       (equal? (list w h bpp tp) '(4 2 24 10))))
(chk "tga type 10, run across the row boundary"
     (let-values (((w h) (tga-decode! SRC nt10 DST)))
       (and (= w 4) (= h 2) (pixels=? DST (want-tga10)))))

;; type 10, 32-bit, descriptor 0x30 -> top-left AND right-to-left
(define (fix-tga10-32)
  '(0 0 10 0 0 0 0 0 0 0 0 0
    2 0 2 0 32 48 129 33 22 11 44 1
    77 66 55 88 101 100 99 102))
(define (want-tga10-32)
  ;; file order A A B C; each row is written right to left
  '(11 22 33 44   11 22 33 44
    99 100 101 102 55 66 77 88))

(define nt10b (load! SRC (fix-tga10-32)))
(chk "tga type 10, top-left + right-to-left"
     (let-values (((w h) (tga-decode! SRC nt10b DST)))
       (and (= w 2) (= h 2) (pixels=? DST (want-tga10-32)))))

;; shapes TGA support stops at, by name
(chk "colour-mapped TGA is refused by name"
     (string=? (msg-of '(0 1 1 0 0 2 0 24 0 0 0 0 2 0 2 0 8 0)
                       (lambda (n) (tga-info SRC n)))
               "colour-mapped TGA is not supported"))
(chk "greyscale TGA is refused by name"
     (string=? (msg-of '(0 0 3 0 0 0 0 0 0 0 0 0 2 0 2 0 8 0)
                       (lambda (n) (tga-info SRC n)))
               "only truecolour TGA (type 2 or 10) is supported"))
(chk "16-bit TGA is refused by name"
     (string=? (msg-of '(0 0 2 0 0 0 0 0 0 0 0 0 2 0 2 0 16 0)
                       (lambda (n) (tga-info SRC n)))
               "only 24- or 32-bit TGA pixels are supported"))

(null? fails)
