;; expect: #t
;; G14 (2026-09-06 review, still live 2026-09-09): the GLB reader does
;; not check the container it is reading.
;;
;; RED ON PURPOSE.  gltf-parse checks the four magic bytes and then
;; walks chunks, and between those two things it never asks:
;;
;;   * what version the container claims -- a file marked 99 parses
;;   * whether the declared total length matches the bytes present
;;   * whether a chunk's declared length stays inside the file -- a
;;     chunk header may say more bytes follow than exist, and the reader
;;     will read them
;;
;; ⚠️ In linear memory a chunk that runs past the end reads whatever is
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
;; ⚠️ The chunk type is written as four BYTES, not as a u32 literal.
  ;; 0x4E4F534A is 1,313,821,514, past this tree's fixnum range, so it
  ;; is a bignum -- and a bitwise operation on a bignum traps with
  ;; `illegal cast`.  The first draft of this file did write it as a
  ;; number and died before reaching a single assertion.
  (str! (+ BASE 16) "JSON")
  (str! (+ BASE 20) JSON))

;; ⭐ The twin first.  Everything below asks for a refusal, and a reader
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

;; ⚠️ The chunk says more bytes follow than the file has.  This is the
;; one that reads another buffer's memory.
(build! 2 TOTAL (+ JLEN 4096))
(check "G14-CHUNK: a chunk that runs past the end of the file is refused"
       (refuses? (lambda () (gltf-parse BASE TOTAL))))

;; ⭐ These two go LAST because they do not fail -- they TRAP.  With no
;; bound on a chunk length, one walks the reader out of linear memory
;; and the other reads chunk headers past a six-byte file; a wasm trap
;; is not a condition, so `refuses?` cannot see either and the file dies
;; at the first of them.
;;
;; They are still evidence of the same missing bound as the three cells
;; above, at sizes big enough to leave the sandbox rather than quietly
;; read the next buffer -- ⚠️ and the quiet one is the dangerous one.
;;
;; After everything else, so that a trap here cannot take the other
;; verdicts with it: a run that ends in this section has already printed
;; them, and run-tests.sh says the list is a lower bound.
(str! BASE "glTF")
(check "G14-SHORT: a file shorter than its own header is refused"
       (refuses? (lambda () (gltf-parse BASE 6))))
(build! 2 TOTAL #x3FFFFF00)             ; a gigabyte, in a file of ninety bytes
(check "G14-ABSURD: a gigabyte chunk length in a ninety-byte file is refused"
       (refuses? (lambda () (gltf-parse BASE TOTAL))))
(display (= failed 0))
