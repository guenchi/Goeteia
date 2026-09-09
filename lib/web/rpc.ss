;; Copyright 2026 guenchi
;;
;; Licensed under the Apache License, Version 2.0 (the "License");
;; you may not use this file except in compliance with the License.
;; You may obtain a copy of the License at
;;
;;     http://www.apache.org/licenses/LICENSE-2.0
;;
;; Unless required by applicable law or agreed to in writing, software
;; distributed under the License is distributed on an "AS IS" BASIS,
;; WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
;; See the License for the specific language governing permissions and
;; limitations under the License.

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
(library (web rpc)
  (export rpc rpc! rpc-get rpc-serialize rpc-parse)
  (import (rnrs) (web js) (web fetch) (web sexpr))

  ;; (web sexpr) is the restricted, depth-limited codec -- Igropyr's
  ;; extended wire format, not the host read/write: no #-syntax
  ;; surprises, flonums as #f8"<base64>" (their eight IEEE bytes, so a
  ;; signed zero and a NaN's payload cross intact), bytevectors as
  ;; #vu8"<base64>".
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
