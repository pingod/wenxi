// AsterLink per-task retry and speed options, 2026-09-12. Gopeed v1.8.1 / GPL-3.0.
package http

const (
	DefaultRetryLimit = 64
	MaxRetryLimit     = 64
)

type ReqExtra struct {
	NetworkPolicy *NetworkPolicy    `json:"networkPolicy,omitempty"`
	Method        string            `json:"method"`
	Header        map[string]string `json:"header"`
	Body          string            `json:"body"`
}

type OptsExtra struct {
	Connections int `json:"connections"`
	// ConnectionProfile selects the app's per-route range budget.
	ConnectionProfile string `json:"connectionProfile,omitempty"`
	// AliyunGroup is an app-local account digest, never an account credential.
	AliyunGroup string `json:"aliyunGroup,omitempty"`
	// AsterLink options; nil uses the application's default retry budget.
	RetryLimit *int  `json:"retryLimit,omitempty"`
	SpeedLimit int64 `json:"speedLimit,omitempty"`
	// AutoTorrent when task download complete, and it is a .torrent file, it will be auto create a new task for the torrent file
	AutoTorrent bool `json:"autoTorrent"`
}

type AliyunTransferState struct {
	Limit  int   `json:"limit"`
	WaitMS int64 `json:"waitMs"`
	Queued bool  `json:"queued"`
}

// Stats for download
type Stats struct {
	Connections []*StatsConnection `json:"connections"`
}

type StatsConnection struct {
	Downloaded int64 `json:"downloaded"`
	Completed  bool  `json:"completed"`
	Failed     bool  `json:"failed"`
	RetryTimes int   `json:"retryTimes"`
}
