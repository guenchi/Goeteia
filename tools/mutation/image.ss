;; A mutation driver for tools/mutate.mjs, which appends
;; tools/mutation/harness.ss to it.  Drives the PNG and TGA decoders.
(import (rnrs) (web js) (gfx image))
(define MEM-NEED 800000)
(define BASE 8192)
(define DST 65536)
(define SCR 200000)
(define fixtures-as-built
  (list
   ;; tools/mutation/fixtures.py: 12x10 RGBA, every filter type
   (cons "png-rgba"
         '(
           137 80 78 71 13 10 26 10 0 0 0 13 73 72 68 82 0 0 0 12
           0 0 0 10 8 6 0 0 0 128 44 191 250 0 0 1 169 73 68 65
           84 120 218 21 144 189 110 212 64 20 133 175 125 39 99 207 143 61 241 216
           222 117 226 205 38 187 41 104 136 120 1 68 69 71 9 21 61 69 158 128
           40 18 8 130 162 8 104 81 10 58 10 26 122 196 139 64 141 120 132 253
           177 189 51 107 143 177 139 79 247 232 92 233 30 157 11 82 194 102 25 195
           234 33 129 253 19 31 186 231 8 237 229 1 216 235 65 127 29 252 111 30
           184 159 3 127 34 88 255 29 118 94 252 0 86 225 22 229 169 192 138 85
           40 202 0 77 210 33 206 66 220 241 26 249 56 69 131 172 32 216 78 17
           59 191 47 192 115 83 244 109 74 105 95 48 207 59 150 61 28 41 104 14
           53 227 231 121 93 171 130 7 103 165 233 38 115 52 122 17 96 247 8 62
           36 41 181 34 10 129 75 230 241 72 128 206 164 137 84 236 120 164 32 73
           19 43 149 118 74 103 123 159 228 140 4 103 96 204 16 105 128 130 136 217
           154 58 233 119 78 98 85 75 62 137 228 102 187 149 195 25 217 243 1 153
           72 11 209 39 88 47 63 171 213 197 205 220 62 189 189 104 94 188 127 188
           127 245 246 153 187 122 243 178 255 114 123 217 252 184 187 170 126 189 187 107
           127 127 188 223 252 187 249 110 61 184 135 190 32 186 157 133 122 151 116 26
           115 79 247 188 214 124 244 70 173 157 246 71 230 92 215 25 104 240 225 8
           128 156 96 107 52 13 198 210 54 149 148 45 85 195 207 117 237 151 185 163
           167 133 13 23 229 206 166 115 218 230 11 130 236 26 94 139 40 134 36 83
           38 224 9 146 64 83 26 102 7 76 230 158 136 166 64 130 130 198 135 199
           93 40 74 63 157 156 52 4 103 208 153 225 223 13 82 162 3 102 68 47
           43 69 84 235 42 45 40 203 27 233 21 198 108 203 33 182 108 214 245 34
           254 15 10 139 146 209 95 248 64 33 0 0 0 0 73 69 78 68 174 66
           96 130 153))
   ;; tools/mutation/fixtures.py: 10x8, 8-bit palette with tRNS
   (cons "png-palette"
         '(
           137 80 78 71 13 10 26 10 0 0 0 13 73 72 68 82 0 0 0 10
           0 0 0 8 8 3 0 0 0 247 36 158 132 0 0 0 18 80 76 84
           69 0 0 0 255 0 0 0 255 0 0 0 255 255 255 0 255 255 255 90
           107 99 224 0 0 0 2 116 82 78 83 0 128 155 43 78 24 0 0 0
           52 73 68 65 84 120 218 45 138 193 17 0 65 8 194 34 98 255 45 31
           186 247 144 9 18 170 186 61 155 168 123 168 146 135 159 178 224 220 45 240
           188 144 56 47 93 65 197 219 52 251 59 242 7 34 176 0 193 88 42 9
           81 0 0 0 0 73 69 78 68 174 66 96 130 150))
   ;; tools/mutation/fixtures.py: 8x6 run-length true colour
   (cons "tga-rle"
         '(
           0 0 10 0 0 0 0 0 0 0 0 0 8 0 6 0 32 8 131 0
           10 200 255 3 0 0 7 255 30 0 7 255 60 0 7 255 90 0 7 255
           131 40 10 200 255 3 0 30 7 255 30 30 7 255 60 30 7 255 90 30
           7 255 131 80 10 200 255 3 0 60 7 255 30 60 7 255 60 60 7 255
           90 60 7 255 131 120 10 200 255 3 0 90 7 255 30 90 7 255 60 90
           7 255 90 90 7 255 131 160 10 200 255 3 0 120 7 255 30 120 7 255
           60 120 7 255 90 120 7 255 131 200 10 200 255 3 0 150 7 255 30 150
           7 255 60 150 7 255 90 150 7 255 712))))
;; The two PNG fixtures again, as an attacker who writes the CRC would
;; send them: after the mutation, decode! rewrites the CRC of every chunk
;; it can walk, so a changed byte reaches inflate and the filters instead
;; of stopping at the CRC check (3489 of the 3711 plain PNG mutations
;; stopped there on 57868e4).  An unchanged chunk's CRC is rewritten to
;; the value it had; a changed length moves the chunks the walk sees, as
;; it would for the decoder.  Listed last, so the numbering of the
;; fixtures before them does not change.
(define fixtures
  (append fixtures-as-built
          (list (cons "png-rgba-crc" (cdr (assoc "png-rgba" fixtures-as-built)))
                (cons "png-palette-crc" (cdr (assoc "png-palette" fixtures-as-built))))))

(define (be32 at)
  (+ (* 16777216 (%mem-u8-ref at)) (* 65536 (%mem-u8-ref (+ at 1)))
     (* 256 (%mem-u8-ref (+ at 2))) (%mem-u8-ref (+ at 3))))

;; each chunk is length (4), type (4), data, CRC (4) over type and data;
;; the walk stops at a chunk that runs past the end
(define (rewrite-crcs! n)
  (let walk ((at (+ BASE 8)))
    (when (<= (+ at 12) (+ BASE n))
      (let ((len (be32 at)))
        (when (<= (+ at 12 len) (+ BASE n))
          (let-values (((hi lo) (crc32 (+ at 4) (+ len 4))))
            (let ((c (+ at 8 len)))
              (%mem-u8-set! c (quotient hi 256))
              (%mem-u8-set! (+ c 1) (remainder hi 256))
              (%mem-u8-set! (+ c 2) (quotient lo 256))
              (%mem-u8-set! (+ c 3) (remainder lo 256))))
          (walk (+ at 12 len)))))))

(define (decode! name n)
  (cond ((string=? name "tga-rle") (tga-decode! BASE n DST))
        ((or (string=? name "png-rgba-crc") (string=? name "png-palette-crc"))
         (rewrite-crcs! n)
         (png-decode! BASE n DST SCR))
        (else (png-decode! BASE n DST SCR))))
