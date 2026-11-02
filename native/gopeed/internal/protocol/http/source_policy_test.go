package http

import (
	"context"
	"errors"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"testing"

	fhttp "github.com/GopeedLab/gopeed/pkg/protocol/http"
)

func sourceTestPolicy() *fhttp.NetworkPolicy {
	return &fhttp.NetworkPolicy{Hosts: []string{"origin.example.com", "cdn.example.com", "*.files.example.com"}, Schemes: []string{"https"}, Ports: []int{443}}
}

func TestSourcePolicyTargets(t *testing.T) {
	policy := sourceTestPolicy()
	policy.Schemes = []string{"http", "https"}
	policy.Ports = []int{80, 443}
	secure, _ := http.NewRequest("GET", "https://origin.example.com/file", nil)
	insecure, _ := http.NewRequest("GET", "http://cdn.example.com/file", nil)
	if !errors.Is(sourceRedirect(policy)(insecure, []*http.Request{secure}), fhttp.ErrNetworkPolicy) {
		t.Fatal("accepted an HTTPS downgrade")
	}
	policy = sourceTestPolicy()
	for _, target := range []string{"https://origin.example.com/file", "https://part.files.example.com/file"} {
		u, _ := url.Parse(target)
		if err := policy.CheckURL(u); err != nil {
			t.Fatal(err)
		}
	}
	for _, target := range []string{"http://origin.example.com/file", "https://origin.example.com:8443/file", "https://files.example.com/file", "https://origin.example.com.evil.org/file", "https://user:pass@origin.example.com/file", "https://127.0.0.1/file"} {
		u, _ := url.Parse(target)
		if !errors.Is(policy.CheckURL(u), fhttp.ErrNetworkPolicy) {
			t.Fatal("accepted forbidden target")
		}
	}
	for _, address := range []string{"127.0.0.1", "10.1.2.3", "172.16.0.1", "192.168.1.1", "169.254.169.254", "100.64.0.1", "198.18.0.1", "192.0.2.1", "224.0.0.1", "::1", "fc00::1", "fe80::1", "2001:db8::1", "2002::1"} {
		if fhttp.PublicAddress(net.ParseIP(address)) {
			t.Fatalf("accepted reserved address %s", address)
		}
	}
}

type sourceTestRoundTrip func(*http.Request) (*http.Response, error)

func (f sourceTestRoundTrip) RoundTrip(req *http.Request) (*http.Response, error) { return f(req) }

func TestSourcePolicyRedirectCredentials(t *testing.T) {
	var calls []*http.Request
	client := &http.Client{CheckRedirect: sourceRedirect(sourceTestPolicy()), Transport: sourceTestRoundTrip(func(req *http.Request) (*http.Response, error) {
		calls = append(calls, req)
		header := make(http.Header)
		status := 200
		if len(calls) == 1 {
			status = 302
			header.Set("Location", "https://cdn.example.com/file")
		}
		if len(calls) == 2 {
			status = 302
			header.Set("Location", "https://origin.example.com/final")
		}
		return &http.Response{StatusCode: status, Header: header, Body: io.NopCloser(strings.NewReader("")), Request: req}, nil
	})}
	req, _ := http.NewRequest("GET", "https://origin.example.com/file", nil)
	for _, key := range []string{"Authorization", "Cookie", "X-Token", "Referer"} {
		req.Header.Set(key, "fixture")
	}
	req.Header.Set("Range", "bytes=0-0")
	req.Header.Set("User-Agent", "source-agent")
	response, err := client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if len(calls) != 3 {
		t.Fatal("redirect chain incomplete")
	}
	for _, call := range calls[1:] {
		for _, key := range []string{"Authorization", "Cookie", "X-Token", "Referer"} {
			if call.Header.Get(key) != "" {
				t.Fatalf("forwarded %s", key)
			}
		}
		if call.Header.Get("Range") != "bytes=0-0" || call.Header.Get("User-Agent") != "source-agent" {
			t.Fatal("lost download headers")
		}
	}
	blocked, _ := http.NewRequest("GET", "https://outside.example.com/file", nil)
	if !errors.Is(client.CheckRedirect(blocked, calls[:1]), fhttp.ErrNetworkPolicy) {
		t.Fatal("accepted external redirect")
	}
}

func TestSourcePolicyRejectsMixedPublicPrivateDNS(t *testing.T) {
	lookup := func(context.Context, string) ([]net.IPAddr, error) {
		return []net.IPAddr{{IP: net.ParseIP("8.8.8.8")}, {IP: net.ParseIP("127.0.0.1")}}, nil
	}
	connection, err := sourceDialContext(sourceTestPolicy(), lookup)(context.Background(), "tcp", "origin.example.com:443")
	if connection != nil || !errors.Is(err, fhttp.ErrNetworkPolicy) {
		t.Fatal("DNS target was not rejected before dialing")
	}
}
