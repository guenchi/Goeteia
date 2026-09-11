;; expect: #t
;; G14 (2026-09-06 review; written as a red witness at 7740506, green
;; since): the GLB reader does not check the container it is reading.
;;
;; REGRESSION GUARD.  gltf-parse checks the four magic bytes and then
;; walks chunks, and between those two things it never asks:
;;
;;   * what version the container claims -- a file marked 99 parses
;;   * whether the declared total length matches the bytes present
;;   * whether a chunk's declared length stays inside the file -- a
;;     chunk header may say more bytes follow than exist, and the reader
;;     will read them
;;
;; In linear memory a chunk that runs past the end reads whatever is
;; after it: the JSON handed to the parser is part real, part whatever
;; the allocator had there.  So the failure is not a crash, it is a
;; scene assembled partly from another buffer -- and the input is a file
;; off the network.
;;
;; The GLB is built here rather than loaded, so each cell differs from
;; the good one in exactly one field and nothing else can be blamed.
;;
;; Reported location: lib/gfx/gltf.ss, the container reader.
(import (rnrs) (gfx gltf))

(define BASE 8192)
(define failed 0)
(define (check name ok)
  (unless ok (set! failed (+ failed 1)) (display "  FAIL ") (display name) (newline)))
(define (refuses? thunk)
  (guard (e ((error? e) #t) (else #f)) (begin (thunk) #f)))
(define (u8! at v) (%mem-u8-set! at (bitwise-and v 255)))
(define (u32! at v)
  (u8! at v)
  (u8! (+ at 1) (bitwise-arithmetic-shift-right v 8))
  (u8! (+ at 2) (bitwise-arithmetic-shift-right v 16))
  (u8! (+ at 3) (bitwise-arithmetic-shift-right v 24)))
(define (str! at s)
  (let loop ((i 0))
    (when (< i (string-length s))
      (u8! (+ at i) (char->integer (string-ref s i)))
      (loop (+ i 1)))))

;; The smallest glTF this reader accepts: it walks the scene's nodes,
;; so an asset block alone is not enough -- with no `nodes` array it
;; traps rather than refusing, which is a separate matter and not what
;; these cells are about.  Padded to four bytes, as the format requires.
(define JSON0
  "{\"asset\":{\"version\":\"2.0\"},\"scene\":0,\"scenes\":[{\"nodes\":[]}],\"nodes\":[]}")
(define JSON
  (let pad ((s JSON0))
    (if (= 0 (mod (string-length s) 4)) s (pad (string-append s " ")))))
(define JLEN (string-length JSON))
(define TOTAL (+ 12 8 JLEN))

;; version, total length and the JSON chunk length are the three fields
;; each cell below changes one of
(define (build! version total jlen)
  (str! BASE "glTF")
  (u32! (+ BASE 4) version)
  (u32! (+ BASE 8) total)
  (u32! (+ BASE 12) jlen)
;; The chunk type is written as four BYTES, not as a u32 literal.
  ;; 0x4E4F534A is 1,313,821,514, past this tree's fixnum range, so it
  ;; is a bignum -- and a bitwise operation on a bignum traps with
  ;; `illegal cast`.  The first draft of this file did write it as a
  ;; number and died before reaching a single assertion.
  (str! (+ BASE 16) "JSON")
  (str! (+ BASE 20) JSON))

;; The twin first.  Everything below asks for a refusal, and a reader
;; that refused every GLB would satisfy all of it; this is the line that
;; says the cells are about the malformed ones.
(build! 2 TOTAL JLEN)
(check "G14-TWIN: a well-formed minimal GLB still parses"
       (not (refuses? (lambda () (gltf-parse BASE TOTAL)))))

(build! 99 TOTAL JLEN)
(check "G14-VERSION: a container version of 99 is refused"
       (refuses? (lambda () (gltf-parse BASE TOTAL))))

(build! 2 (+ TOTAL 64) JLEN)
(check "G14-TOTAL: a declared total length that is not the file's length is refused"
       (refuses? (lambda () (gltf-parse BASE TOTAL))))

;; The chunk says more bytes follow than the file has.  This is the
;; one that reads another buffer's memory.
(build! 2 TOTAL (+ JLEN 4096))
(check "G14-CHUNK: a chunk that runs past the end of the file is refused"
       (refuses? (lambda () (gltf-parse BASE TOTAL))))

;; The strict reading of the declared length, pinned so that relaxing
;; it is a decision rather than a drift.  The spec says the header's
;; length IS the file's length, and this refuses a file that declares
;; less than it carries -- an exporter that appends trailing bytes would
;; be rejected, and that was weighed rather than overlooked.
;;
;; The reasoning: the caller passes the byteLength of what it fetched,
;; so a mismatch means one of the two is wrong and there is nothing to
;; choose between them.  Postel's law argues for accepting a wider range
;; of WELL-FORMED input; a file that disagrees with itself about its own
;; size is not wider input.
(build! 2 (- TOTAL 8) JLEN)
(check "G14-TOTAL: a declared length SMALLER than the file is refused too"
       (refuses? (lambda () (gltf-parse BASE TOTAL))))

;; EVERYTHING BELOW MAY TRAP RATHER THAN FAIL, so it goes last.
;;
;; Removing a guard has three outcomes, not two: a named red, a trap, or
;; nothing at all.  A trap is still coverage -- something noticed -- but
;; it is coverage that takes the rest of the file's verdicts with it,
;; because a wasm trap is not a condition and the run simply stops.
;; -> A cell that traps under mutation belongs in this group even when it
;; is a clean named refusal today.
;;
;; G14-SHORT is here for exactly that reason.  Today it is a named
;; refusal; with `len >= 12` removed it traps, because reading the
;; version and the total length of a six-byte file goes past the end.
;; That cannot be turned into a named red -- the read happens before
;; any check could exist -- so the best available result is a trap, a
;; non-zero exit, and the runner's line saying the list is a lower
;; bound.  It sat above two other cells until it was measured, and
;; one of those was the only thing watching a ruling.  With no
;; bound on a chunk length, one walks the reader out of linear memory
;; and the other reads chunk headers past a six-byte file; a wasm trap
;; is not a condition, so `refuses?` cannot see either and the file dies
;; at the first of them.
;;
;; They are still evidence of the same missing bound as the three cells
;; above, at sizes big enough to leave the sandbox rather than quietly
;; read the next buffer -- and the quiet one is the dangerous one.
;;
;; After everything else, so that a trap here cannot take the other
;; verdicts with it: a run that ends in this section has already printed
;; them, and run-tests.sh says the list is a lower bound.
;; The header region is CLEARED first, and the declared length is
;; written to match the six bytes on offer.  The first version of this
;; cell wrote only the magic over whatever the previous build had left,
;; so offsets 8..11 still held the last case's total -- the file was
;; refused, correctly, but by the declared-length check rather than by
;; the one this cell is named after.
;;
;; Measured: with the length guard removed, nothing in the file went
;; red.  A cell can be satisfied by a guard other than the one it names,
;; and then it reports on a guard it never touches -- which is worse
;; than having no cell, because the name says otherwise.
(let clear ((i 0)) (when (< i 32) (u8! (+ BASE i) 0) (clear (+ i 1))))
(str! BASE "glTF")
(u32! (+ BASE 4) 2)
(u32! (+ BASE 8) 6)                     ; declared length == what we pass
(check "G14-SHORT: a file shorter than its own header is refused"
       (refuses? (lambda () (gltf-parse BASE 6))))

;; The gigabyte is written as four BYTES for the same reason the
;; chunk type is: 0x3FFFFF00 is 1,073,741,568, past this tree's fixnum
;; range, and `u32!` shifts it.  The first version of this file worked
;; around the bignum trap for the chunk TYPE and not for the chunk
;; LENGTH, which goes through the same helper -- so the trap happened
;; while building the input, before gltf-parse was ever called.
;;
;; And the cost of that was not one missing cell.  The trap took the
;; whole file's stdout with it, so five correct verdicts above were
;; never printed and the runner saw `want '#t', got ''`.  A completely
;; correct implementation and a completely broken one produced the same
;; output on this file.
(build! 2 TOTAL JLEN)
(u8! (+ BASE 12) #x00) (u8! (+ BASE 13) #xFF)
(u8! (+ BASE 14) #xFF) (u8! (+ BASE 15) #x3F)   ; 0x3FFFFF00, little-endian
(check "G14-ABSURD: a gigabyte chunk length in a ninety-byte file is refused"
       (refuses? (lambda () (gltf-parse BASE TOTAL))))

(display (= failed 0))
