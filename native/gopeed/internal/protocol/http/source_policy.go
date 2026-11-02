package http

import (
	"context"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"

	fhttp "github.com/GopeedLab/gopeed/pkg/protocol/http"
)

func (f *Fetcher) sourceNetworkPolicy() *fhttp.NetworkPolicy {
	if f.meta.Req != nil {
		if extra, ok := f.meta.Req.Extra.(*fhttp.ReqExtra); ok {
			return extra.NetworkPolicy
		}
	}
	return nil
}

func sourceDialContext(policy *fhttp.NetworkPolicy, lookup func(context.Context, string) ([]net.IPAddr, error)) func(context.Context, string, string) (net.Conn, error) {
	return func(ctx context.Context, network, address string) (net.Conn, error) {
		host, portText, err := net.SplitHostPort(address)
		if err != nil {
			return nil, fhttp.ErrNetworkPolicy
		}
		port, err := strconv.Atoi(portText)
		if err != nil || !policy.AllowsAddress(strings.ToLower(host), port) {
			return nil, fhttp.ErrNetworkPolicy
		}
		addresses, err := lookup(ctx, host)
		if err != nil {
			return nil, err
		}
		if len(addresses) == 0 {
			return nil, fhttp.ErrNetworkPolicy
		}
		for _, item := range addresses {
			if item.Zone != "" || !fhttp.PublicAddress(item.IP) {
				return nil, fhttp.ErrNetworkPolicy
			}
		}
		// Dial only these verified IPs; TLS still uses the request's hostname.
		dialer := &net.Dialer{Timeout: connectTimeout}
		for _, item := range addresses {
			connection, dialErr := dialer.DialContext(ctx, network, net.JoinHostPort(item.IP.String(), portText))
			if dialErr == nil {
				return connection, nil
			}
			err = dialErr
			if ctx.Err() != nil {
				return nil, ctx.Err()
			}
		}
		return nil, err
	}
}

func sameSourceOrigin(a, b *url.URL) bool {
	port := func(u *url.URL) string {
		if u.Port() != "" {
			return u.Port()
		}
		if u.Scheme == "https" {
			return "443"
		}
		return "80"
	}
	return a.Scheme == b.Scheme && strings.EqualFold(a.Hostname(), b.Hostname()) && port(a) == port(b)
}

func sourceRedirect(policy *fhttp.NetworkPolicy) func(*http.Request, []*http.Request) error {
	return func(req *http.Request, via []*http.Request) error {
		if len(via) > 5 || len(via) == 0 || policy.CheckURL(req.URL) != nil {
			return fhttp.ErrNetworkPolicy
		}
		previous := via[len(via)-1]
		if previous.URL.Scheme == "https" && req.URL.Scheme == "http" {
			return fhttp.ErrNetworkPolicy
		}
		sameOrigin := sameSourceOrigin(previous.URL, req.URL)
		req.Header = make(http.Header)
		for key, values := range previous.Header {
			safe := false
			switch strings.ToLower(key) {
			case "accept", "accept-language", "accept-encoding", "user-agent", "range", "if-range":
				safe = true
			}
			if sameOrigin || safe {
				req.Header[key] = append([]string(nil), values...)
			}
		}
		return nil
	}
}

type sourceTransport struct {
	transport *http.Transport
	policy    *fhttp.NetworkPolicy
}

func (t *sourceTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	if err := t.policy.CheckURL(req.URL); err != nil {
		return nil, err
	}
	return t.transport.RoundTrip(req)
}
func (t *sourceTransport) CloseIdleConnections() { t.transport.CloseIdleConnections() }

func sourceClient(transport *http.Transport, policy *fhttp.NetworkPolicy) *http.Client {
	transport.Proxy = nil
	transport.TLSClientConfig.InsecureSkipVerify = false
	transport.DialContext = sourceDialContext(policy, net.DefaultResolver.LookupIPAddr)
	return &http.Client{Transport: &sourceTransport{transport, policy}, CheckRedirect: sourceRedirect(policy)}
}
