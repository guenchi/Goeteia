;; expect: #t
;; string->utf16, string->utf32, utf16->string and utf32->string, with
;; and without an endianness, the byte-order mark, characters outside the
;; Basic Multilingual Plane, and malformed input (ledger R20).  A goeteia
;; string holds UTF-8 bytes (docs/limits.md), so the conversions read and
;; write strings as UTF-8, and every row compares a string by the bytes
;; string->utf8 gives for it, which are the same on Chez.
;;
;; Each row is an expression and the answer Chez 10 gives for it, compared
;; as a value; a row that raises answers `raised'.  A row marked OWN pins
;; goeteia's answer where R6RS leaves the matter open and Chez differs.
;;
;; Each `site' row answers (kind error? violation? i/o-read? message?
;; irritants?) for what the expression raises.
;;
;; ON THE TREE BEFORE THE CHANGE this file does not compile: the names are
;; unbound.
(import (rnrs))

(define (bl b) (bytevector->u8-list b))
(define (bv . xs) (u8-list->bytevector xs))
;; a string as the UTF-8 bytes that spell it
(define (u8 s) (bl (string->utf8 s)))
;; the code points a string holding these bytes is read as: string->utf32
;; reads a string as UTF-8, and utf8->string on Chez replaces what is
;; malformed first, the same way
(define (points . bytes)
  (let loop ((l (bytevector->u8-list (string->utf32 (utf8->string (u8-list->bytevector bytes)) 'big)))
             (acc '()))
    (if (null? l)
        (reverse acc)
        (loop (cddddr l)
              (cons (+ (* 16777216 (car l)) (* 65536 (cadr l)) (* 256 (caddr l)) (cadddr l)) acc)))))

(define fails '())
(define (want row got expect)
  (unless (equal? got expect)
    (set! fails (cons (list row 'got got 'want expect) fails))))

(want 'to-utf16-default-big
      (guard (c (#t 'raised))
        (bl (string->utf16 "Az")))
      '(0 65 0 122))
(want 'to-utf16-little
      (guard (c (#t 'raised))
        (bl (string->utf16 "Az" 'little)))
      '(65 0 122 0))
(want 'to-utf16-two-byte-utf8
      (guard (c (#t 'raised))
        (list (bl (string->utf16 "caf\xE9;")) (bl (string->utf16 "\x4100;\xFFFD;" 'little))))
      '((0 99 0 97 0 102 0 233) (0 65 253 255)))
(want 'to-utf16-astral
      (guard (c (#t 'raised))
        (list (bl (string->utf16 "a\x1F600;z")) (bl (string->utf16 "a\x1F600;z" 'little))))
      '((0 97 216 61 222 0 0 122) (97 0 61 216 0 222 122 0)))
(want 'to-utf32
      (guard (c (#t 'raised))
        (list (bl (string->utf32 "Az")) (bl (string->utf32 "Az" 'little)) (bl (string->utf32 "a\x1F600;z")) (bl (string->utf32 "caf\xE9;" 'little))))
      '((0 0 0 65 0 0 0 122) (65 0 0 0 122 0 0 0) (0 0 0 97 0 1 246 0 0 0 0 122) (99 0 0 0 97 0 0 0 102 0 0 0 233 0 0 0)))
(want 'from-utf16-ascii
      (guard (c (#t 'raised))
        (list (utf16->string (bv 0 65 0 122) 'big) (utf16->string (bv 65 0 122 0) 'little)))
      '("Az" "Az"))
(want 'from-utf16-as-utf8
      (guard (c (#t 'raised))
        (list (u8 (utf16->string (bv 0 97 216 61 222 0 0 122) 'big)) (u8 (utf16->string (bv 233 0) 'little))))
      '((97 240 159 152 128 122) (195 169)))
(want 'from-utf16-bom
      (guard (c (#t 'raised))
        (map u8 (list (utf16->string (bv 254 255 0 65) 'little) (utf16->string (bv 255 254 65 0) 'big) (utf16->string (bv 254 255 0 65) 'little #t))))
      '((65) (65) (239 191 190 228 132 128)))
(want 'from-utf32
      (guard (c (#t 'raised))
        (map u8 (list (utf32->string (bv 0 0 0 65 0 1 246 0) 'big) (utf32->string (bv 65 0 0 0) 'little) (utf32->string (bv 0 0 254 255 0 0 0 66) 'little))))
      '((65 240 159 152 128) (65) (66)))
(want 'round-trips
      (guard (c (#t 'raised))
        (list (equal? (utf32->string (string->utf32 "a\x1F600;z") 'big) "a\x1F600;z") (equal? (utf16->string (string->utf16 "caf\xE9;" 'little) 'little) "caf\xE9;") (equal? (utf16->string (string->utf16 "a\x1F600;z") 'big) "a\x1F600;z") (utf16->string (string->utf16 "") 'big)))
      '(#t #t #t ""))
;; OWN: Chez answers ((239 191 189) (65 239 191 189) (239 191 189))
(want 'malformed-utf16
      (guard (c (#t 'raised))
        (list (u8 (utf16->string (bv 216 0 0 65) 'big)) (u8 (utf16->string (bv 0 65 0) 'big)) (u8 (utf16->string (bv 220 0) 'big))))
      '((239 191 189 65) (65 239 191 189) (239 191 189)))
(want 'malformed-utf32
      (guard (c (#t 'raised))
        (list (u8 (utf32->string (bv 0 0 216 0 0 17 0 0) 'big)) (u8 (utf32->string (bv 0 0 0 65 0) 'big))))
      '((239 191 189 239 191 189) (65 239 191 189)))
(want 'utf8-valid-edges
      (guard (c (#t 'raised))
        (map (lambda (bs) (apply points bs)) '((#xC2 #x80) (#xDF #xBF) (#xE0 #xA0 #x80) (#xED #x9F #xBF) (#xEE #x80 #x80) (#xF0 #x90 #x80 #x80) (#xF4 #x8F #xBF #xBF) (#xE2 #x82 #xAC))))
      '((128) (2047) (2048) (55295) (57344) (65536) (1114111) (8364)))
(want 'utf8-overlong
      (guard (c (#t 'raised))
        (map (lambda (bs) (apply points bs)) '((#xC0 #xAF) (#xC1 #xBF) (#xE0 #x80 #x80) (#xE0 #x9F #xBF) (#xF0 #x80 #x80 #x80))))
      '((65533) (65533) (65533) (65533) (65533)))
(want 'utf8-surrogates-and-past-the-last
      (guard (c (#t 'raised))
        (map (lambda (bs) (apply points bs)) '((#xED #xA0 #x80) (#xF4 #x90 #x80 #x80) (#xF4 #x8F #xBF #xBF #x80))))
      '((65533) (65533) (1114111 65533)))
(want 'utf8-truncated-and-interrupted
      (guard (c (#t 'raised))
        (map (lambda (bs) (apply points bs)) '((#xC2) (#xE2 #x82) (#x61 #xE2 #x82 #x62) (#xE0 #x80 #x41) (#xE0 #xA0 #x41) (#xF0 #x90 #x41) (#xC2 #x41))))
      '((65533) (65533) (97 65533 98) (65533 65) (65533 65) (65533 65) (65533 65)))
(want 'utf8-bytes-that-start-nothing
      (guard (c (#t 'raised))
        (map (lambda (bs) (apply points bs)) '((#x80) (#xBF #x41) (#xFF) (#xF5 #x80 #x80 #x80) (#xF7 #xBF #xBF #xBF) (#xF8 #x88 #x80 #x80 #x80))))
      '((65533) (65533 65) (65533) (65533 65533 65533 65533) (65533 65533 65533 65533) (65533 65533 65533 65533 65533)))
(want 'utf8-malformed-to-utf16
      (guard (c (#t 'raised))
        (list (bytevector->u8-list (string->utf16 (utf8->string (u8-list->bytevector '(#xED #xA0 #x80))))) (bytevector->u8-list (string->utf16 (utf8->string (u8-list->bytevector '(#xF4 #x90 #x80 #x80))) 'little))))
      '((255 253) (253 255)))

(display (if (null? fails) #t (reverse fails)))
