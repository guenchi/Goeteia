;; A mutation driver for tools/mutate.mjs, which appends
;; tools/mutation/harness.ss to it.  Drives the UASTC block decoder.
(import (rnrs) (web js) (gfx uastc))
(define MEM-NEED 400000)
(define BASE 50000)
(define fixtures
  (list
   ;; test/uastc.ss's blk-src, 13 blocks
   (cons "blocks"
         '(
           177 72 3 96 221 214 109 221 98 251 97 251 96 250 80 233 245 36 254 179
           239 179 239 179 79 78 78 78 14 0 0 0 83 129 6 248 199 53 228 247
           255 223 255 161 42 213 127 0 235 129 30 113 16 113 16 113 128 70 177 85
           253 245 7 0 219 129 2 5 5 8 48 128 64 200 81 217 98 234 115 251
           247 255 255 255 31 124 239 1 0 0 0 0 0 0 0 0 207 168 3 177
           28 254 1 66 222 225 1 34 0 165 254 115 202 216 177 81 35 160 0 0
           0 0 32 83 48 167 80 250 56 49 18 32 1 8 129 197 49 48 116 116
           184 184 252 252 95 1 32 81 88 154 64 2 32 96 88 26 5 165 175 15
           5 5 90 71 116 250 255 255 110 95 110 63 76 29 40 25 21 38 173 227
           254 129 254 255 91 138 254 255 203 228 228 228 229 252 186 67 225 255 255 159
           153 1 152 1 128 1 0 0))))
(define (decode! name n)
  (let each ((at 0))
    (when (<= (+ at 16) n)
      (uastc-block! (+ BASE at) 60000)
      (each (+ at 16)))))
