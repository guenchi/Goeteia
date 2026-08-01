;; Mount-section assembly for two-artifact pages: given a --js
;; compiled module's text and a reference to the wasm artifact, build
;; the HTML fragment that runs the wasm on WasmGC engines and the
;; inline JS fallback everywhere else (rt/web.mjs's loadGoeteiaAuto
;; does the picking at load time).
;;
;;   (mount-html js-text wasm-ref rt-url)  ->  fragment string
;;
;; wasm-ref is either a URL string (the lean deployment: the .wasm
;; fetches and caches separately) or the module's bytes as a
;; bytevector, which embeds as a data: URI for a fully self-contained
;; page.  rt-url locates rt/web.mjs from the page.  The emitter
;; escapes `<` inside string literals, so the fallback text cannot
;; close its own script tag; this library still verifies that
;; invariant rather than assuming it.
;; Copyright (c) 2026 guenchi. MIT license; see LICENSE.
(library (web embed)
  (export mount-html wasm->data-uri base64-encode)
  (import (rnrs))

  (define $b64 "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")

  ;; standard base64 with padding
  (define (base64-encode bv)
    (let* ((n (bytevector-length bv))
           (groups (quotient (+ n 2) 3))
           (out (make-string (* groups 4)))
           (enc (lambda (i) (string-ref $b64 i))))
      (let loop ((i 0) (o 0))
        (if (>= i n)
            out
            (let* ((b0 (bytevector-u8-ref bv i))
                   (b1 (if (< (+ i 1) n) (bytevector-u8-ref bv (+ i 1)) 0))
                   (b2 (if (< (+ i 2) n) (bytevector-u8-ref bv (+ i 2)) 0)))
              (string-set! out o (enc (quotient b0 4)))
              (string-set! out (+ o 1)
                           (enc (+ (* (remainder b0 4) 16) (quotient b1 16))))
              (string-set! out (+ o 2)
                           (if (< (+ i 1) n)
                               (enc (+ (* (remainder b1 16) 4) (quotient b2 64)))
                               #\=))
              (string-set! out (+ o 3)
                           (if (< (+ i 2) n) (enc (remainder b2 64)) #\=))
              (loop (+ i 3) (+ o 4)))))))

  (define (wasm->data-uri bv)
    (string-append "data:application/wasm;base64," (base64-encode bv)))

  ;; the fallback text must not be able to close its own tag; the JS
  ;; emitter guarantees this (string literals escape `<`), verified
  ;; here so a foreign or corrupted input fails loudly
  (define (contains-close-script? s)
    (let ((n (string-length s))
          (pat "</script"))
      (let scan ((i 0))
        (cond
         ((> (+ i 8) n) #f)
         ((let cmp ((j 0))
            (cond
             ((= j 8) #t)
             ((char=? (let ((c (string-ref s (+ i j))))
                        (if (and (char<=? #\A c) (char<=? c #\Z))
                            (integer->char (+ (char->integer c) 32))
                            c))
                      (string-ref pat j))
              (cmp (+ j 1)))
             (else #f)))
          #t)
         (else (scan (+ i 1)))))))

  (define (mount-html js-text wasm-ref rt-url)
    (when (contains-close-script? js-text)
      (error 'mount-html
                           "fallback text contains a script terminator"))
    (let ((wasm-url (if (string? wasm-ref)
                        wasm-ref
                        (wasm->data-uri wasm-ref))))
      (string-append
       "<script type=\"goeteia/js\">\n"
       js-text
       "</script>\n"
       "<script type=\"module\">\n"
       "import { loadGoeteiaAuto } from '" rt-url "';\n"
       "loadGoeteiaAuto('" wasm-url "');\n"
       "</script>\n"))))
