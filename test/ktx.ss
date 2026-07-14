;; expect: #t
;; (gfx ktx): the KTX2 container and the ETC1S/BasisLZ decoder
;; against a real basisu-encoded file, pixel goldens from the
;; reference transcoder's unpack.
(import (rnrs) (gfx ktx))

;; test16.ktx2 (590 bytes): basisu -ktx2 -mipmap of a 16x16 gradient/checker
(define ktx2-bytes
 '(171 75 84 88 32 50 48 187 13 10 26 10 0 0 0 0
  1 0 0 0 16 0 0 0 16 0 0 0 0 0 0 0
  0 0 0 0 1 0 0 0 5 0 0 0 1 0 0 0
  200 0 0 0 44 0 0 0 244 0 0 0 36 0 0 0
  24 1 0 0 0 0 0 0 41 1 0 0 0 0 0 0
  71 2 0 0 0 0 0 0 7 0 0 0 0 0 0 0
  0 0 0 0 0 0 0 0 68 2 0 0 0 0 0 0
  3 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
  67 2 0 0 0 0 0 0 1 0 0 0 0 0 0 0
  0 0 0 0 0 0 0 0 66 2 0 0 0 0 0 0
  1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
  65 2 0 0 0 0 0 0 1 0 0 0 0 0 0 0
  0 0 0 0 0 0 0 0 44 0 0 0 0 0 0 0
  2 0 40 0 163 1 2 0 3 3 0 0 8 0 0 0
  0 0 0 0 0 0 63 0 0 0 0 0 0 0 0 0
  255 255 255 255 31 0 0 0 75 84 88 119 114 105 116 101
  114 0 66 97 115 105 115 32 85 110 105 118 101 114 115 97
  108 32 50 46 49 48 0 0 23 0 12 0 75 0 0 0
  49 0 0 0 53 0 0 0 0 0 0 0 0 0 0 0
  0 0 0 0 7 0 0 0 0 0 0 0 0 0 0 0
  0 0 0 0 0 0 0 0 3 0 0 0 0 0 0 0
  0 0 0 0 0 0 0 0 0 0 0 0 1 0 0 0
  0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
  1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
  0 0 0 0 1 0 0 0 0 0 0 0 0 0 0 0
  28 64 20 128 1 0 0 65 216 35 38 152 245 21 192 20
  128 1 0 134 97 24 102 152 194 107 151 0 162 0 12 0
  0 8 131 48 176 23 138 7 192 20 0 0 0 0 64 16
  68 13 237 238 11 10 13 45 8 69 163 13 71 81 180 112
  40 20 190 170 240 165 168 222 182 143 3 4 240 247 247 7
  168 84 255 7 170 84 255 7 170 212 255 135 42 85 253 7
  160 74 245 7 128 74 245 7 160 74 255 47 133 82 253 55
  133 82 253 7 2 40 213 175 170 170 170 2 0 193 68 0
  0 0 0 0 0 242 95 237 2 152 19 0 0 0 0 4
  192 172 129 135 38 224 109 131 0 0 128 48 4 27 47 22
  150 142 16 55 201 1 48 3 0 0 0 0 0 128 28 32
  0 30 150 230 106 64 61 34 192 89 163 21 2 0))

