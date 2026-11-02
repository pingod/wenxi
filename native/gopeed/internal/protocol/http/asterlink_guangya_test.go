package http

import (
	"bytes"
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	fhttp "github.com/GopeedLab/gopeed/pkg/protocol/http"
)

func TestGuangyaOverloadSharesSlotsAndKeepsOtherNodesIndependent(t *testing.T) {
	const host = "busy-guangya.invalid"
	var releases []func()
	t.Cleanup(func() {
		for _, release := range releases {
			if release != nil {
				release()
			}
		}
		guangyaHosts.Lock()
		delete(guangyaHosts.entries, host)
		guangyaHosts.Unlock()
	})
	acquire := func(node, profile string) {
		t.Helper()
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		release, err := acquireProfileConnection(ctx, node, profile)
		if err != nil {
			t.Fatal(err)
		}
		releases = append(releases, release)
	}
	// A healthy node must still accept the user's higher connection setting.
	for range 8 {
		acquire(host, "guangya")
	}
	guangyaHosts.limit(host)
	for i := range 4 {
		releases[i]()
		releases[i] = nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 40*time.Millisecond)
	defer cancel()
	if release, err := acquireProfileConnection(ctx, host, "guangya"); err == nil {
		release()
		t.Fatal("a second task bypassed the four existing Guangya requests")
	} else if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatal(err)
	}
	// Neither another CDN node nor the Xunlei profile inherits this slowdown.
	for range 8 {
		acquire("healthy-guangya.invalid", "guangya")
		acquire(host, "xunlei")
	}
	releases[4]()
	releases[4] = nil
	acquire(host, "guangya")
	// The temporary limit expires while other file streams can remain active.
	guangyaHosts.Lock()
	guangyaHosts.entries[host].busyUntil = time.Now().Add(-time.Second)
	guangyaHosts.Unlock()
	for range 8 {
		acquire(host, "guangya")
	}
}

func TestGuangyaOverloadedNodeRecoversWithoutLosingRanges(t *testing.T) {
	data := bytes.Repeat([]byte("guangya-range-01"), 1024*1024)
	var active, rejected atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		first, last, ok := xunleiRange(t, r, len(data))
		if !ok {
			w.WriteHeader(http.StatusRequestedRangeNotSatisfiable)
			return
		}
		if first != 0 || last != 0 {
			count := active.Add(1)
			defer active.Add(-1)
			if count > 4 {
				rejected.Add(1)
				w.WriteHeader(http.StatusServiceUnavailable)
				return
			}
			xunleiResponse(w, first, last, len(data))
			w.(http.Flusher).Flush()
			select {
			case <-time.After(80 * time.Millisecond):
			case <-r.Context().Done():
				return
			}
		} else {
			xunleiResponse(w, first, last, len(data))
		}
		_, _ = w.Write(data[first : last+1])
	}))
	defer server.Close()
	f := xunleiFetcher(t, server.URL, 64)
	extra := f.meta.Opts.Extra.(*fhttp.OptsExtra)
	extra.ConnectionProfile = "guangya"
	retries := 1
	extra.RetryLimit = &retries
	if err := f.Start(); err != nil {
		t.Fatal(err)
	}
	verifyXunleiDownload(t, f, data)
	if rejected.Load() == 0 {
		t.Fatal("fixture did not exercise Guangya's overloaded response")
	}
}
