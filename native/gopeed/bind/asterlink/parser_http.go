package gopeed

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/imroc/req/v3"
	"golang.org/x/net/http/httpguts"
)

const parserResponseLimit = 1024 * 1024

type parserRequestInput struct {
	ID      string            `json:"id"`
	Method  string            `json:"method"`
	URL     string            `json:"url"`
	Headers map[string]string `json:"headers"`
	Body    string            `json:"body"`
}

type parserRequestResult struct {
	Status    string              `json:"status"`
	Code      int                 `json:"code,omitempty"`
	Protocol  string              `json:"protocol,omitempty"`
	Headers   map[string][]string `json:"headers,omitempty"`
	Body      string              `json:"body,omitempty"`
	ErrorKind string              `json:"errorKind,omitempty"`
}

type parserRequestJob struct {
	cancel context.CancelFunc
	expiry *time.Timer
	result parserRequestResult
}

var parserRequests = struct {
	sync.Mutex
	jobs map[string]*parserRequestJob
}{jobs: map[string]*parserRequestJob{}}

func validateParserRequest(input parserRequestInput) error {
	u, err := url.Parse(input.URL)
	if err != nil || u == nil || u.Scheme != "https" || u.Hostname() == "" ||
		u.User != nil || u.Fragment != "" || (u.Port() != "" && u.Port() != "443") ||
		len(input.URL) > 8192 || strings.ContainsAny(input.URL, "\\\r\n\t ") ||
		!strings.Contains(u.Hostname(), ".") || net.ParseIP(u.Hostname()) != nil {
		return errors.New("invalid parser URL")
	}
	if !safeID.MatchString(input.ID) || (input.Method != http.MethodGet && input.Method != http.MethodPost) ||
		len(input.Body) > parserResponseLimit || len(input.Headers) > 64 {
		return errors.New("invalid parser request")
	}
	headerBytes := 0
	for key, value := range input.Headers {
		headerBytes += len(key) + len(value)
		if !httpguts.ValidHeaderFieldName(key) || !httpguts.ValidHeaderFieldValue(value) || headerBytes > 64*1024 {
			return errors.New("invalid parser headers")
		}
		switch strings.ToLower(key) {
		case "host", "connection", "content-length", "transfer-encoding", "proxy-authorization", "proxy-connection", "upgrade", "keep-alive", "te", "trailer":
			return errors.New("invalid parser transport header")
		}
	}
	return nil
}

// StartParserRequest uses the existing HTTP/2-capable transport without opening
// download storage or a listener. Signed rule validation stays with the caller.
// Start/status/stop keep the native control queue responsive during a slow site.
func StartParserRequest(value string) error {
	var input parserRequestInput
	if len(value) > 2*parserResponseLimit || json.Unmarshal([]byte(value), &input) != nil {
		return errors.New("invalid parser request")
	}
	if err := validateParserRequest(input); err != nil {
		return err
	}
	parserRequests.Lock()
	defer parserRequests.Unlock()
	if parserRequests.jobs[input.ID] != nil || len(parserRequests.jobs) >= 8 {
		return errors.New("parser request limit reached")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 65*time.Second)
	job := &parserRequestJob{cancel: cancel, result: parserRequestResult{Status: "running"}}
	parserRequests.jobs[input.ID] = job
	// Bound retention even if Flutter exits before sending stop.
	job.expiry = time.AfterFunc(90*time.Second, func() {
		parserRequests.Lock()
		defer parserRequests.Unlock()
		if parserRequests.jobs[input.ID] == job {
			cancel()
			delete(parserRequests.jobs, input.ID)
		}
	})
	go func() {
		defer cancel()
		client := newParserHTTPClient()
		defer client.GetTransport().CloseIdleConnections()
		result := performParserRequest(ctx, input, client)
		parserRequests.Lock()
		if parserRequests.jobs[input.ID] == job {
			job.result = result
		}
		parserRequests.Unlock()
	}()
	return nil
}

func newParserHTTPClient() *req.Client {
	// Keep the previous parser's direct routing, normal certificate verification,
	// and per-request isolation. No browser fingerprints, shared account cookies,
	// automatic retries, or redirects are added by this transport.
	client := req.C().SetProxy(nil).SetCookieJar(nil).SetLogger(nil).
		SetTimeout(65 * time.Second).SetTLSHandshakeTimeout(10 * time.Second).
		SetDial((&net.Dialer{Timeout: 10 * time.Second, KeepAlive: 30 * time.Second}).DialContext).
		SetRedirectPolicy(req.NoRedirectPolicy()).DisableAutoReadResponse().DisableAutoDecode().EnableAutoDecompress()
	client.GetTransport().SetMaxResponseHeaderBytes(64 * 1024)
	return client
}

func performParserRequest(ctx context.Context, input parserRequestInput, client *req.Client) parserRequestResult {
	failure := func(kind string) parserRequestResult {
		return parserRequestResult{Status: "error", ErrorKind: kind}
	}
	request, err := http.NewRequestWithContext(ctx, input.Method, input.URL, strings.NewReader(input.Body))
	if err != nil {
		return failure("request")
	}
	for key, value := range input.Headers {
		request.Header.Set(key, value)
	}
	response, err := client.Do(request)
	if err != nil {
		if errors.Is(ctx.Err(), context.Canceled) {
			return failure("cancelled")
		}
		return failure("network")
	}
	defer response.Body.Close()
	// Apply the limit after decompression too; a tiny gzip must not expand without
	// bounds. Return the real upstream status, including 3xx, 403 and 429.
	body, err := io.ReadAll(io.LimitReader(response.Body, parserResponseLimit+1))
	if len(body) > parserResponseLimit {
		return failure("response_too_large")
	}
	if err != nil {
		if errors.Is(ctx.Err(), context.Canceled) {
			return failure("cancelled")
		}
		return failure("network")
	}
	headers := make(map[string][]string, len(response.Header))
	for key, values := range response.Header {
		headers[strings.ToLower(key)] = values
	}
	return parserRequestResult{Status: "done", Code: response.StatusCode, Protocol: response.Proto, Headers: headers, Body: string(body)}
}

func ParserRequestStatus(id string) (string, error) {
	if !safeID.MatchString(id) {
		return "", errors.New("invalid parser request ID")
	}
	parserRequests.Lock()
	defer parserRequests.Unlock()
	job := parserRequests.jobs[id]
	if job == nil {
		return `{"status":"cancelled"}`, nil
	}
	data, err := json.Marshal(job.result)
	return string(data), err
}

func StopParserRequest(id string) {
	parserRequests.Lock()
	defer parserRequests.Unlock()
	if job := parserRequests.jobs[id]; job != nil {
		job.cancel()
		job.expiry.Stop()
		delete(parserRequests.jobs, id)
	}
}

func closeParserRequests() {
	parserRequests.Lock()
	defer parserRequests.Unlock()
	for id, job := range parserRequests.jobs {
		job.cancel()
		job.expiry.Stop()
		delete(parserRequests.jobs, id)
	}
}
