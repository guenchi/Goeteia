;; expect: #t
;; A supercompressed UASTC level whose decode RAISES gives its temporaries
;; back too (ledger R90, batch M52): ktx-uastc-level! takes the inflated
;; blocks and the zstd scratch from the bump heap, and the water level
;; (fx-mark) must be where it was whether the level decodes or not.
;;
;; The raise has to come after the two allocations, or the cell says
;; nothing about the release: the compressed stream is cut to half its
;; length (byteLength at offset 88 halved, the file cut to match), so
;; the length check passes and zstd-decode! runs out of input partway.
;; The condition must be catchable, and a good level must still decode
;; after it.  The length check that raises BEFORE allocating is a
;; control: the level stays put there on any tree.
;;
;; Setup line for line from test/ktx-uastc-zstd-keeps-no-memory.ss.
;;
;; ON THE TREE BEFORE THE CHANGE the truncated decode leaves the level
;; risen by the two temporaries.
(import (rnrs) (gfx ktx) (gfx fx))

(let ((need (- 500000 (* 65536 (%mem-size)))))
  (when (> need 0) (%mem-grow (quotient (+ need 65535) 65536))))

(define RAW 300000)
(define ZST 320000)
(define DST 350000)
(define (load! base bs)
  (let put ((b bs) (i 0))
    (when (pair? b) (%mem-u8-set! (+ base i) (car b)) (put (cdr b) (+ i 1)))))
(define (llen l) (let loop ((l l) (n 0)) (if (null? l) n (loop (cdr l) (+ n 1)))))
(define (cmp gold)
  (let loop ((g gold) (i 0) (bad 0))
    (if (null? g)
        (begin (when (> bad 0) (display "  ") (display bad) (display " bytes differ") (newline)) (= bad 0))
        (loop (cdr g) (+ i 1) (if (= (%mem-u8-ref (+ DST i)) (car g)) bad (+ bad 1))))))
(define kw 16)
(define kh 16)
(define ktx-raw
  (append
   (quote (171 75 84 88 32 50 48 187 13 10 26 10 0 0 0 0 1 0 0 0 16 0 0 0 16 0 0 0 0 0 0 0 0 0 0 0 1 0 0 0 1 0 0 0 0 0 0 0 104 0 0 0 44 0 0 0 148 0 0 0 44 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 192 0 0 0 0 0 0 0 0 1 0 0 0 0 0 0 0 1 0 0 0 0 0 0 44 0 0 0 0 0 0 0 2 0 40 0 166 1 2 0 3 3 0 0 16 0 0 0 0 0 0 0 0 0 127 3 0 0 0 0 0 0 0 0 255 255 255 255 31 0 0 0 75 84 88 119 114 105 116 101 114 0 66 97 115 105 115 32 85 110 105 118 101 114 115 97 108 32 50 46))
   (quote (49 48 0 0 4 0 0 0 127 127 0 0 52 49 155 71 0 1 1 97 216 109 221 230 109 254 230 127 60 49 59 12 32 131 145 6 2 25 144 33 25 162 33 58 60 49 187 74 252 130 33 7 130 17 24 161 33 58 162 51 52 49 59 39 228 0 241 99 216 109 221 230 109 254 230 127 36 49 59 18 128 33 147 6 2 25 144 33 25 162 33 58 52 49 123 11 160 163 163 7 130 17 24 161 17 42 161 50 28 49 155 50 252 34 243 99 200 93 220 229 109 254 230 127 28 49 251 46 220 32 255 6 2 41 144 34 25 178 33 59 20 49 187 78 128 253 34 7 130 33 24 162 17 58 161 51 28 48 155 47 32 255 242 99 200 109 220 230 93 254 229 127 44 49 123 11 252 254 254 6))
   (quote (2 25 144 33 25 178 33 59 52 48 251 57 228 252 238 5 146 33 24 162 33 58 161 51 52 49 59 36 0 229 240 99 216 109 221 230 109 254 230 127 28 49 251 44 32 223 252 6 2 25 144 33 41 178 34 59 60 49 251 52 252 230 236 5 130 17 25 162 33 58 162 51 36 49 219 35 228 228 228 96 216 109 221 230 109 254 230 127))))
