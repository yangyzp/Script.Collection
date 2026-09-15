package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"sync"
	"time"
)

func main() {
	httpListen := flag.String("http-listen", "127.0.0.1:80", "local HTTP responder address")
	httpsListen := flag.String("https-listen", "127.0.0.1:443", "local HTTPS relay address")
	upstream := flag.String("upstream", "www.gstatic.com:443", "real HTTPS upstream")
	dnsServer := flag.String("dns", "223.5.5.5:53", "DNS server used by the HTTPS relay")
	legacyHTTP := flag.Bool("http", false, "run only the HTTP responder")
	legacyListen := flag.String("listen", "", "legacy listen address used with -http")
	flag.Parse()

	if *legacyHTTP {
		listen := *httpListen
		if *legacyListen != "" {
			listen = *legacyListen
		}
		log.Printf("listening on http://%s", listen)
		if err := serveHTTP(listen); err != nil {
			log.Fatal(err)
		}
		return
	}

	resolver := &net.Resolver{
		PreferGo: true,
		Dial: func(ctx context.Context, network, _ string) (net.Conn, error) {
			dialer := net.Dialer{Timeout: 3 * time.Second}
			return dialer.DialContext(ctx, network, *dnsServer)
		},
	}

	errors := make(chan error, 2)
	go func() {
		if err := serveHTTP(*httpListen); err != nil {
			errors <- fmt.Errorf("HTTP responder: %w", err)
		}
	}()
	go func() {
		if err := serveRelay(*httpsListen, *upstream, resolver); err != nil {
			errors <- fmt.Errorf("HTTPS relay: %w", err)
		}
	}()

	log.Printf("HTTP responder: http://%s", *httpListen)
	log.Printf("HTTPS relay: %s -> %s", *httpsListen, *upstream)
	log.Fatal(<-errors)
}

func serveHTTP(listen string) error {
	mux := http.NewServeMux()
	mux.HandleFunc("/generate_204", func(w http.ResponseWriter, r *http.Request) {
		log.Printf("probe method=%s host=%q path=%q", r.Method, r.Host, r.URL.Path)
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			w.WriteHeader(http.StatusForbidden)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	})
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusForbidden)
	})

	server := &http.Server{
		Addr:              listen,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
		IdleTimeout:       10 * time.Second,
	}
	if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		return err
	}
	return nil
}

func serveRelay(listen, upstream string, resolver *net.Resolver) error {
	listener, err := net.Listen("tcp", listen)
	if err != nil {
		return fmt.Errorf("listen %s: %w", listen, err)
	}
	defer listener.Close()

	for {
		client, acceptErr := listener.Accept()
		if acceptErr != nil {
			return acceptErr
		}
		go relay(client, upstream, resolver)
	}
}

func relay(client net.Conn, upstream string, resolver *net.Resolver) {
	defer client.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	host, port, err := net.SplitHostPort(upstream)
	if err != nil {
		log.Printf("invalid upstream %q: %v", upstream, err)
		return
	}
	addresses, err := resolver.LookupIP(ctx, "ip4", host)
	if err != nil {
		log.Printf("resolve %s: %v", host, err)
		return
	}

	var server net.Conn
	for _, address := range addresses {
		if address.IsLoopback() {
			continue
		}
		server, err = (&net.Dialer{Timeout: 5 * time.Second}).DialContext(ctx, "tcp", net.JoinHostPort(address.String(), port))
		if err == nil {
			break
		}
	}
	if err != nil || server == nil {
		log.Printf("connect %s: %v", upstream, err)
		return
	}
	defer server.Close()

	log.Printf("relay %s -> %s", client.RemoteAddr(), upstream)
	client.SetDeadline(time.Now().Add(15 * time.Second))
	server.SetDeadline(time.Now().Add(15 * time.Second))

	var waitGroup sync.WaitGroup
	waitGroup.Add(2)
	go func() {
		defer waitGroup.Done()
		_, _ = io.Copy(server, client)
		if tcp, ok := server.(*net.TCPConn); ok {
			_ = tcp.CloseWrite()
		}
	}()
	go func() {
		defer waitGroup.Done()
		_, _ = io.Copy(client, server)
		if tcp, ok := client.(*net.TCPConn); ok {
			_ = tcp.CloseWrite()
		}
	}()
	waitGroup.Wait()
}
