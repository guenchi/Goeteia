;; A streaming chat feed over (web scroll): each message's height is
;; typeset BEFORE it mounts (no reflow-forcing measurement), only the
;; visible window lives in the DOM, and the view sticks to the bottom
;; while messages stream in -- scroll up and it stays put.
(import (rnrs) (web js) (web dom) (web scroll))

(define vs (make-vscroll (get-element-by-id "app")
                         420 560 "15px system-ui" 22))

(define phrases
  '#("ok"
     "short reply"
     "a somewhat longer message that wraps to a few lines once the column runs out of width, like chat messages tend to do"
     "多语言消息也一样：中日文在任意表意文字之间断行，无需空格，排版器逐码点累加宽度即可。"
     "streaming models emit tokens continuously, so feeds keep appending while you read -- the scroller has to know each height before mounting"
     "https://goeteia.dev/an/unbroken/token/that/must/split/inside/because/nothing/breaks/naturally"
     "混排 also works: CJK 与 latin 的混合行、长词内断行、硬换行\n都走同一个纯函数排版器。"))

(define seed 7)
(define (rnd! n)
  (set! seed (remainder (+ (* seed 1103515245) 12345) 2147483648))
  (remainder seed n))

(define count 0)
(define (push!)
  (set! count (+ count 1))
  (vscroll-append!
   vs (string-append (number->string count) "  "
                     (vector-ref phrases (rnd! (vector-length phrases))))))

(push!)
(js-method (js-global) "setInterval"
           (lambda _ (push!) (js-undefined))
           450)
