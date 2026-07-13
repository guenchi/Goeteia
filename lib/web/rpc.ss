;; s-expression RPC over HTTP: the browser half.
;;
;; Both ends speak Scheme; the wire is Igropyr's (igropyr sexpr)
;; EXTENDED format, mirrored byte-for-byte here by (web sexpr) -- so
;; bytevectors cross as #vu8"<base64>". The server half is (igropyr
;; sexpr) + app-rpc -- requests are (tag arg ...), replies are (ok ...)
;; or (error ...), everything stays data.
;;
;;   (rpc! "/rpc" '(get-user 42)
;;     (lambda (reply) ...)          ; (ok (user (id . 42) ...))
;;     (lambda (e) ...))             ; optional: network/parse failure
;;
;; Callback style until JSPI lands (then a direct-style rpc can wrap
;; this). Exact integers and ratios cross intact -- no float
;; approximation. The wire whitelist is lists, symbols, strings, exact
;; integers and ratios, booleans, vectors and bytevectors; dispatch on
;; tags, never evaluate payloads.
;;
;; Copyright (c) 2026 guenchi. MIT license; see LICENSE.
(library (web rpc)
  (export rpc rpc! rpc-get rpc-serialize rpc-parse)
  (import (rnrs) (web js) (web fetch) (web sexpr))

  ;; (web sexpr) is the restricted, depth-limited codec -- Igropyr's
  ;; extended wire format, not the host read/write (no #-syntax
  ;; surprises, no flonums, bytevectors as #vu8"<base64>").
  (define (rpc-serialize datum) (sexpr->string datum))

  (define (rpc-parse text) (string->sexpr text))

  ;; direct style over JSPI: the call reads like a blocking one --
  ;;   (let ((reply (rpc "/rpc" '(get-user 42)))) ...)
  ;; needs (fetch-direct?); otherwise use the callback rpc! below
  (define (rpc url datum)
    (rpc-parse (http-post url (rpc-serialize datum) "application/sexpr")))

  ;; REST-style resources: GET a datum -- any route serving
  ;; application/sexpr (Igropyr's send-sexpr!), not just app-rpc
  (define (rpc-get url)
    (rpc-parse (http-get url)))

  (define (rpc! url datum on-reply . more)
    (let ((on-error (if (pair? more) (car more) (lambda (e) (js-undefined))))
          (opts (js-eval "({method:'POST',headers:{'Content-Type':'application/sexpr'}})")))
      (js-set! opts "body" (rpc-serialize datum))
      (js-method
       (js-method
        (js-method (js-call (js-get (js-global) "fetch") (js-undefined)
                            url opts)
                   "then" (lambda (resp) (js-method resp "text")))
        "then" (lambda (text)
                 (on-reply (rpc-parse (js->string text)))
                 (js-undefined)))
       "catch" (lambda (e) (on-error e) (js-undefined))))))
