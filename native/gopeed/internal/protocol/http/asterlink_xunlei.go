package http

import (
	"context"
	"time"
)

const xunleiBusyConnections = 8
const xunleiBusyPeriod = 2 * time.Minute

var xunleiHosts = newAdaptiveHostLimiter(xunleiBusyConnections, xunleiBusyPeriod)

func limitXunleiHost(host string) {
	xunleiHosts.limit(host)
}

func acquireXunleiConnection(ctx context.Context, host string) (func(), error) {
	return xunleiHosts.acquire(ctx, host)
}
