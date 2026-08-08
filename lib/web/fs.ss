;; Files as bytes, through the host's file shims.
;;
;; The shim protocol underneath is one call per byte: a path is
;; pushed to the host a byte at a time and then opened, and reads and
;; writes move single bytes through the returned descriptor.  The
;; prelude already wraps that as R6RS character ports; this library
;; names the OTHER half -- whole files in and out of staging memory,
;; which is where every decoder in `(gfx ...)` wants its input and
;; where every encoder leaves its output.  Before it existed, each
;; caller open-coded `%path-byte` / `%open-read` / `%fread` again,
;; and the protocol was written out in three places.
;;
;;   (define base (fx-alloc! 900000))            ; the caller allocates
;;   (define n (fs-slurp! "asset.glb" base 900000))
;;   (define g (gltf-parse base n))
;;
;; Staging memory is NOT allocated here.  There is exactly one bump
;; heap and exactly one water level, and `(gfx fx)` owns them; a
;; second allocator would hand out the same bytes twice.  So the
;; destination is the caller's, which also keeps this library on the
;; `(web ...)` side of the stack -- it imports nothing but `(rnrs)`,
;; and a page that reads a file does not drag the GL harness in.
;;
;; HOST BODY.  A filesystem is not something every host has: a
;; browser has none, and neither do the verify and compile hosts.
;; There, every open fails, and this library says so BY NAME rather
;; than trapping deeper down:
;;
;;   `fs-exists?` answers #f.  It never raises -- on a host with no
;;   filesystem nothing exists, which is the true answer.
;;
;;   The readers raise naming the path: a failed read-open means
;;   either that the file is missing or that the host has no
;;   filesystem, and the two are indistinguishable from in here (both
;;   are a -1 descriptor).  The message says both.
;;
;;   The writers raise naming the host: a failed WRITE-open is not
;;   ambiguous.  A host with a filesystem accepts the open and defers
;;   any failure to the close (that is where the bytes are written),
;;   so a -1 there means there is no filesystem at all.
;;
;; Copyright (c) 2026 guenchi. MIT license; see LICENSE.
(library (web fs)
  (export fs-exists? fs-size fs-slurp! fs-spit!
          fs-slurp-string fs-spit-string!)
  (import (rnrs))

  ;; A Goeteia string holds one character per UTF-8 byte, so pushing
  ;; `char->integer' of each character is the path's UTF-8 encoding.
  (define ($fs-path who s)
    (unless (string? s)
      (error who "a path is a string" s))
    (string-for-each (lambda (c) (%path-byte (char->integer c))) s))

  (define ($fs-open-read who path)
    ($fs-path who path)
    (let ((fd (%open-read)))
      (when (< fd 0)
        (error who
               "cannot open for reading: no such file, or this host provides no filesystem"
               path))
      fd))

  (define ($fs-open-write who path)
    ($fs-path who path)
    (let ((fd (%open-write)))
      (when (< fd 0)
        (error who "this host provides no filesystem" path))
      fd))

  (define ($fs-base who base)
    (unless (and (integer? base) (>= base 0))
      (error who "a staging address is a non-negative integer" base))
    base)

  ;; the optional capacity, or #f for "bounded only by the memory"
  (define ($fs-cap who rest)
    (if (null? rest)
        #f
        (let ((cap (car rest)))
          (unless (and (integer? cap) (>= cap 0))
            (error who "a capacity is a non-negative integer" cap))
          cap)))

  ;; -> #t / #f, and never anything else: a host with no filesystem
  ;; holds no files, so #f is the true answer there and not an error.
  (define (fs-exists? path)
    ($fs-path 'fs-exists? path)
    (let ((fd (%open-read)))
      (if (< fd 0) #f (begin (%fclose fd) #t))))

  ;; The file's length in bytes.  This reads the whole file to count
  ;; it -- the host offers no stat -- so a caller who is about to
  ;; slurp the file anyway should slurp it and take the count that
  ;; `fs-slurp!' returns rather than ask twice.
  (define (fs-size path)
    (let ((fd ($fs-open-read 'fs-size path)))
      (let loop ((n 0))
        (if (< (%fread fd) 0)
            (begin (%fclose fd) n)
            (loop (+ n 1))))))

  ;; Read the whole file into staging memory at `base'.  -> the byte
  ;; count.
  ;;
  ;;   (fs-slurp! path base)          ; bounded only by the memory
  ;;   (fs-slurp! path base cap)      ; bounded by what you allocated
  ;;
  ;; A file that outgrows either bound is a named error at the byte
  ;; that would leave it, not a trap with no path in it and not a
  ;; quiet overwrite of whatever fx-alloc! handed out next.  The two
  ;; bounds are reported apart because they call for different fixes:
  ;; one is a block that was allocated too small, the other is a
  ;; memory that has to grow.
  (define (fs-slurp! path base . rest)
    (let* ((base ($fs-base 'fs-slurp! base))
           (cap ($fs-cap 'fs-slurp! rest))
           (mem (* 65536 (%mem-size)))
           (fd ($fs-open-read 'fs-slurp! path)))
      (let loop ((i 0))
        (let ((b (%fread fd)))
          (cond
           ((< b 0) (%fclose fd) i)
           ((and cap (>= i cap))
            (%fclose fd)
            (error 'fs-slurp! "the file does not fit the space given for it"
                   path cap))
           ((>= (+ base i) mem)
            (%fclose fd)
            (error 'fs-slurp! "the file would leave the staging memory" path))
           (else (%mem-u8-set! (+ base i) b) (loop (+ i 1))))))))

  ;; Write `len' bytes of staging memory starting at `base'.  -> len.
  (define (fs-spit! path base len)
    (let ((base ($fs-base 'fs-spit! base)))
      (unless (and (integer? len) (>= len 0))
        (error 'fs-spit! "a length is a non-negative integer" len))
      (when (> (+ base len) (* 65536 (%mem-size)))
        (error 'fs-spit! "the range asked for leaves the staging memory"
               base len))
      (let ((fd ($fs-open-write 'fs-spit! path)))
        (let loop ((i 0))
          (if (= i len)
              (begin (%fclose fd) len)
              (begin (%fwrite fd (%mem-u8-ref (+ base i)))
                     (loop (+ i 1))))))))

  ;; The whole file as a Scheme string -- the shape `(web json)'
  ;; reads.  A Goeteia string is UTF-8 bytes and this moves one byte
  ;; per character, so a UTF-8 file arrives unchanged.
  (define (fs-slurp-string path)
    (let ((fd ($fs-open-read 'fs-slurp-string path)))
      (let loop ((acc '()))
        (let ((b (%fread fd)))
          (if (< b 0)
              (begin (%fclose fd) (list->string (reverse acc)))
              (loop (cons (integer->char b) acc)))))))

  ;; -> the byte count written.
  (define (fs-spit-string! path s)
    (unless (string? s)
      (error 'fs-spit-string! "not a string" s))
    (let ((fd ($fs-open-write 'fs-spit-string! path))
          (n (string-length s)))
      (let loop ((i 0))
        (if (= i n)
            (begin (%fclose fd) n)
            (begin (%fwrite fd (char->integer (string-ref s i)))
                   (loop (+ i 1)))))))
  )