;; level 0 golden RGBA (reference transcoder ETC1 unpack)
(define golden-l0
 '(7 7 16 255 7 7 16 255 7 7 16 255 7 7 16 255
  73 7 238 255 73 7 238 255 73 7 238 255 73 7 238 255
  139 7 16 255 139 7 16 255 139 7 16 255 139 7 16 255
  214 7 238 255 214 7 238 255 214 7 238 255 214 7 238 255
  19 19 28 255 19 19 28 255 19 19 28 255 29 29 38 255
  85 19 250 255 85 19 250 255 85 19 250 255 95 29 255 255
  151 19 28 255 151 19 28 255 151 19 28 255 161 29 38 255
  226 19 250 255 226 19 250 255 226 19 250 255 236 29 255 255
  29 29 38 255 29 29 38 255 29 29 38 255 41 41 50 255
  95 29 255 255 95 29 255 255 95 29 255 255 107 41 255 255
  161 29 38 255 161 29 38 255 161 29 38 255 173 41 50 255
  236 29 255 255 236 29 255 255 236 29 255 255 248 41 255 255
  41 41 50 255 41 41 50 255 41 41 50 255 41 41 50 255
  107 41 255 255 107 41 255 255 107 41 255 255 107 41 255 255
  173 41 50 255 173 41 50 255 173 41 50 255 173 41 50 255
  248 41 255 255 248 41 255 255 248 41 255 255 248 41 255 255
  7 73 238 255 7 73 238 255 7 73 238 255 7 73 238 255
  73 73 16 255 73 73 16 255 73 73 16 255 73 73 16 255
  139 73 238 255 139 73 238 255 139 73 238 255 139 73 238 255
  214 73 16 255 214 73 16 255 214 73 16 255 214 73 16 255
  19 85 250 255 19 85 250 255 19 85 250 255 29 95 255 255
  85 85 28 255 85 85 28 255 85 85 28 255 95 95 38 255
  151 85 250 255 151 85 250 255 151 85 250 255 161 95 255 255
  226 85 28 255 226 85 28 255 226 85 28 255 236 95 38 255
  29 95 255 255 29 95 255 255 29 95 255 255 41 107 255 255
  95 95 38 255 95 95 38 255 95 95 38 255 107 107 50 255
  161 95 255 255 161 95 255 255 161 95 255 255 173 107 255 255
  236 95 38 255 236 95 38 255 236 95 38 255 248 107 50 255
  41 107 255 255 41 107 255 255 41 107 255 255 41 107 255 255
  107 107 50 255 107 107 50 255 107 107 50 255 107 107 50 255
  173 107 255 255 173 107 255 255 173 107 255 255 173 107 255 255
  248 107 50 255 248 107 50 255 248 107 50 255 248 107 50 255
  7 148 16 255 7 148 16 255 7 148 16 255 7 148 16 255
  82 148 238 255 82 148 238 255 82 148 238 255 82 148 238 255
  148 148 16 255 148 148 16 255 148 148 16 255 148 148 16 255
  214 148 238 255 214 148 238 255 214 148 238 255 214 148 238 255
  19 160 28 255 19 160 28 255 19 160 28 255 29 170 38 255
  94 160 250 255 94 160 250 255 94 160 250 255 104 170 255 255
  160 160 28 255 160 160 28 255 160 160 28 255 170 170 38 255
  226 160 250 255 226 160 250 255 226 160 250 255 236 170 255 255
  29 170 38 255 29 170 38 255 29 170 38 255 41 182 50 255
  104 170 255 255 104 170 255 255 104 170 255 255 116 182 255 255
  170 170 38 255 170 170 38 255 170 170 38 255 182 182 50 255
  236 170 255 255 236 170 255 255 236 170 255 255 248 182 255 255
  41 182 50 255 41 182 50 255 41 182 50 255 41 182 50 255
  116 182 255 255 116 182 255 255 116 182 255 255 116 182 255 255
  182 182 50 255 182 182 50 255 182 182 50 255 182 182 50 255
  248 182 255 255 248 182 255 255 248 182 255 255 248 182 255 255
  7 214 238 255 7 214 238 255 7 214 238 255 7 214 238 255
  82 214 16 255 82 214 16 255 82 214 16 255 82 214 16 255
  148 214 238 255 148 214 238 255 148 214 238 255 148 214 238 255
  214 214 16 255 214 214 16 255 214 214 16 255 214 214 16 255
  19 226 250 255 19 226 250 255 19 226 250 255 29 236 255 255
  94 226 28 255 94 226 28 255 94 226 28 255 104 236 38 255
  160 226 250 255 160 226 250 255 160 226 250 255 170 236 255 255
  226 226 28 255 226 226 28 255 226 226 28 255 236 236 38 255
  29 236 255 255 29 236 255 255 29 236 255 255 41 248 255 255
  104 236 38 255 104 236 38 255 104 236 38 255 116 248 50 255
  170 236 255 255 170 236 255 255 170 236 255 255 182 248 255 255
  236 236 38 255 236 236 38 255 236 236 38 255 248 248 50 255
  41 248 255 255 41 248 255 255 41 248 255 255 41 248 255 255
  116 248 50 255 116 248 50 255 116 248 50 255 116 248 50 255
  182 248 255 255 182 248 255 255 182 248 255 255 182 248 255 255
  248 248 50 255 248 248 50 255 248 248 50 255 248 248 50 255))

;; level 1 golden RGBA (reference transcoder ETC1 unpack)
(define golden-l1
 '(79 79 169 255 53 53 143 255 79 79 169 255 79 79 169 255
  202 79 169 255 176 53 143 255 202 79 169 255 202 79 169 255
  24 24 114 255 24 24 114 255 53 53 143 255 53 53 143 255
  147 24 114 255 147 24 114 255 176 53 143 255 176 53 143 255
  79 79 169 255 79 79 169 255 79 79 169 255 79 79 169 255
  202 79 169 255 202 79 169 255 202 79 169 255 202 79 169 255
  108 108 198 255 108 108 198 255 108 108 198 255 108 108 198 255
  231 108 198 255 231 108 198 255 231 108 198 255 231 108 198 255
  24 147 114 255 24 147 114 255 53 176 143 255 53 176 143 255
  147 147 114 255 147 147 114 255 176 176 143 255 176 176 143 255
  53 176 143 255 53 176 143 255 79 202 169 255 79 202 169 255
  176 176 143 255 176 176 143 255 202 202 169 255 202 202 169 255
  79 202 169 255 79 202 169 255 79 202 169 255 79 202 169 255
  202 202 169 255 202 202 169 255 202 202 169 255 202 202 169 255
  108 231 198 255 108 231 198 255 108 231 198 255 108 231 198 255
  231 231 198 255 231 231 198 255 231 231 198 255 231 231 198 255))

