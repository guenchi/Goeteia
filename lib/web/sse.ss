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

;; Server-sent events carrying s-expressions: the browser half.
;;
;; The server (Igropyr's sse-send-sexpr!) frames one datum per event;
;; EventSource rejoins multi-line data, so datums with embedded
;; newlines survive. One-way pushes: notifications, progress streams.
;;
;;   (define es (sse-connect! "/events"
;;                (lambda (datum) ...)          ; one datum per event
;;                (lambda () ...)))             ; optional: on error
;;   (sse-close! es)
;;
(library (web sse)
  (export sse-connect! sse-close!)
  (import (rnrs) (web js) (web rpc))

  (define (sse-connect! url on-datum . more)
    (let ((es (js-new (js-get (js-global) "EventSource") url)))
      (js-set! es "onmessage"
               (lambda (ev)
                 (on-datum (rpc-parse (js->string (js-get ev "data"))))
                 (js-undefined)))
      (when (pair? more)
        (js-set! es "onerror"
                 (lambda (ev) ((car more)) (js-undefined))))
      es))

  (define (sse-close! es) (js-method es "close")))
