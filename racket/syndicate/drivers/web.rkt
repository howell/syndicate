#lang syndicate
;; More general web driver: supports normal HTTP as well as websockets.

(provide (struct-out web-virtual-host)
         (struct-out web-resource)
         url->resource
         resource->url

         string->resource-path
         resource-path->string
         append-resource-path

         (struct-out web-request)
         (struct-out web-request-peer-details)
         (struct-out web-request-header)
         (struct-out web-request-cookie)
         web-request-header-content-type
         web-request-header-websocket-upgrade?

         (rename-out [web-response-header <web-response-header>])
         (struct-out/defaults [make-web-response-header web-response-header])
         web-response-header-code-type
         web-response-successful?
         (struct-out web-response-complete)
         (struct-out web-response-chunked)
         (rename-out [web-response-websocket <web-response-websocket>])
         (struct-out/defaults [make-web-response-websocket web-response-websocket])

         (struct-out web-response-chunk)
         (struct-out websocket-message)

         web-request-incoming
         web-request-get
         websocket-connection-closed
         websocket-message-recv
         websocket-message-send!
         web-request-send!
         web-request-send!*
         web-respond/bytes!
         web-respond/string!
         web-respond/xexpr!
         web-redirect!

         spawn-web-driver)

(define-logger syndicate/drivers/web)

(require net/url)
(require net/rfc6455)
(require net/rfc6455/conn-api)
(require net/rfc6455/dispatcher)
(require net/http-client)
(require racket/dict)
(require racket/exn)
(require racket/tcp)
(require racket/set)
(require racket/async-channel)
(require (only-in racket/bytes bytes-join))
(require (only-in racket/list flatten))
(require (only-in racket/port port->bytes))
(require web-server/http/bindings)
(require web-server/http/cookie)
(require web-server/http/cookie-parse)
(require web-server/http/request)
(require web-server/http/request-structs)
(require web-server/http/response)
(require web-server/http/response-structs)
(require web-server/private/connection-manager)
(require (only-in web-server/private/util lowercase-symbol!))
(require web-server/dispatchers/dispatch)
(require struct-defaults)
(require xml)

(module+ test (require rackunit))