;; level 2 golden RGBA (reference transcoder ETC1 unpack)
(define golden-l2
 '(127 127 152 255 127 127 152 255 127 127 152 255 147 147 172 255
  127 127 152 255 127 127 152 255 127 127 152 255 127 127 152 255
  147 147 172 255 147 147 172 255 165 165 190 255 165 165 190 255
  165 165 190 255 165 165 190 255 185 185 210 255 185 185 210 255))

;; level 3 golden RGBA (reference transcoder ETC1 unpack)
(define golden-l3
 '(127 127 152 255 127 127 152 255 165 165 190 255 185 185 210 255))

;; level 4 golden RGBA (reference transcoder ETC1 unpack)
(define golden-l4
 '(154 154 187 255))

;; the file into staging
(define BASE 8192)
(let put ((bs ktx2-bytes) (i 0))
  (when (pair? bs)
    (%mem-u8-set! (+ BASE i) (car bs))
    (put (cdr bs) (+ i 1))))

(define k (ktx-parse BASE 590))

(define container-ok
  (and (ktx? k)
       (= (ktx-width k) 16)
       (= (ktx-height k) 16)
       (= (ktx-level-count k) 5)
       (= (ktx-scheme k) 1)
       (ktx-etc1s? k)
       (= (ktx-level-width k 0) 16)
       (= (ktx-level-width k 1) 8)
       (= (ktx-level-width k 4) 1)
       (= (ktx-level-height k 3) 2)
       (= (ktx-transcode-bytes k 0 'rgba) 1024)
       (= (ktx-transcode-bytes k 0 'etc1) 128)
       (= (ktx-transcode-bytes k 1 'bc1) 32)))


;; ---- RGBA transcode vs the reference transcoder, bit for bit ----
(define DST 16384)
(define (check-level l golden)
  (ktx-transcode! k l DST 'rgba)
  (let loop ((gs golden) (i 0) (bad 0))
    (if (null? gs)
        (begin
          (when (> bad 0)
            (display "level ") (display l) (display ": ")
            (display bad) (display " bytes differ") (newline))
          (= bad 0))
        (loop (cdr gs) (+ i 1)
              (if (= (%mem-u8-ref (+ DST i)) (car gs))
                  bad
                  (+ bad 1))))))

(define rgba-ok
  (let ((ok0 (check-level 0 golden-l0))
        (ok1 (check-level 1 golden-l1))
        (ok2 (check-level 2 golden-l2))
        (ok3 (check-level 3 golden-l3))
        (ok4 (check-level 4 golden-l4)))
    (and ok0 ok1 ok2 ok3 ok4)))


;; ---- ETC1 repack: decode our packed blocks by the ETC1 spec and
;; compare against the same goldens ----
(define etc1-sel->basis '#(2 3 1 0))     ; raw ETC1 -> logical
(define inten-tabs
  '#(#(-8 -2 2 8) #(-17 -5 5 17) #(-29 -9 9 29) #(-42 -13 13 42)
     #(-60 -18 18 60) #(-80 -24 24 80) #(-106 -33 33 106)
     #(-183 -47 47 183)))
(define (x5 v) (+ (* v 8) (quotient v 4)))
(define (cl8 v) (if (< v 0) 0 (if (> v 255) 255 v)))
(define (etc1-check l golden w h)
  (ktx-transcode! k l DST 'etc1)
  (let* ((nbx (quotient (+ w 3) 4))
         (gref (list->vector golden)))
    (let blocks ((bi 0) (ok #t))
      (if (= bi (* nbx (quotient (+ h 3) 4)))
          ok
          (let* ((at (+ DST (* bi 8)))
                 (bx (remainder bi nbx))
                 (by (quotient bi nbx))
                 (r (x5 (quotient (%mem-u8-ref at) 8)))
                 (g (x5 (quotient (%mem-u8-ref (+ at 1)) 8)))
                 (b (x5 (quotient (%mem-u8-ref (+ at 2)) 8)))
                 (b3 (%mem-u8-ref (+ at 3)))
                 (tab (vector-ref inten-tabs (remainder b3 8))))
            (let px ((x 0) (ok ok))
              (if (= x 4)
                  (blocks (+ bi 1) ok)
                  (let py ((y 0) (ok ok))
                    (if (= y 4)
                        (px (+ x 1) ok)
                        (let* ((gx (+ (* bx 4) x)) (gy (+ (* by 4) y)))
                          (if (or (>= gx w) (>= gy h))
                              (py (+ y 1) ok)
                              (let* ((bit (+ (* x 4) y))
                                     (bo (- 7 (quotient bit 8)))
                                     (sh (remainder bit 8))
                                     (lsb (remainder
                                           (bitwise-arithmetic-shift-right
                                            (%mem-u8-ref (+ at bo)) sh)
                                           2))
                                     (msb (remainder
                                           (bitwise-arithmetic-shift-right
                                            (%mem-u8-ref (+ at bo -2)) sh)
                                           2))
                                     (raw (+ (* msb 2) lsb))
                                     (s (vector-ref etc1-sel->basis raw))
                                     (m (vector-ref tab s))
                                     (gi (* (+ (* gy w) gx) 4)))
                                (py (+ y 1)
                                    (and ok
                                         (= (cl8 (+ r m))
                                            (vector-ref gref gi))
                                         (= (cl8 (+ g m))
                                            (vector-ref gref (+ gi 1)))
                                         (= (cl8 (+ b m))
                                            (vector-ref gref (+ gi 2)))))))))))))))))
(define etc1-ok
  (and (etc1-check 0 golden-l0 16 16)
       (etc1-check 1 golden-l1 8 8)
       (etc1-check 4 golden-l4 1 1)))

;; ---- BC1: decode by the BC1 spec, compare within transcode
;; tolerance (our simple path trades a little PSNR for no tables) ----
(define (bc1-check l golden w h tol)
  (ktx-transcode! k l DST 'bc1)
  (let* ((nbx (quotient (+ w 3) 4))
         (gref (list->vector golden))
         (c565 (lambda (v)
                 (vector (quotient (* (quotient v 2048) 255) 31)
                         (quotient (* (remainder (quotient v 32) 64)
                                      255) 63)
                         (quotient (* (remainder v 32) 255) 31)))))
    (let blocks ((bi 0) (worst 0))
      (if (= bi (* nbx (quotient (+ h 3) 4)))
          (begin
            (when (> worst tol)
              (display "bc1 worst diff ") (display worst) (newline))
            (<= worst tol))
          (let* ((at (+ DST (* bi 8)))
                 (bx (remainder bi nbx)) (by (quotient bi nbx))
                 (c0v (+ (%mem-u8-ref at) (* 256 (%mem-u8-ref (+ at 1)))))
                 (c1v (+ (%mem-u8-ref (+ at 2))
                         (* 256 (%mem-u8-ref (+ at 3)))))
                 (c0 (c565 c0v)) (c1 (c565 c1v))
                 (cols (vector
                        c0 c1
                        (vector (quotient (+ (* 2 (vector-ref c0 0))
                                             (vector-ref c1 0)) 3)
                                (quotient (+ (* 2 (vector-ref c0 1))
                                             (vector-ref c1 1)) 3)
                                (quotient (+ (* 2 (vector-ref c0 2))
                                             (vector-ref c1 2)) 3))
                        (vector (quotient (+ (vector-ref c0 0)
                                             (* 2 (vector-ref c1 0))) 3)
                                (quotient (+ (vector-ref c0 1)
                                             (* 2 (vector-ref c1 1))) 3)
                                (quotient (+ (vector-ref c0 2)
                                             (* 2 (vector-ref c1 2))) 3)))))
            (let py ((y 0) (worst worst))
              (if (= y 4)
                  (blocks (+ bi 1) worst)
                  (let ((row (%mem-u8-ref (+ at 4 y))))
                    (let px ((x 0) (worst worst))
                      (if (= x 4)
                          (py (+ y 1) worst)
                          (let ((gx (+ (* bx 4) x)) (gy (+ (* by 4) y)))
                            (if (or (>= gx w) (>= gy h))
                                (px (+ x 1) worst)
                                (let* ((code (remainder
                                              (bitwise-arithmetic-shift-right
                                               row (* x 2))
                                              4))
                                       (c (vector-ref cols code))
                                       (gi (* (+ (* gy w) gx) 4))
                                       (d (lambda (ch i)
                                            (abs (- (vector-ref c ch)
                                                    (vector-ref
                                                     gref (+ gi i))))))
                                       (m (max (max (d 0 0) (d 1 1)) (d 2 2))))
                                  (px (+ x 1)
                                      (if (> m worst) m worst)))))))))))))))

(define bc1-ok (bc1-check 0 golden-l0 16 16 40))

(and container-ok rgba-ok etc1-ok bc1-ok)
