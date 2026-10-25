package gopeed

import (
	"compress/gzip"
	"context"
	"crypto/x509"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestParserHTTP2KeepsStatusBodyAndExplicitHeaders(t *testing.T) {
	var calls atomic.Int32
	server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		body, _ := io.ReadAll(r.Body)
		if r.ProtoMajor != 2 || r.Method != "POST" || string(body) != `{"pwd":"sample"}` || r.Header.Get("User-Agent") != "fixture-ua" || r.Header.Get("Origin") != "https://parser.example" {
			t.Error("parser changed its HTTP/2 request")
		}
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Retry-After", "7")
		w.WriteHeader(http.StatusForbidden)
		_, _ = io.WriteString(w, `{"error":"blocked"}`)
	}))
	server.EnableHTTP2 = true
	server.StartTLS()
	defer server.Close()
	client := newParserHTTPClient()
	roots := x509.NewCertPool()
	roots.AddCert(server.Certificate())
	client.GetTLSClientConfig().RootCAs = roots
	defer client.GetTransport().CloseIdleConnections()
	result := performParserRequest(context.Background(), parserRequestInput{
		Method: "POST", URL: server.URL, Body: `{"pwd":"sample"}`,
		Headers: map[string]string{"User-Agent": "fixture-ua", "Origin": "https://parser.example"},
	}, client)
	if result.Status != "done" || result.Code != 403 || result.Protocol != "HTTP/2.0" || result.Body != `{"error":"blocked"}` || result.Headers["retry-after"][0] != "7" || calls.Load() != 1 {
		t.Fatalf("upstream response or attempt count changed: %+v, %d", result, calls.Load())
	}
}

func TestParserHTTPDoesNotFollowRedirectOrReuseCookies(t *testing.T) {
	var redirected atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Cookie") != "" {
			t.Error("parser persisted another request's cookies")
		}
		if r.URL.Path == "/next" {
			redirected.Add(1)
			return
		}
		w.Header().Add("Set-Cookie", "temporary=private; Path=/")
		http.Redirect(w, r, "/next", http.StatusFound)
	}))
	defer server.Close()
	client := newParserHTTPClient()
	defer client.GetTransport().CloseIdleConnections()
	for i := 0; i < 2; i++ {
		result := performParserRequest(context.Background(), parserRequestInput{Method: "GET", URL: server.URL}, client)
		if result.Status != "done" || result.Code != 302 || result.Headers["location"][0] != "/next" {
			t.Fatalf("lost redirect: %+v", result)
		}
	}
	if redirected.Load() != 0 {
		t.Fatal("followed an unchecked redirect")
	}
}

func TestParserHTTPLimitsDecompressedBody(t *testing.T) {
	for _, compressed := range []bool{false, true} {
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			var writer io.Writer = w
			if compressed {
				w.Header().Set("Content-Encoding", "gzip")
				zw := gzip.NewWriter(w)
				defer zw.Close()
				writer = zw
			}
			_, _ = io.WriteString(writer, strings.Repeat("x", parserResponseLimit+128))
		}))
		client := newParserHTTPClient()
		result := performParserRequest(context.Background(), parserRequestInput{Method: "GET", URL: server.URL, Headers: map[string]string{"Accept-Encoding": "gzip"}}, client)
		client.GetTransport().CloseIdleConnections()
		server.Close()
		if result.Status != "error" || result.ErrorKind != "response_too_large" || result.Body != "" {
			t.Fatalf("unbounded parser response (gzip=%t): %s/%s", compressed, result.Status, result.ErrorKind)
		}
	}
}

func TestParserHTTPCancellationClosesActiveRequest(t *testing.T) {
	started, stopped, release := make(chan struct{}), make(chan struct{}), make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.Copy(io.Discard, r.Body)
		w.WriteHeader(http.StatusOK)
		w.(http.Flusher).Flush()
		close(started)
		select {
		case <-r.Context().Done():
		case <-release:
		}
		close(stopped)
	}))
	defer server.Close()
	defer close(release)
	client := newParserHTTPClient()
	defer client.GetTransport().CloseIdleConnections()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	result := make(chan parserRequestResult, 1)
	go func() {
		result <- performParserRequest(ctx, parserRequestInput{Method: "POST", URL: server.URL}, client)
	}()
	select {
	case <-started:
	case <-time.After(3 * time.Second):
		t.Fatal("request did not start")
	}
	cancel()
	select {
	case <-stopped:
	case <-time.After(time.Second):
		t.Fatal("cancel left a request running")
	}
	select {
	case value := <-result:
		if value.Status != "error" || value.ErrorKind != "cancelled" {
			t.Fatalf("unexpected cancellation result: %+v", value)
		}
	case <-time.After(time.Second):
		t.Fatal("caller remained blocked after cancel")
	}
}

func TestParserHTTPRejectsUntrustedCertificate(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Error("untrusted certificate was accepted")
	}))
	defer server.Close()
	client := newParserHTTPClient()
	defer client.GetTransport().CloseIdleConnections()
	result := performParserRequest(context.Background(), parserRequestInput{Method: "GET", URL: server.URL + "/?secret=private"}, client)
	encoded, _ := json.Marshal(result)
	if result.Status != "error" || strings.Contains(string(encoded), "private") || strings.Contains(string(encoded), server.URL) {
		t.Fatal("certificate failure was ignored or exposed a request URL")
	}
}

func TestParserHTTPInputAndJobLifecycle(t *testing.T) {
	defer closeParserRequests()
	for _, address := range []string{"http://parser.example/", "https://127.0.0.1/", "https://parser.example:444/", "https://user:password@parser.example/", "https://parser.example/#fragment"} {
		if validateParserRequest(parserRequestInput{ID: "invalid", Method: "GET", URL: address}) == nil {
			t.Fatal("unsafe URL accepted")
		}
	}
	base := parserRequestInput{ID: "valid", Method: "POST", URL: "https://parser.example/", Headers: map[string]string{"Origin": "https://parser.example", "Cookie": "explicit-only=fixture"}}
	if err := validateParserRequest(base); err != nil {
		t.Fatal(err)
	}
	base.Headers["Transfer-Encoding"] = "chunked"
	if validateParserRequest(base) == nil {
		t.Fatal("transport header override accepted")
	}
	// Populate controlled pending jobs without any external requests. Stop and
	// Close must release them even when the download database was never opened.
	ctx, cancel := context.WithCancel(context.Background())
	parserRequests.Lock()
	parserRequests.jobs["pending"] = &parserRequestJob{cancel: cancel, expiry: time.NewTimer(time.Hour), result: parserRequestResult{Status: "running"}}
	parserRequests.Unlock()
	if status, _ := ParserRequestStatus("pending"); status != `{"status":"running"}` {
		t.Fatal("pending job unavailable")
	}
	StopParserRequest("pending")
	if ctx.Err() != context.Canceled {
		t.Fatal("stop did not cancel")
	}
	if status, _ := ParserRequestStatus("pending"); status != `{"status":"cancelled"}` {
		t.Fatal("stop retained job data")
	}
}