(require/activate "timer.rkt")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(struct web-virtual-host (scheme name port) #:prefab)
(struct web-resource (virtual-host path) #:prefab)

(struct web-request (id direction header* body) #:prefab)
(struct web-request-peer-details (id local-ip local-port remote-ip remote-port) #:prefab)
(struct web-request-header (method resource headers query) #:prefab)
(struct web-request-cookie (id name value domain path) #:prefab)

(struct web-response-header (code message last-modified-seconds mime-type headers) #:prefab)
(struct web-response-complete (id header body) #:prefab)
(struct web-response-chunked (id header) #:prefab)
(struct web-response-websocket (id headers) #:prefab)

(struct web-response-chunk (id bytes) #:prefab)
(struct websocket-message (id direction body) #:prefab)

(define (web-request-header-content-type req)
  (dict-ref (web-request-header-headers req) 'content-type #f))

(define (web-request-header-websocket-upgrade? req)
  (equal? (string-downcase (dict-ref (web-request-header-headers req) 'upgrade "")) "websocket"))

(begin-for-declarations
  (define-struct-defaults make-web-response-header web-response-header
    (#:code [web-response-header-code 200]
     #:message [web-response-header-message #"OK"]
     #:last-modified-seconds [web-response-header-last-modified-seconds (current-seconds)]
     #:mime-type [web-response-header-mime-type #"text/html"]
     #:headers [web-response-header-headers '()]))
  (define-struct-defaults make-web-response-websocket web-response-websocket
    (#:headers [web-response-websocket-headers '()])))

(define (web-response-header-code-type rh)
  (if (not rh) ;; network failure of some kind; respondent did not respond
      'network-failure
      (let ((code (web-response-header-code rh)))
        (cond
          [(<= 100 code 199) 'informational]
          [(<= 200 code 299) 'successful]
          [(<= 300 code 399) 'redirection]
          [(<= 400 code 499) 'client-error]
          [(<= 500 code 599) 'server-error]
          [else 'other]))))

(define (web-response-successful? rh)
  (eq? (web-response-header-code-type rh) 'successful))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Ground-level communication messages

(struct web-raw-request (id port connection addresses req control-ch) #:prefab)
(struct web-raw-client-conn (id connection) #:prefab)
(struct web-incoming-message (id message) #:prefab)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define-event-expander web-request-incoming
  (syntax-rules ()
    [(_ (id req) vh method path)
     (web-request-incoming (id req) vh method path _)]
    [(_ (id req) vh method path body)
     (message (web-request ($ id _)
                           'inbound
                           ($ req (web-request-header method (web-resource vh `path) _ _))
                           body))]))

(define-event-expander web-request-get
  (syntax-rules ()
    [(_ (id req) vh path)
     (web-request-incoming (id req) vh 'get path)]))

(define-event-expander websocket-connection-closed
  (syntax-rules ()
    [(_ id)
     (retracted (observe (websocket-message id 'outbound _)))]))

(define-event-expander websocket-message-recv
  (syntax-rules ()
    [(_ id str)
     (message (websocket-message id 'inbound str))]))

(define (websocket-message-send! id str)
  (send! (websocket-message id 'outbound str)))

(define (web-request-send! id url-string
                           #:method [method 'GET]
                           #:headers [headers '()]
                           #:query [query #f]
                           #:body [body #""])
  (define u (string->url url-string))
  (web-request-send!* id (url->resource u)
                      #:method method
                      #:headers headers
                      #:query (or query (url-query u))
                      #:body body))

(define (web-request-send!* id resource
                            #:method [method 'GET]
                            #:headers [headers '()]
                            #:query [query '()]
                            #:body [body #f])
  (send! (web-request id 'outbound (web-request-header method resource headers query) body)))

(define (web-respond/bytes! id #:header [header (make-web-response-header)] body-bytes)
  (send! (web-response-complete id header body-bytes)))

(define (web-respond/string! id #:header [header (make-web-response-header)] body-string)
  (web-respond/bytes! id #:header header (string->bytes/utf-8 body-string)))

(define (web-respond/xexpr! id
                            #:header [header (make-web-response-header)]
                            #:preamble [preamble #"<!DOCTYPE html>"]
                            body-xexpr)
  (web-respond/bytes! id #:header header
                      (bytes-append preamble
                                    (string->bytes/utf-8 (xexpr->string body-xexpr)))))

(define (web-redirect! id location
                       #:code [code 303]
                       #:message [message #"Redirect"]
                       #:content-type [content-type "text/html"]
                       #:headers [headers '()]
                       #:body [body `(html (body (a ((href ,location))
                                                    "Moved to " ,location)))])
  (web-respond/xexpr! id
                      #:header (make-web-response-header
                                #:code code
                                #:message message
                                #:headers (list* (cons 'location location)
                                                 (cons 'content-type content-type)
                                                 headers))
                      body))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define web-server-max-waiting (make-parameter 511)) ;; sockets
(define web-server-connection-manager (make-parameter #f))
(define web-server-initial-connection-timeout (make-parameter 30)) ;; seconds

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define (url->resource u)
  (web-resource (web-virtual-host (url-scheme u)
                                  (url-host u)
                                  (url-port u))
                (format-url-path u)))

(define (resource->url r #:query [query '()])
  (match-define (web-resource (web-virtual-host scheme host port) path) r)
  (url scheme
       #f
       host
       port
       #t
       (resource-path->url-path path)
       query
       #f))

(define (string->resource-path str)
  (define-values (_absolute? rp) (string->resource-path* str))
  rp)

(define (string->resource-path* str)
  (define u (string->url str))
  (values (url-path-absolute? u)
          (url-path->resource-path (url-path u))))

(define (resource-path->string rp #:absolute? [absolute? #t])
  (url->string
   (url #f #f #f #f absolute? (resource-path->url-path rp) '() #f)))

(define (url-path->resource-path up)
  (define elements (for/list [(p (in-list up))]
                     (match-define (path/param path-element params) p)
                     (list* path-element params)))
  (foldr (lambda (e acc) (append e (list acc))) '() elements))

(define (resource-path->url-path p)
  (match p
    ['() '()]
    [(list d par ... rest)
     (cons (path/param d par) (resource-path->url-path rest))]))

(module+ test
  (check-equal? (string->resource-path "/foo;p/bar") '("foo" "p" ("bar" ())))
  (check-equal? (string->resource-path  "foo;p/bar") '("foo" "p" ("bar" ())))
  (check-equal? (resource-path->string #:absolute? #t '("foo" "p" ("bar" ()))) "/foo;p/bar")
  (check-equal? (resource-path->string #:absolute? #f '("foo" "p" ("bar" ())))  "foo;p/bar"))

(define (append-resource-path p1 p2)
  (match p1
    ['() p2]
    [(list "" '()) p2]
    [(list pieces ... next) (append pieces (list (append-resource-path next p2)))]))

(module+ test
  (check-equal? (append-resource-path '() '("c" ("d" ()))) '("c" ("d" ())))
  (check-equal? (append-resource-path '("" ()) '("c" ("d" ()))) '("c" ("d" ())))
  (check-equal? (append-resource-path '("a" "x" ("b" ())) '("c" ("d" ())))
                '("a" "x" ("b" ("c" ("d" ())))))
  (check-equal? (append-resource-path '("a" "x" ("b" ("" ()))) '("c" ("d" ())))
                '("a" "x" ("b" ("c" ("d" ()))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define (spawn-web-driver)
  (spawn #:name 'web-server-manager
         (during/spawn (web-virtual-host "http" _ $port)
                       #:name (list 'web-server port)
                       (setup-web-server "http"
                                         (or (web-server-connection-manager)
                                             (start-connection-manager))
                                         port)))
  (spawn #:name 'web-client-manager
         (on (message (web-request $id 'outbound $req $body))
             (spawn #:name (list 'web-client id)
                    (do-client-request id req body)))))

(define (setup-web-server scheme cm port)
  (define listener (tcp-listen port (web-server-max-waiting) #t))
  (define listener-control (make-channel))
  (thread (lambda ()
            (let loop ()
              (sync (handle-evt (tcp-accept-evt listener)
                                (lambda (ports)
                                  (handle-incoming-connection port cm ports)
                                  (loop)))
                    (handle-evt listener-control
                                (match-lambda
                                  [(list 'quit k-ch)
                                   (tcp-close listener)
                                   (channel-put k-ch (void))]))))))

  (on-start (log-syndicate/drivers/web-info "Starting HTTP listener on port ~v" port))

  (on-stop (define k-ch (make-channel))
           (log-syndicate/drivers/web-info "Stopping HTTP listener on port ~v" port)
           (channel-put listener-control (list 'quit k-ch))
           (channel-get k-ch)
           (log-syndicate/drivers/web-info "Stopped HTTP listener on port ~v" port))

  (on (message (inbound (web-raw-request $id port $conn $addresses $lowlevel-req $control-ch)))
      (define web-req (web-request id
                                   'inbound
                                   (web-request-header
                                    (string->symbol (string-downcase
                                                     (bytes->string/latin-1
                                                      (request-method lowlevel-req))))
                                    (web-resource (req->virtual-host scheme lowlevel-req port)
                                                  (format-url-path (request-uri lowlevel-req)))
                                    (request-headers lowlevel-req)
                                    (url-query (request-uri lowlevel-req)))
                                   (request-post-data/raw lowlevel-req)))
      (spawn #:name (list 'web-req id)
             (for [(c (request-cookies lowlevel-req))]
               (match-define (client-cookie n v d p) c)
               (assert (web-request-cookie id n v d p)))
             (match-let ([(list Lip Lport Rip Rport) addresses])
               (assert (web-request-peer-details id Lip Lport Rip Rport)))
             (on-start (send! (set-timer (list 'web-req id) 100 'relative))
                       (send! web-req))
             ;; TODO: protocol for 500 Internal server error
             (stop-when (message (timer-expired (list 'web-req id) _))
                        (do-response-complete control-ch id header-404 '()))
             (stop-when (message (web-response-complete id $rh $body))
                        (do-response-complete control-ch id rh body))
             (stop-when (asserted (web-response-chunked id $rh))
                        (do-response-chunked control-ch id rh))
             (stop-when (asserted (web-response-websocket id $headers))
                        (do-response-websocket control-ch id headers)))))

(define header-404 (make-web-response-header #:code 404 #:message #"Not found"))

(define (do-response-complete control-ch id rh constree-of-bytes)
  (match-define (web-response-header code resp-message last-modified-seconds mime-type headers) rh)
  (channel-put control-ch
               (list 'response
                     (response/full code
                                    resp-message
                                    last-modified-seconds
                                    mime-type
                                    (build-headers headers)
                                    (flatten constree-of-bytes)))))

(define (do-response-chunked control-ch id rh)
  (match-define (web-response-header code resp-message last-modified-seconds mime-type headers) rh)
  (define stream-ch (make-async-channel))
  (react (stop-when (retracted (web-response-chunked id rh)))
         (on-stop (async-channel-put stream-ch #f))
         (on (message (web-response-chunk id $chunk))
             (async-channel-put stream-ch (flatten chunk)))
         (on-start (channel-put control-ch
                                (list 'response
                                      (response code
                                                resp-message
                                                last-modified-seconds
                                                mime-type
                                                (build-headers headers)
                                                (lambda (output-port)
                                                  (let loop ()
                                                    (match (async-channel-get stream-ch)
                                                      [#f
                                                       (void)]
                                                      [bss (for [(bs (in-list bss))]
                                                             (write-bytes bs
                                                                          output-port))
                                                           (loop)])))))))))

(define (do-response-websocket control-ch id headers)
  (define ws-ch (make-channel))
  (react (stop-when (retracted (web-response-websocket id headers)))
         (on-start (channel-put control-ch (list 'websocket headers ws-ch)))
         (run-websocket-connection id ws-ch)))

(define (run-websocket-connection id ws-ch)
  (on-stop (channel-put ws-ch 'quit))
  (on (message (websocket-message id 'outbound $body))
      (channel-put ws-ch (list 'send body)))
  (stop-when (message (inbound (web-incoming-message id (? eof-object? _)))))
  (on (message (inbound (web-incoming-message id $body)))
      (unless (eof-object? body) (send! (websocket-message id 'inbound body)))))

(define (req->virtual-host scheme r port)
  (cond [(assq 'host (request-headers r)) =>
         (lambda (h)
           (match (cdr h)
             [(regexp #px"(.*):(\\d+)" (list _ host port))
              (web-virtual-host scheme host (string->number port))]
             [host
              (web-virtual-host scheme host port)]))]
        [else
         (web-virtual-host scheme #f port)]))

(define (format-url-path u)
  (url-path->resource-path (url-path u)))

(define (build-headers hs)
  (for/list ((h (in-list hs)))
    (header (string->bytes/utf-8 (symbol->string (car h)))
            (string->bytes/utf-8 (cdr h)))))

(define (build-http-client-headers hs)
  (for/list ((h (in-list hs)))
    (format "~a: ~a" (car h) (cdr h))))

(define (handle-incoming-connection listen-port cm connection-ports)
  (thread
   (lambda ()
     (match-define (list i o) connection-ports)
     ;; Deliberately construct an empty custodian for the connection. Killing the connection
     ;; abruptly can cause deadlocks since the connection thread communicates with Syndicate
     ;; via synchronous channels.
     (define conn
       (new-connection cm (web-server-initial-connection-timeout) i o (make-custodian) #f))
     (define addresses
       (let-values (((Lip Lport Rip Rport) (tcp-addresses i #t)))
         (list Lip Lport Rip Rport)))
     (define control-ch (make-channel))
     (let do-request ()
       (define-values (req initial-headers) ;; TODO initial-headers?!?!
         (with-handlers ([exn:fail? (lambda (e) (values #f #f))])
           (read-request conn listen-port tcp-addresses)))
       (when req
         (define id (gensym 'web))
         (define start-ms (current-inexact-milliseconds))
         (send-ground-message (web-raw-request id listen-port conn addresses req control-ch))
         (sync (handle-evt control-ch
                           (lambda (msg)
                             (define delay-ms (inexact->exact
                                               (truncate
                                                (- (current-inexact-milliseconds) start-ms))))
                             (match msg
                               [(list 'websocket reply-headers ws-ch)
                                (log-syndicate/drivers/web-info
                                 "~s"
                                 `((method ,(request-method req))
                                   (url ,(url->string (request-uri req)))
                                   (headers ,(request-headers req))
                                   (port ,(request-host-port req))
                                   (websocket)
                                   (delay-ms ,delay-ms)))
                                (with-handlers ((exn:dispatcher?
                                                 (lambda (_e) (bad-request conn req))))
                                  ((make-general-websockets-dispatcher
                                    (websocket-connection-main id ws-ch)
                                    (lambda _args (values reply-headers (void))))
                                   conn req))]
                               [(list 'response resp)
                                (log-syndicate/drivers/web-info
                                 "~s"
                                 `((method ,(request-method req))
                                   (url ,(url->string (request-uri req)))
                                   (headers ,(request-headers req))
                                   (port ,(request-host-port req))
                                   (code ,(response-code resp))
                                   (delay-ms ,delay-ms)))
                                (output-response/method conn resp (request-method req))]))))
         (do-request))))))

;; D-:  uck barf
;; TODO: something to fix this :-/
(define (exn:fail:port-is-closed? e)
  (and (exn:fail? e)
       (regexp-match #px"port is closed" (exn-message e))))

(define ((websocket-connection-main id ws-ch) wsc _ws-connection-state)
  (define quit-seen? #f)
  (define (shutdown!)
    (send-ground-message (web-incoming-message id eof))
    (with-handlers ([(lambda (e) #t)
                     (lambda (e)
                       (log-syndicate/drivers/web-info
                        "Unexpected ws-close! error: ~a"
                        (if (exn? e)
                            (exn->string e)
                            (format "~v" e))))])
      (ws-close! wsc)))
  (with-handlers [(exn:fail:network? (lambda (e) (shutdown!)))
                  (exn:fail:port-is-closed? (lambda (e) (shutdown!)))
                  (exn:fail? (lambda (e)
                               (log-syndicate/drivers/web-error
                                "Unexpected websocket error: ~a"
                                (exn->string e))
                               (shutdown!)))]
    (let loop ()
      (sync (handle-evt wsc (lambda _args
                              (define msg (ws-recv wsc #:payload-type 'text))
                              (send-ground-message (web-incoming-message id msg))
                              (loop)))
            (handle-evt ws-ch (match-lambda
                                ['quit
                                 (set! quit-seen? #t)
                                 (void)]
                                [(list 'send m)
                                 (ws-send! wsc m)
                                 (loop)]))))
    (ws-close! wsc))
  (when (not quit-seen?)
    (let loop ()
      (when (not (equal? (channel-get ws-ch) 'quit))
        (loop)))))

(define (bad-request conn req)
  (output-response/method conn
                          (response/full 400
                                         #"Bad request"
                                         (current-seconds)
                                         #"text/plain"
                                         (list)
                                         (list))
                          (request-method req)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define (do-client-request id req body)
  (stop-when (asserted (observe (web-response-websocket id _)))
             (do-request-websocket id req))
  (stop-when (asserted (observe (web-response-complete id _ _)))
             (do-request-complete id req body))
  (stop-when (asserted (observe (web-response-chunked id _)))
             (do-request-chunked id req body)))

(define (analyze-outbound-request req)
  (match-define (web-request-header method
                                    (and resource
                                         (web-resource (web-virtual-host scheme host port) _))
                                    headers
                                    query)
    req)
  (values (match scheme
            [(or "wss" "https") #t]
            [_ #f])
          host
          (or port (match scheme
                     [(or "ws" "http") 80]
                     [(or "wss" "https") 443]
                     [_ #f]))
          method
          (url->string (resource->url resource #:query query))
          headers))

(define (do-request-websocket id req)
  (define-values (_ssl? _host server-port method urlstr headers) (analyze-outbound-request req))
  (define control-ch (make-channel))
  (if (not server-port)
      (send-ground-message (web-raw-client-conn id #f))
      (thread
       (lambda ()
         (log-syndicate/drivers/web-debug "Connecting to ~a ~a"
                                          urlstr
                                          (current-inexact-milliseconds))
         (define c (with-handlers [(exn? values)]
                     (ws-connect (string->url urlstr) #:headers headers)))
         (when (exn? c)
           (log-syndicate/drivers/web-debug "Connection to ~a failed: ~a" urlstr (exn->string c)))
         (send-ground-message (web-raw-client-conn id c))
         (when (not (exn? c))
           (log-syndicate/drivers/web-debug "Connected to ~a ~a" url (current-inexact-milliseconds))
           ((websocket-connection-main id control-ch) c (void))))))
  (react
   (stop-when (message (inbound (web-raw-client-conn id $c)))
              (react (stop-when (retracted (observe (web-response-websocket id _))))
                     (if (ws-conn? c)
                         (begin (assert (web-response-websocket id (ws-conn-headers c)))
                                (run-websocket-connection id control-ch))
                         (assert (web-response-websocket id #f)))))))

(define (do-request-complete id req body)
  (define-values (ssl? host server-port method urlstr headers) (analyze-outbound-request req))
  (thread
   (lambda ()
     (define response
       (with-handlers [(exn? values)]
         (when (not server-port)
           (error 'http-sendrecv "No server port specified"))
         (define-values (first-line header-lines body-port)
           (http-sendrecv host
                          urlstr
                          #:ssl? ssl?
                          #:headers (build-http-client-headers headers)
                          #:port server-port
                          #:method (string-upcase (symbol->string method))
                          #:data (bytes-join (flatten body) #"")))
         (match first-line
           [(regexp #px"\\S+\\s(\\d+)\\s(.*)" (list _ codebs msgbs))
            (define code (string->number (bytes->string/latin-1 codebs)))
            (define msg (bytes->string/utf-8 msgbs))
            (define response-headers
              (for/list ((h (in-list (read-headers (open-input-bytes
                                                    (bytes-join header-lines #"\r\n"))))))
                (match-define (header k v) h)
                (cons (lowercase-symbol! (bytes->string/utf-8 k))
                      (bytes->string/utf-8 v))))
            (define response-body (port->bytes body-port))
            (web-response-complete id
                                   (web-response-header code
                                                        msg
                                                        #f ;; TODO: fill in from response-headers
                                                        (cond [(assq 'content-type response-headers)
                                                               => cdr]
                                                              [else #f])
                                                        response-headers)
                                   response-body)]
           [_
            (error 'http-sendrecv "Bad first line: ~v" first-line)])))
     (send-ground-message (web-raw-client-conn id response))))
  (react
   (stop-when (message (inbound (web-raw-client-conn id $r)))
              (react (stop-when (asserted (observe (web-response-complete id _ _)))
                                (if (exn? r)
                                    (begin (log-syndicate/drivers/web-error
                                            "Outbound web request failed: ~a"
                                            (exn->string r))
                                           (send! (web-response-complete id #f #f)))
                                    (send! r)))))))

(define (do-request-chunked id req body)
  (log-error "syndicate/drivers/web: do-request-chunked: unimplemented")
  (react (stop-when (retracted (observe (web-response-chunked id _))))
         (assert (web-response-chunked id #f))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(spawn-web-driver)
