(ns pixie.io.tcp
  (:require [pixie.stacklets :as st]
            [pixie.streams :refer [IInputStream read IOutputStream write]]
            [pixie.uv :as uv]
            [pixie.ffi :as ffi]))

(defrecord TCPServer [ip port on-connect uv-server bind-addr on-connection-cb])

(defn -prep-uv-buffer-fn [buf read-bytes]
  (ffi/ffi-prep-callback
   uv/uv_alloc_cb
   (fn [handle suggested-size uv-buf]
     (try
       (let [casted (ffi/cast uv-buf uv/uv_buf_t)]
         (println "Alloc " handle suggested-size buf read-bytes)
         (ffi/set! casted :base buf)
         (ffi/set! casted :len (min suggested-size
                                    (buffer-capacity buf)
                                    read-bytes)))
       (catch ex (println ex))))))

(deftype TCPStream [uv-client uv-write-buf]
  IInputStream
  (read [this buffer len]
    (assert (<= (buffer-capacity buffer) len)
            "Not enough capacity in the buffer")
    (let [alloc-cb (-prep-uv-buffer-fn buffer len)
          read-cb (atom nil)]
      (st/call-cc (fn [k]
                 (reset! read-cb (ffi/ffi-prep-callback
                                  uv/uv_read_cb
                                  (fn [stream nread uv-buf]
                                    (println "-<<< nread <-- " nread)
                                    (set-buffer-count! buffer nread)
                                    (try
                                      (dispose! alloc-cb)
                                      (dispose! @read-cb)
                                      ;(dispose! uv-buf)
                                      (uv/uv_read_stop stream)
                                      (st/run-and-process k nread)
                                      (catch ex
                                          (println ex))))))
                 (uv/uv_read_start uv-client alloc-cb @read-cb)))))
  IOutputStream
  (write [this buffer]
    (let [write-cb (atom nil)
          uv_write (uv/uv_write_t)]
      (println "writing " (count buffer))
      (ffi/set! uv-write-buf :base buffer)
      (ffi/set! uv-write-buf :len (count buffer))
      (st/call-cc
       (fn [k]
         (reset! write-cb (ffi/ffi-prep-callback
                          uv/uv_write_cb
                          (fn [req status]
                            (println status "<<-- status")
                            (try
                              (dispose! @write-cb)
                              ;(uv/uv_close uv_write st/close_cb)
                              (st/run-and-process k status)
                              (catch ex
                                  (println ex))))))
         (uv/uv_write uv_write uv-client uv-write-buf 1 @write-cb))))))

(defn launch-tcp-client-from-server [svr]
  (assert (instance? TCPServer svr) "Requires a TCPServer as the first argument")
  (let [client (uv/uv_tcp_t)]
    (uv/uv_tcp_init (uv/uv_default_loop) client)
    (if (= 0 (uv/uv_accept (:uv-server svr) client))
      (do (st/spawn-from-non-stacklet #((:on-connect svr)
                                        (->TCPStream client (uv/uv_buf_t))))
          svr)
      (do (uv/uv_close client nil)
          svr))))



(defn tcp-server [ip port on-connection]
    (assert (string? ip) "Ip should be a string")
    (assert (integer? port) "Port should be a int")

    (let [server (uv/uv_tcp_t)
          bind-addr (uv/sockaddr_in)
          _ (uv/throw-on-error (uv/uv_ip4_addr ip port bind-addr))
          on-new-connetion (atom nil)
          tcp-server (->TCPServer ip port on-connection server bind-addr on-new-connetion)]
      (reset! on-new-connetion
              (ffi/ffi-prep-callback
               uv/uv_connection_cb
               (fn [server status]
                 (launch-tcp-client-from-server tcp-server))))
      (uv/uv_tcp_init (uv/uv_default_loop) server)
      (uv/uv_tcp_bind server bind-addr 0)
      (uv/throw-on-error (uv/uv_listen server 128 @on-new-connetion))
      (st/yield-control)
      tcp-server))
