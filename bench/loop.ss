(let loop ((i 0) (sum 0))
  (if (= i 10000000)
      (begin (display sum) (newline))
      (loop (+ i 1) (+ sum i))))
