;; expect: 10
(do ((i 1 (+ i 1))
     (sum 0 (+ sum i)))
    ((< 4 i) sum))
