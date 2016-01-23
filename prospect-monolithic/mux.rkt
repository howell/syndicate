#lang racket/base
;; General multiplexer.

(provide meta-label?
         (except-out (struct-out mux) mux)
         (rename-out [mux <mux>] [make-mux mux])
         mux-add-stream
         mux-remove-stream
         mux-update-stream
         mux-route-message
         mux-interests-of
         compute-scns
         compute-affected-pids
         pretty-print-mux)

(require racket/set)
(require racket/match)
(require "../prospect/route.rkt")
(require "scn.rkt")
(require "../prospect/trace.rkt")
(require "../prospect/tset.rkt")
(require "../prospect/pretty.rkt")

;; A PID is a Nat.
;; A Label is a PID or 'meta.
;; Multiplexer private states
(struct mux (next-pid ;; PID
             routing-table ;; (Matcherof (Setof Label))
             interest-table ;; (HashTable Label Matcher)
             )
  #:transparent
  #:methods gen:prospect-pretty-printable
  [(define (prospect-pretty-print m [p (current-output-port)])
     (pretty-print-mux m p))])

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define (meta-label? x) (eq? x 'meta))

(define (make-mux)
  (mux 0 (trie-empty) (hash)))

(define (mux-add-stream m initial-scn)
  (define new-pid (mux-next-pid m))
  (mux-update-stream (struct-copy mux m [next-pid (+ new-pid 1)])
                     new-pid
                     initial-scn))

(define (mux-remove-stream m label)
  (mux-update-stream m label (scn (trie-empty))))

(define (mux-update-stream m label new-scn)
  (define old-interests (mux-interests-of m label))
  (define old-routing-table (mux-routing-table m))
  (define new-interests (label-interests (scn-trie new-scn) (datum-tset label)))
  (define new-routing-table (trie-union (trie-subtract old-routing-table old-interests)
                                        new-interests))
  (define aggregate-assertions (trie-union old-interests new-interests))
  (values (struct-copy mux m
                       [routing-table new-routing-table]
                       [interest-table (if (trie-empty? new-interests)
                                           (hash-remove (mux-interest-table m) label)
                                           (hash-set (mux-interest-table m) label new-interests))])
          label
          new-scn ;; unnecessary?
          aggregate-assertions))

(define (compute-scns old-m new-m label s aggregate-assertions)
  (define old-routing-table (mux-routing-table old-m))
  (define new-routing-table (mux-routing-table new-m))
  (define affected-pids
    (let ((pids (compute-affected-pids old-routing-table aggregate-assertions))) ;; hmm
      (tset-remove (tset-add pids label) 'meta))) ;; TODO: removing meta is weird
  (values (for/list [(pid (tset->list affected-pids))]
            (cons pid (scn (biased-intersection new-routing-table (mux-interests-of new-m pid)))))
          (and (not (meta-label? label))
               (drop-scn (scn (strip-interests new-routing-table))))))

(define (compute-affected-pids routing-table cover)
  (trie-match-trie cover
		   (trie-step routing-table struct:observe)
		   #:seed (datum-tset)
		   #:combiner (lambda (v1 v2 acc) (tset-union v2 acc))
		   #:left-short (lambda (v r acc)
				  (tset-union acc (success-value (trie-step r EOS))))))

(define (mux-route-message m body)
  (if (trie-lookup (mux-routing-table m) body #f) ;; some other stream has declared body
      '()
      (tset->list (trie-lookup (mux-routing-table m) (observe body) (datum-tset)))))

(define (mux-interests-of m label)
  (hash-ref (mux-interest-table m) label (trie-empty)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define (pretty-print-mux m [p (current-output-port)])
  (match-define (mux next-pid routing-table interest-table) m)
  (fprintf p "MUX:\n")
  (fprintf p " - ~a labelled entities with claims\n" (hash-count interest-table))
  (fprintf p " - next label: ~a\n" next-pid)
  (fprintf p " - routing-table:\n")
  (display (indented-port-output 3 (lambda (p) (pretty-print-trie routing-table p))) p)
  (newline p))