(define ktx-zstd
  (append
   (quote (171 75 84 88 32 50 48 187 13 10 26 10 0 0 0 0 1 0 0 0 16 0 0 0 16 0 0 0 0 0 0 0 0 0 0 0 1 0 0 0 1 0 0 0 2 0 0 0 104 0 0 0 44 0 0 0 148 0 0 0 36 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 184 0 0 0 0 0 0 0 237 0 0 0 0 0 0 0 0 1 0 0 0 0 0 0 44 0 0 0 0 0 0 0 2 0 40 0 166 1 2 0 3 3 0 0 16 0 0 0 0 0 0 0 0 0 127 3 0 0 0 0 0 0 0 0 255 255 255 255 31 0 0 0 75 84 88 119 114 105 116 101 114 0 66 97 115 105 115 32 85 110 105 118 101 114 115 97 108 32 50 46))
   (quote (49 48 0 0 40 181 47 253 96 0 0 29 7 0 164 12 52 49 155 71 0 1 1 97 216 109 221 230 109 254 230 127 60 49 59 12 32 131 145 6 2 25 144 33 25 162 33 58 60 49 187 74 252 130 33 7 130 17 24 161 33 58 162 51 52 49 59 39 228 0 241 99 36 49 59 18 128 33 147 52 49 123 11 160 163 163 17 42 161 50 28 49 155 50 252 34 243 99 200 93 220 229 28 49 251 46 220 32 255 6 2 41 144 34 25 178 33 59 20 49 187 78 128 253 34 7 130 33 24 162 17 58 161 51 28 48 155 47 32 255 242 99 200 109 220 230 93 254 229 127 44 49 123 11 252 254 254 178 33 59 52 48 251 57 228 252 238 5 146 33 24 162 33 58 161 36 0 229 240 28))
   (quote (49 251 44 32 223 252 41 178 34 59 60 49 251 52 252 230 236 5 130 17 162 51 36 49 219 35 228 228 228 96 216 109 221 230 109 254 230 127 9 0 33 19 10 92 3 69 76 44 132 27 195 108 32 0 184 27 20 131 147 80 80))))
(define rgba-gold
  (append
   (quote (0 0 0 127 14 14 14 255 14 14 14 255 29 29 29 127 70 5 38 255 70 5 38 255 82 19 52 127 82 19 52 255 136 0 70 255 136 0 70 127 147 15 82 255 147 15 82 255 190 0 97 127 205 14 110 255 205 14 110 255 220 29 123 127 14 14 14 255 14 14 14 255 29 29 29 127 29 29 29 255 70 5 38 255 82 19 52 127 82 19 52 255 95 34 67 255 136 0 70 127 147 15 82 255 147 15 82 255 158 32 95 127 205 14 110 255 205 14 110 255 220 29 123 127 220 29 123 255 14 14 14 255 29 29 29 127 29 29 29 255 43 43 43 255 82 19 52 127 82 19 52 255 95 34 67 255 95 34 67 127 147 15 82 255 158 32 95 255 158 32 95 127 169 48 108 255 205 14 110 255))
   (quote (220 29 123 127 220 29 123 255 234 43 136 255 29 29 29 127 29 29 29 255 43 43 43 255 43 43 43 127 82 19 52 255 95 34 67 255 95 34 67 127 108 48 81 255 158 32 95 255 158 32 95 127 169 48 108 255 169 48 108 255 220 29 123 127 220 29 123 255 234 43 136 255 234 43 136 127 5 70 38 255 5 70 38 255 19 82 52 127 19 82 52 255 70 70 70 255 70 70 70 127 84 84 84 255 84 84 84 255 136 70 103 127 136 70 103 255 147 82 114 255 147 82 114 127 196 70 136 255 196 70 136 255 210 81 147 127 225 92 158 255 5 70 38 255 19 82 52 127 19 82 52 255 34 95 67 255 70 70 70 127 84 84 84 255 84 84 84 255 99 99 99 127 136 70 103 255 147 82 114 255))
   (quote (147 82 114 127 158 95 125 255 196 70 136 255 210 81 147 127 225 92 158 255 225 92 158 255 19 82 52 127 19 82 52 255 34 95 67 255 34 95 67 127 84 84 84 255 84 84 84 255 99 99 99 127 99 99 99 255 147 82 114 255 158 95 125 127 158 95 125 255 169 108 136 255 210 81 147 127 210 81 147 255 225 92 158 255 239 103 169 127 19 82 52 255 34 95 67 255 34 95 67 127 48 108 81 255 84 84 84 255 99 99 99 127 99 99 99 255 113 113 113 255 158 95 125 127 158 95 125 255 169 108 136 255 169 108 136 127 210 81 147 255 225 92 158 255 239 103 169 127 239 103 169 255 0 136 70 255 0 136 70 127 15 147 82 255 32 158 95 255 70 136 103 127 70 136 103 255 82 147 114 255))
   (quote (95 158 125 127 136 136 136 255 136 136 136 255 149 149 149 127 149 149 149 255 190 131 163 255 206 144 176 127 206 144 176 255 223 157 189 255 0 136 70 127 15 147 82 255 32 158 95 255 32 158 95 127 70 136 103 255 82 147 114 255 95 158 125 127 95 158 125 255 136 136 136 255 149 149 149 127 149 149 149 255 162 162 162 255 190 131 163 127 206 144 176 255 223 157 189 255 223 157 189 127 15 147 82 255 15 147 82 255 32 158 95 127 48 169 108 255 82 147 114 255 82 147 114 127 95 158 125 255 108 169 136 255 149 149 149 127 149 149 149 255 162 162 162 255 174 174 174 127 206 144 176 255 223 157 189 255 223 157 189 127 239 169 201 255 15 147 82 255 32 158 95 127 48 169 108 255 48 169 108 255))
   (quote (82 147 114 127 95 158 125 255 108 169 136 255 108 169 136 127 149 149 149 255 162 162 162 255 174 174 174 127 174 174 174 255 206 144 176 255 223 157 189 127 239 169 201 255 239 169 201 255 0 190 97 127 14 205 110 255 14 205 110 255 29 220 123 127 70 196 136 255 70 196 136 255 81 210 147 127 81 210 147 255 131 190 163 255 131 190 163 127 144 206 176 255 144 206 176 255 190 190 190 127 205 205 205 255 205 205 205 255 220 220 220 127 14 205 110 255 14 205 110 255 29 220 123 127 29 220 123 255 70 196 136 255 81 210 147 127 81 210 147 255 92 225 158 255 144 206 176 127 144 206 176 255 157 223 189 255 157 223 189 127 205 205 205 255 205 205 205 255 220 220 220 127 220 220 220 255 14 205 110 255))
   (quote (29 220 123 127 29 220 123 255 43 234 136 255 81 210 147 127 92 225 158 255 92 225 158 255 103 239 169 127 144 206 176 255 157 223 189 255 157 223 189 127 169 239 201 255 205 205 205 255 220 220 220 127 220 220 220 255 234 234 234 255 29 220 123 127 29 220 123 255 43 234 136 255 43 234 136 127 92 225 158 255 92 225 158 255 103 239 169 127 103 239 169 255 157 223 189 255 157 223 189 127 169 239 201 255 169 239 201 255 220 220 220 127 220 220 220 255 234 234 234 255 234 234 234 127))))

