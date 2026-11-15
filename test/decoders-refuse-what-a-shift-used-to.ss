;; expect: #t
;; Malformed assets that a left shift used to stop still end in a condition
;; (ledger R76, batch M50).  The left shift took fixnums only and refused a
;; result past the fixnum range, and a decoder that shifted a value read
;; from a malformed stream stopped there with a catchable condition.  It
;; now answers the exact integer, so each decoder checks the values that
;; matter itself; these rows are the stops a fuzz of the bundled fixtures
;; found, each refused, not decoded and not a trap.
;;
;; - A KTX file whose Basis Huffman code lengths are over-subscribed (the
;;   ETC1S fixture of test/ktx.ss with byte 525 set to 255): the canonical
;;   codes grew past the fixnum range and the shift refused them; with
;;   the shift answering, the stream ran on into a decode that trapped
;;   (an illegal cast, measured).  $huff-build now refuses the table
;;   (Kraft: at most 2^l codes of length l or less).
;; - A KTX file whose level 0 slice reads a Basis variable-length count
;;   with a run of continuation bits past 32 bits of shift, then a payload
;;   of 1 (the fixture rewritten by archive's craft-vlc.py: the predictor
;;   table gives symbol 256 a code, and the slice opens with it, eight
;;   groups of payload 0 with the continuation bit set, and a group of 1).
;;   A zero payload keeps the count at 0, so the shift grows unchecked; the
;;   payload after it was then shifted by the whole run, a bignum whose cost
;;   is quadratic in the run's length, before the fixnum check refused it.
;;   $br-vlc now refuses a shift of 32 before shifting, and the row checks
;;   that it is that refusal: "variable-length count too long".
;; - meshopt-filter-oct! with a stride other than 4 or 8: the maximum
;;   component value was 2^(stride*2-1) - 1, a bignum, which the shift
;;   refused and then fixnum->flonum would trap on.
;;
;; ON THE TREE BEFORE THE CHANGE the rows are refused too, by the shift.
;; The rows pin that they stay refused rather than trapping: the batch
;; without the $huff-build check traps the first one, and without the
;; bound in $br-vlc the third is refused by the later check, "past the
;; fixnum range", and reads red here.
(import (rnrs) (gfx ktx) (gfx meshopt))

(define fails '())
(define (want row got expect)
  (unless (equal? got expect)
    (set! fails (cons (list row 'got got 'want expect) fails))))

(let ((need (- 100000 (* 65536 (%mem-size)))))
  (when (> need 0) (%mem-grow (quotient (+ need 65535) 65536))))

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
(define BASE 8192)
(define DST 16384)
(define (llen l) (let loop ((l l) (n 0)) (if (null? l) n (loop (cdr l) (+ n 1)))))
(define (place! bs changes)
  (let put ((b bs) (i 0))
    (when (pair? b)
      (let ((c (assv i changes)))
        (%mem-u8-set! (+ BASE i) (if c (cdr c) (car b))))
      (put (cdr b) (+ i 1)))))
(define (decode)
  (guard (e (#t 'refused))
    (ktx-transcode! (ktx-parse BASE (llen ktx2-bytes)) 0 DST 'rgba)
    'decoded))

;; the control: the fixture as it is decodes
(place! ktx2-bytes '())
(want 'ktx-fixture-decodes (decode) 'decoded)
(place! ktx2-bytes '((525 . 255)))
(want 'ktx-over-subscribed-huffman-lengths (decode) 'refused)

(define ktx-vlc-bytes
  '(171 75 84 88 32 50 48 187 13 10 26 10 0 0 0 0 1 0 0 0 16 0 0 0 16 0 0 0 0 0 0 0 0 0 0 0 1 0 0 0 5 0 0 0 1 0 0 0 200 0 0 0 44 0 0 0 244 0 0 0 36 0 0 0 24 1 0 0 0 0 0 0 41 1 0 0 0 0 0 0 71 2 0 0 0 0 0 0 7 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 68 2 0 0 0 0 0 0 3 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 67 2 0 0 0 0 0 0 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 66 2 0 0 0 0 0 0 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 65 2 0 0 0 0 0 0 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 44 0 0 0 0 0 0 0 2 0 40 0 163 1 2 0 3 3 0 0 8 0 0 0 0 0 0 0 0 0 63 0 0 0 0 0 0 0 0 0 255 255 255 255 31 0 0 0 75 84 88 119 114 105 116 101 114 0 66 97 115 105 115 32 85 110 105 118 101 114 115 97 108 32 50 46 49 48 0 0 23 0 12 0 75 0 0 0 49 0 0 0 53 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 7 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 3 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 1 0 0 0 0 0 0 0 0 0 0 0 28 64 20 128 1 0 0 65 216 35 38 152 245 21 192 20 128 1 0 134 97 24 102 152 194 107 151 0 162 0 12 0 0 8 131 48 176 23 138 7 192 20 0 0 0 0 64 16 68 13 237 238 11 10 13 45 8 69 163 13 71 81 180 112 40 20 190 170 240 165 168 222 182 143 3 4 240 247 247 7 168 84 255 7 170 84 255 7 170 212 255 135 42 85 253 7 160 74 245 7 128 74 245 7 160 74 255 47 133 82 253 55 133 82 253 7 2 40 213 175 170 170 170 2 1 129 65 0 196 127 181 11 96 78 0 0 0 0 16 0 179 6 30 154 128 183 13 2 0 0 194 16 108 188 88 88 58 66 220 36 7 192 12 0 0 0 0 0 0 114 128 0 0 0 0 0 0 30 150 230 106 64 61 128 16 66 8 33 132 1))
(define (decode-message bs)
  (place! bs '())
  (guard (e ((message-condition? e) (condition-message e)) (#t 'other))
    (ktx-transcode! (ktx-parse BASE (llen bs)) 0 DST 'rgba)
    'decoded))
(want 'ktx-vlc-run-past-32-bits (decode-message ktx-vlc-bytes)
      "variable-length count too long")

(define (oct stride)
  (guard (e (#t 'refused)) (meshopt-filter-oct! DST 1 stride) 'filtered))
(want 'meshopt-oct-stride-4 (oct 4) 'filtered)
(want 'meshopt-oct-stride-16 (oct 16) 'refused)

(display (if (null? fails) #t (reverse fails)))
