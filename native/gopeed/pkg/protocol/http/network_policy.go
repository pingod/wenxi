package http

import (
	"errors"
	"net"
	"net/url"
	"regexp"
	"strconv"
	"strings"
)

var ErrNetworkPolicy = errors.New("source download exceeds declared network permissions")

// NetworkPolicy is the signed source's download permission snapshot.
type NetworkPolicy struct {
	Hosts   []string `json:"hosts"`
	Schemes []string `json:"schemes"`
	Ports   []int    `json:"ports"`
}

var sourceHostPattern = regexp.MustCompile(`^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$`)
var sourceLocalSuffix = regexp.MustCompile(`\.(local|localhost|internal|invalid|test)$`)

func (p *NetworkPolicy) Validate() error {
	if p == nil || len(p.Hosts) == 0 || len(p.Hosts) > 32 || len(p.Schemes) == 0 || len(p.Ports) == 0 || len(p.Ports) > 16 {
		return ErrNetworkPolicy
	}
	for _, host := range p.Hosts {
		host = strings.TrimPrefix(host, "*.")
		if len(host) > 253 || !sourceHostPattern.MatchString(host) || sourceLocalSuffix.MatchString(host) {
			return ErrNetworkPolicy
		}
	}
	for _, scheme := range p.Schemes {
		if scheme != "https" && scheme != "http" {
			return ErrNetworkPolicy
		}
	}
	for _, port := range p.Ports {
		if port < 1 || port > 65535 {
			return ErrNetworkPolicy
		}
	}
	return nil
}

func (p *NetworkPolicy) AllowsAddress(host string, port int) bool {
	hostAllowed, portAllowed := false, false
	for _, allowed := range p.Hosts {
		if host == allowed || strings.HasPrefix(allowed, "*.") && strings.HasSuffix(host, allowed[1:]) {
			hostAllowed = true
		}
	}
	for _, allowed := range p.Ports {
		if port == allowed {
			portAllowed = true
		}
	}
	return hostAllowed && portAllowed
}

func (p *NetworkPolicy) CheckURL(u *url.URL) error {
	if p.Validate() != nil || u == nil || u.User != nil || u.Opaque != "" || len(u.String()) > 16384 || strings.ContainsAny(u.String(), "\\\r\n\t ") {
		return ErrNetworkPolicy
	}
	schemeAllowed := false
	for _, scheme := range p.Schemes {
		if u.Scheme == scheme {
			schemeAllowed = true
		}
	}
	port := 80
	if u.Scheme == "https" {
		port = 443
	}
	if u.Port() != "" {
		var err error
		port, err = strconv.Atoi(u.Port())
		if err != nil {
			return ErrNetworkPolicy
		}
	}
	if !schemeAllowed || !p.AllowsAddress(strings.ToLower(u.Hostname()), port) {
		return ErrNetworkPolicy
	}
	return nil
}

// PublicAddress excludes private, loopback, transition and documentation ranges.
func PublicAddress(ip net.IP) bool {
	if b := ip.To4(); b != nil {
		return b[0] != 0 && b[0] != 10 && b[0] != 127 && b[0] < 224 &&
			!(b[0] == 100 && b[1] >= 64 && b[1] <= 127) &&
			!(b[0] == 169 && b[1] == 254) && !(b[0] == 172 && b[1] >= 16 && b[1] <= 31) &&
			!(b[0] == 192 && (b[1] == 168 || b[1] == 0 && (b[2] == 0 || b[2] == 2) || b[1] == 88 && b[2] == 99)) &&
			!(b[0] == 198 && (b[1] == 18 || b[1] == 19 || b[1] == 51 && b[2] == 100)) &&
			!(b[0] == 203 && b[1] == 0 && b[2] == 113)
	}
	b := ip.To16()
	return b != nil && b[0]&0xe0 == 0x20 && !(b[0] == 0x20 && b[1] == 2) && !(b[0] == 0x20 && b[1] == 1 &&
		(b[2] == 0 || b[2] == 0x0d && b[3] == 0xb8 || b[2] == 0x10 || b[2] == 0x20))
}
