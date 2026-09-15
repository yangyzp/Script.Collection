package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"
)

func main() {
	httpListen := flag.String("http-listen", "127.0.0.1:80", "local HTTP responder address")
	httpsListen := flag.String("https-listen", "127.0.0.1:443", "local HTTPS relay address")
	gstaticUpstream := flag.String("gstatic-upstream", "www.gstatic.com:443", "real Gstatic HTTPS upstream")
	cloudflareUpstream := flag.String("cloudflare-upstream", "cp.cloudflare.com:443", "real Cloudflare HTTPS upstream")
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
		if err := serveRelay(*httpsListen, *gstaticUpstream, *cloudflareUpstream, resolver); err != nil {
			errors <- fmt.Errorf("HTTPS relay: %w", err)
		}
	}()

	log.Printf("HTTP responder: http://%s", *httpListen)
	log.Printf("HTTPS relay: %s -> %s, %s", *httpsListen, *gstaticUpstream, *cloudflareUpstream)
	log.Fatal(<-errors)
}

func serveHTTP(listen string) error {
	mux := http.NewServeMux()
	mux.HandleFunc("/generate_204", func(w http.ResponseWriter, r *http.Request) {
		started := time.Now()
		status := http.StatusNoContent
		log.Printf("probe start method=%s remote=%q host=%q path=%q ua=%q", r.Method, r.RemoteAddr, r.Host, r.URL.Path, r.UserAgent())
		defer func() {
			log.Printf("probe done status=%d remote=%q duration=%s", status, r.RemoteAddr, time.Since(started))
		}()
		host := r.Host
		if parsedHost, _, err := net.SplitHostPort(r.Host); err == nil {
			host = parsedHost
		}
		if !isProbeHost(host) {
			status = http.StatusForbidden
			w.WriteHeader(http.StatusForbidden)
			return
		}
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			status = http.StatusForbidden
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

func serveRelay(listen, gstaticUpstream, cloudflareUpstream string, resolver *net.Resolver) error {
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
		go relay(client, gstaticUpstream, cloudflareUpstream, resolver)
	}
}

func relay(client net.Conn, gstaticUpstream, cloudflareUpstream string, resolver *net.Resolver) {
	defer client.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	_ = client.SetDeadline(time.Now().Add(5 * time.Second))
	prefetched, serverName, err := readTLSClientHello(client)
	if err != nil {
		log.Printf("inspect TLS %s: %v", client.RemoteAddr(), err)
		return
	}
	upstream := gstaticUpstream
	if strings.EqualFold(serverName, "cp.cloudflare.com") {
		upstream = cloudflareUpstream
	}

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

	log.Printf("relay %s sni=%q -> %s", client.RemoteAddr(), serverName, upstream)
	client.SetDeadline(time.Now().Add(15 * time.Second))
	server.SetDeadline(time.Now().Add(15 * time.Second))

	var waitGroup sync.WaitGroup
	waitGroup.Add(2)
	go func() {
		defer waitGroup.Done()
		_, _ = io.Copy(server, io.MultiReader(bytes.NewReader(prefetched), client))
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

func isProbeHost(host string) bool {
	host = strings.TrimSuffix(strings.ToLower(strings.TrimSpace(host)), ".")
	return host == "www.gstatic.com" || host == "cp.cloudflare.com"
}

func readTLSClientHello(conn net.Conn) ([]byte, string, error) {
	captured := &captureConn{Conn: conn}
	var serverName string
	var capturedHello = errors.New("client hello captured")
	tlsConn := tls.Server(captured, &tls.Config{
		GetConfigForClient: func(info *tls.ClientHelloInfo) (*tls.Config, error) {
			serverName = info.ServerName
			return nil, capturedHello
		},
	})
	if err := tlsConn.Handshake(); !errors.Is(err, capturedHello) {
		return nil, "", err
	}
	return bytes.Clone(captured.data.Bytes()), serverName, nil
}

type captureConn struct {
	net.Conn
	data bytes.Buffer
}

func (conn *captureConn) Read(data []byte) (int, error) {
	read, err := conn.Conn.Read(data)
	_, _ = conn.data.Write(data[:read])
	return read, err
}

func (conn *captureConn) Write(data []byte) (int, error) {
	return len(data), nil
}