(load! RAW ktx-raw)
(load! ZST ktx-zstd)
(define kraw (ktx-parse RAW (llen ktx-raw)))
(define kzst (ktx-parse ZST (llen ktx-zstd)))
(define (run k) (ktx-uastc-level! k 0 DST) (cmp rgba-gold))

(define fails '())
(define (want row got expect)
  (unless (equal? got expect)
    (set! fails (cons (list row 'got got 'want expect) fails))))
(define (u8 at) (%mem-u8-ref at))
(define (u8! at v) (%mem-u8-set! at v))
(define (u32 at)
  (+ (u8 at) (* 256 (u8 (+ at 1))) (* 65536 (u8 (+ at 2)))
     (* 16777216 (u8 (+ at 3)))))
(define (u32! at v)
  (let loop ((i 0) (v v))
    (when (< i 4) (u8! (+ at i) (remainder v 256)) (loop (+ i 1) (quotient v 256)))))
(define (copy-to! base bs) (load! base bs))

;; one good decode first, so whatever is allocated once is allocated
(want 'zstd-first-call-decodes (run kzst) #t)

;; the stream cut to half its length
(define CUT 440000)
(copy-to! CUT ktx-zstd)
(define cut-off (u32 (+ CUT 80)))
(define cut-len (quotient (u32 (+ CUT 88)) 2))
(u32! (+ CUT 88) cut-len)
(define kcut (ktx-parse CUT (+ cut-off cut-len)))
(define before-cut (fx-mark))
(want 'a-truncated-stream-raises-a-condition
      (guard (e ((condition? e) 'condition) (#t 'other))
        (ktx-uastc-level! kcut 0 DST)
        'decoded)
      'condition)
(want 'level-after-a-raising-decode (- (fx-mark) before-cut) 0)

;; the control: the length check raises before anything is allocated
(define SHORT 470000)
(copy-to! SHORT ktx-zstd)
(u32! (+ SHORT 96) 255)
(define kshort (ktx-parse SHORT (llen ktx-zstd)))
(define before-short (fx-mark))
(want 'the-length-check-raises
      (guard (e ((condition? e) 'condition) (#t 'other))
        (ktx-uastc-level! kshort 0 DST)
        'decoded)
      'condition)
(want 'level-after-the-length-check (- (fx-mark) before-short) 0)

;; and a good level still decodes, at the same level
(define before-good (fx-mark))
(want 'a-good-level-still-decodes (run kzst) #t)
(want 'level-after-the-good-decode (- (fx-mark) before-good) 0)

(display (if (null? fails) #t (reverse fails)))
