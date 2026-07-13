;; expect: #t
;; (web typeset): DOM-free line breaking. Pure, fully verifiable.
(import (rnrs) (web typeset))

(define (m s) 1)                        ; every code point 1 unit wide

(define (texts l) (map line-text (layout-lines l)))
(define (widths l) (map line-width (layout-lines l)))
(define (same? a b)
  (or (and (null? a) (null? b))
      (and (pair? a) (pair? b)
           (equal? (car a) (car b))
           (same? (cdr a) (cdr b)))))

(and
 ;; fits on one line: nothing breaks, glue keeps its width
 (let ((l (layout (prepare "hello world" m) 100 10)))
   (and (= (layout-line-count l) 1)
        (= (layout-height l) 10)
        (same? (texts l) '("hello world"))
        (same? (widths l) '(11))))
 ;; soft wrap at the space; the space vanishes from both lines
 (let ((l (layout (prepare "hello world" m) 5 10)))
   (and (= (layout-line-count l) 2)
        (= (layout-height l) 20)
        (same? (texts l) '("hello" "world"))
        (same? (widths l) '(5 5))
        (= (line-y (car (layout-lines l))) 0)
        (= (line-y (cadr (layout-lines l))) 10)))
 ;; greedy first-fit: exactly full is not a wrap; one unit less is
 (same? (texts (layout (prepare "aa bb cc" m) 8 10)) '("aa bb cc"))
 (same? (texts (layout (prepare "aa bb cc" m) 7 10)) '("aa bb" "cc"))
 ;; hard breaks: kept verbatim, trailing newline yields an empty line
 (same? (texts (layout (prepare "a\nb" m) 100 10)) '("a" "b"))
 (same? (texts (layout (prepare "a\n" m) 100 10)) '("a" ""))
 ;; a text is never zero lines
 (let ((l (layout (prepare "" m) 100 10)))
   (and (= (layout-line-count l) 1) (= (layout-height l) 10)
        (same? (texts l) '(""))))
 ;; spaces after a hard break survive; spaces at a soft wrap don't
 (same? (texts (layout (prepare "a\n b" m) 100 10)) '("a" " b"))
 ;; a word wider than the line breaks inside, by code point
 (same? (texts (layout (prepare "abcdefgh" m) 3 10)) '("abc" "def" "gh"))
 (same? (widths (layout (prepare "abcdefgh" m) 3 10)) '(3 3 2))
 ;; CJK: breaks fall between ideographs, no space needed
 (same? (texts (layout (prepare "汉字排版" m) 2 10)) '("汉字" "排版"))
 (same? (texts (layout (prepare "ab汉字" m) 3 10)) '("ab汉" "字"))
 ;; natural width: widest hard-break-only line
 (= (prepared-width (prepare "hello world" m)) 11)
 (= (prepared-width (prepare "hello\nworld!" m)) 6)
 ;; per-code-point widths flow through words
 (let ((wide (lambda (s) (if (string=? s "W") 3 1))))
   (same? (widths (layout (prepare "iW i" wide) 100 10)) '(6)))
 ;; measure runs once per distinct code point
 (let ((calls 0))
   (prepare "aaaa bb" (lambda (s) (set! calls (+ calls 1)) 1))
   (= calls 3))
 ;; string-fold-cp walks code points with byte positions
 (same? (reverse (string-fold-cp
                  (lambda (acc cp st n) (cons (list cp st n) acc))
                  '() "a汉b"))
        '((97 0 1) (27721 1 3) (98 4 1)))
 (eq? 'seed (string-fold-cp (lambda (acc cp st n) 'other) 'seed ""))
 ;; kinsoku: closing punctuation never starts a line -- it merges
 ;; into the box before it and they wrap together
 (same? (texts (layout (prepare "汉字、排版。" m) 3 10))
        '("汉字、" "排版。"))
 (same? (texts (layout (prepare "汉字、排版。" m) 2 10))
        '("汉" "字、" "排" "版。"))
 ;; opening brackets never end a line -- they stick to the next box
 (same? (texts (layout (prepare "看「书」呢" m) 3 10))
        '("看" "「书」" "呢"))
 ;; the same rule holds against latin boxes and ellipses
 (same? (texts (layout (prepare "abc、def" m) 4 10))
        '("abc、" "def"))
 (same? (texts (layout (prepare "so… yes" m) 3 10))
        '("so…" "yes")))
