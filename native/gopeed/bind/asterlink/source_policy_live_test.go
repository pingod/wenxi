package gopeed

import (
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	fhttp "github.com/GopeedLab/gopeed/pkg/protocol/http"
)

// Opt-in public fixture: exercises the actual native transfer and its policy.
func TestSourceNativePublicDownload(t *testing.T) {
	if os.Getenv("SOURCE_LIVE_DOWNLOAD") != "1" {
		t.Skip("public-network test is opt-in")
	}
	root := t.TempDir()
	if err := Open(filepath.Join(root, "state"), filepath.Join(root, "cache"), base64.StdEncoding.EncodeToString(make([]byte, 32))); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { Close() })
	packet, _ := json.Marshal(request{ID: "source-public-rfc", URL: "https://www.rfc-editor.org/rfc/rfc20.txt", Connections: 1,
		NetworkPolicy: &fhttp.NetworkPolicy{Hosts: []string{"www.rfc-editor.org", "rfc-editor.org"}, Schemes: []string{"https"}, Ports: []int{443}},
		Headers:       map[string]string{"Accept-Encoding": "identity"}})
	if err := Begin(string(packet)); err != nil {
		t.Fatal("native source download could not start")
	}
	deadline := time.Now().Add(60 * time.Second)
	for time.Now().Before(deadline) {
		encoded, err := Snapshot("source-public-rfc")
		if err != nil {
			t.Fatal(err)
		}
		var state snapshot
		if json.Unmarshal([]byte(encoded), &state) != nil {
			t.Fatal("invalid native state")
		}
		if state.Status == "error" {
			t.Fatalf("native source failed: %s", state.ErrorKind)
		}
		if state.Status == "done" {
			content, err := os.ReadFile(state.Path)
			if err != nil || len(content) < 4096 || !strings.Contains(string(content), "ASCII") {
				t.Fatal("public file content mismatch")
			}
			t.Logf("Native source transfer saved %d bytes with declared network policy", len(content))
			return
		}
		time.Sleep(100 * time.Millisecond)
	}
	t.Fatal("native source transfer timed out")
}
