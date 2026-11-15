;; A mutation of the ETC1S fixture of test/ktx.ss, transcoded once: MUTANT
;; is "len pos val", len bytes from pos set to val (len 1: one byte; len 8:
;; a run).  Prints decoded, or refused and the condition's message; a trap
;; ends the process (ledger R98, batch M55).
(import (rnrs) (gfx ktx) (web js))
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
;; The mutation comes from the environment variable MUTANT, as numbers
;; separated by spaces, because a trap ends the program: the cell
;; (test/decoders-never-trap.mjs) runs one mutation per process.
(define (words s)
  (let loop ((cs (string->list s)) (cur '()) (out '()))
    (define (flush) (if (null? cur) out (cons (list->string (reverse cur)) out)))
    (cond ((null? cs) (reverse (flush)))
          ((char=? (car cs) #\space) (loop (cdr cs) '() (flush)))
          (else (loop (cdr cs) (cons (car cs) cur) out)))))
(define spec
  (map string->number
       (words (js->string (js-get (js-get (js-get (js-global) "process") "env")
                                  "MUTANT")))))
(define (outcome thunk)
  (guard (e ((message-condition? e) (string-append "refused: " (condition-message e)))
            (#t "refused"))
    (thunk)
    "decoded"))
(let ((need (- 1500000 (* 65536 (%mem-size)))))
  (when (> need 0) (%mem-grow (quotient (+ need 65535) 65536))))
(define BASE 8192)
(define DST 16384)
(define bytes (list->vector ktx2-bytes))
(define n (vector-length bytes))
(let ((len (car spec)) (pos (cadr spec)) (val (caddr spec)))
  (let put ((i 0))
    (when (< i n)
      (%mem-u8-set! (+ BASE i)
                    (if (and (>= i pos) (< i (+ pos len))) val (vector-ref bytes i)))
      (put (+ i 1)))))
(display (outcome (lambda () (ktx-transcode! (ktx-parse BASE n) 0 DST 'rgba))))
(newline)
