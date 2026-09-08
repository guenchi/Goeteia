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

;; s-expressions over WebSocket: the browser half.
;;
;; Each message is one datum -- write to send, read on receive. The
;; server half is Igropyr's ws-send-sexpr! / ws-recv-sexpr.
;;
;;   (define w (ws-connect! "ws://host/ws"
;;               (lambda (datum) ...)          ; one datum per message
;;               (lambda () ...)               ; optional: on open
;;               (lambda () ...)))             ; optional: on close
;;   (ws-send! w '(add 1 2 1/2))
;;
(library (web ws)
  (export ws-connect! ws-send! ws-close! ws-open?)
  (import (rnrs) (web js) (web rpc))

  (define (ws-connect! url on-datum . more)
    (let ((w (js-new (js-get (js-global) "WebSocket") url))
          (on-open (and (pair? more) (car more)))
          (on-close (and (pair? more) (pair? (cdr more)) (cadr more))))
      (js-set! w "onmessage"
               (lambda (ev)
                 (on-datum (rpc-parse (js->string (js-get ev "data"))))
                 (js-undefined)))
      (when on-open
        (js-set! w "onopen" (lambda (ev) (on-open) (js-undefined))))
      (when on-close
        (js-set! w "onclose" (lambda (ev) (on-close) (js-undefined))))
      w))

  (define (ws-send! w datum)
    (js-method w "send" (rpc-serialize datum)))

  (define (ws-close! w) (js-method w "close"))

  (define (ws-open? w)                  ; readyState 1 = OPEN
    (= (js->number (js-get w "readyState")) 1)))
