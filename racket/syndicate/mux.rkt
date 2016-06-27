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
         ;; mux-focus-event
         compute-patches
         compute-affected-pids
         pretty-print-mux)

(require racket/set)
(require racket/match)
(require "trie.rkt")
(require "patch.rkt")
(require "trace.rkt")
(require "tset.rkt")
(require "pretty.rkt")

;; A PID is a Nat.
;; A Label is a PID or 'meta.
;; Multiplexer private states
(struct mux (next-pid ;; PID
             routing-table ;; (Matcherof (Setof Label))
             interest-table ;; (HashTable Label Matcher)
             )
  #:transparent
  #:methods gen:syndicate-pretty-printable
  [(define (syndicate-pretty-print m [p (current-output-port)])
     (pretty-print-mux m p))])

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define (meta-label? x) (eq? x 'meta))

(define (make-mux)
  (mux 0 trie-empty (hash)))

(define (mux-add-stream m initial-patch)
  (define new-pid (mux-next-pid m))
  (mux-update-stream (struct-copy mux m [next-pid (+ new-pid 1)])
                     new-pid
                     initial-patch))

(define (mux-remove-stream m label)
  (mux-update-stream m label (patch trie-empty (pattern->trie '<mux-remove-stream> ?))))

(define (mux-update-stream m label delta-orig)
  (define old-interests (mux-interests-of m label))
  (define old-routing-table (mux-routing-table m))
  (define delta (limit-patch (label-patch delta-orig (datum-tset label)) old-interests))
  (define new-interests (apply-patch old-interests delta))
  ;; CONDITION at this point: delta has been labelled and limited to
  ;; be minimal with respect to existing interests of its label.
  (define delta-aggregate (compute-aggregate-patch delta label old-routing-table))
  (define new-routing-table (apply-patch old-routing-table delta))
  (values (struct-copy mux m
                       [routing-table new-routing-table]
                       [interest-table (if (trie-empty? new-interests)
                                           (hash-remove (mux-interest-table m) label)
                                           (hash-set (mux-interest-table m) label new-interests))])
          label
          delta
          delta-aggregate))

(define at-meta-everything (pattern->trie '<at-meta-everything> (at-meta ?)))

(define (echo-cancelled-trie t)
  (trie-subtract t
                 at-meta-everything
                 #:combiner (lambda (v1 v2)
                              (if (tset-member? v1 'meta)
                                  (trie-success only-meta-tset)
                                  trie-empty))))

(define (compute-patches old-m new-m label delta delta-aggregate)
  (define delta-aggregate/no-echo
    (if (meta-label? label)
        delta
        (patch-without-at-meta delta-aggregate)))
  (define old-routing-table (mux-routing-table old-m))
  (define new-routing-table (mux-routing-table new-m))
  (define affected-pids
    (let ((pids (compute-affected-pids old-routing-table delta-aggregate/no-echo)))
      (tset-remove (tset-add pids label) 'meta))) ;; TODO: removing meta is weird
  (values (for/list [(pid (tset->list affected-pids))]
            (cond [(equal? pid label)
                   (define feedback
                     (patch-union
                      (patch (echo-cancelled-trie
                              (biased-intersection new-routing-table (patch-added delta)))
                             (echo-cancelled-trie
                              (biased-intersection old-routing-table (patch-removed delta))))
                      (patch (biased-intersection (patch-added delta-aggregate/no-echo)
                                                  (mux-interests-of new-m label))
                             (biased-intersection (patch-removed delta-aggregate/no-echo)
                                                  (mux-interests-of old-m label)))))
                   (cons label feedback)]
                  [else
                   (cons pid (view-patch delta-aggregate/no-echo (mux-interests-of old-m pid)))]))
          (and (not (meta-label? label))
               (drop-patch
                (compute-aggregate-patch delta label old-routing-table #:remove-meta? #t)))))

(define (compute-affected-pids routing-table delta)
  (define cover (trie-union (patch-added delta) (patch-removed delta)))
  (trie-match-trie cover
		   (trie-step routing-table observe-parenthesis)
		   #:seed datum-tset-empty
		   #:combiner (lambda (v1 v2 acc) (tset-union v2 acc))))

(define (mux-route-message m body)
  (if (trie-lookup (mux-routing-table m) body #f #:wildcard-union (lambda (a b) (or a b)))
      ;; some other stream has declared body
      '()
      (tset->list (trie-lookup (mux-routing-table m)
                               (observe body)
                               datum-tset-empty
                               #:wildcard-union tset-union))))

(define (mux-interests-of m label)
  (hash-ref (mux-interest-table m) label trie-empty))

;; There's a problem with mux-focus-event in most circumstances: often
;; you will want to focus incoming events with respect to some
;; locally-stored memory of interests. But that local memory may be
;; *ahead* of the incoming event stream! There's the round-trip
;; latency between the actor and the dataspaces where patch actions
;; are applied. This could lead to unwanted discarding of retractions,
;; and even of assertions in cases of quick pulses of interest.
;;
;; ;; Mux Label Event -> (Option Event)
;; (define (mux-focus-event m label e)
;;   (define interests (mux-interests-of m label))
;;   (match e
;;     [(patch added removed)
;;      (define p (patch (biased-intersection added interests)
;;                       (biased-intersection removed interests)))
;;      (and (patch-non-empty? p) p)]
;;     [(message body)
;;      (and (trie-lookup interests (observe body) #f) e)]))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define (pretty-print-mux m [p (current-output-port)])
  (match-define (mux next-pid routing-table interest-table) m)
  (fprintf p "MUX:\n")
  (fprintf p " - ~a labelled entities with claims\n" (hash-count interest-table))
  (fprintf p " - next label: ~a\n" next-pid)
  (fprintf p " - routing-table:\n")
  (display (indented-port-output 3 (lambda (p) (pretty-print-trie routing-table p))) p)
  (newline p))
