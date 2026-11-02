//go:build linux || android

package gopeed

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

// Android passes a seekable document descriptor, not the document's filesystem
// path. Exercise that same descriptor binding, including a different descriptor
// number when the encrypted checkpoint is reopened.
func TestDirectOutputProcDescriptorAcrossRestart(t *testing.T) {
	for _, protocol := range []string{"http", "bt"} {
		t.Run(protocol, func(t *testing.T) {
			storage, payload, key := openTestCore(t)
			input := request{ID: "proc-" + protocol, Connections: 16, Retries: 2,
				SpeedLimit: 512 * 1024, OutputKey: "document-" + protocol}
			var want []byte
			var httpFixture *fixture
			var relative string
			if protocol == "http" {
				httpFixture = serveFile(t, 2*1024*1024, 50*time.Millisecond)
				input.URL = httpFixture.server.URL + "/file"
				input.Headers = map[string]string{"Cookie": "test-cookie=local-only"}
				want, relative = httpFixture.data, "payload.gopeed"
			} else {
				input.TorrentData, want = torrentFixture(t, 2*1024*1024)
				input.TorrentIndex = 1
				_, info, err := parseTorrent(input.TorrentData)
				if err != nil {
					t.Fatal(err)
				}
				relative = info.Files[input.TorrentIndex].Path
			}
			backing := directFile(t, []byte("stale document contents"))
			lease, err := os.OpenFile(backing, os.O_RDWR, 0)
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() {
				_ = Pause(input.ID)
				_ = lease.Close()
			})
			input.OutputPath = fmt.Sprintf("/proc/self/fd/%d", lease.Fd())
			firstPath := input.OutputPath
			if os.Geteuid() != 0 {
				if err = os.Chmod(backing, 0); err != nil {
					t.Fatal(err)
				}
				if reopened, openErr := os.OpenFile(firstPath, os.O_RDWR, 0); openErr == nil {
					reopened.Close()
					t.Fatal("fixture must deny reopening the granted descriptor path")
				} else if !os.IsPermission(openErr) {
					t.Fatal(openErr)
				}
			}
			beginCacheTest(t, input)
			state := waitState(t, input.ID, func(s snapshot) bool {
				return s.Downloaded > 0 && s.Status != "done"
			})
			if state.Path != firstPath {
				t.Fatalf("snapshot path = %q, want live descriptor %q", state.Path, firstPath)
			}
			logical := filepath.Join(payload, input.ID, relative)
			assertNoPrivateOutput(t, logical)
			if err = Pause(input.ID); err != nil {
				t.Fatal(err)
			}
			oldID := taskIDs[input.ID]
			if err = Close(); err != nil {
				t.Fatal(err)
			}
			assertOutputNotPersisted(t, storage, key, firstPath)

			// Keep the first descriptor open until the new one is allocated so
			// the test cannot accidentally resume using the same numeric fd.
			nextFD, err := unix.FcntlInt(lease.Fd(), unix.F_DUPFD_CLOEXEC, 0)
			if err != nil {
				t.Fatal(err)
			}
			nextLease := os.NewFile(uintptr(nextFD), "renewed-document-grant")
			if err = lease.Close(); err != nil {
				nextLease.Close()
				t.Fatal(err)
			}
			lease = nextLease
			input.OutputPath = fmt.Sprintf("/proc/self/fd/%d", lease.Fd())
			if input.OutputPath == firstPath {
				t.Fatal("reopened output reused the original test descriptor")
			}
			if err = Open(storage, payload, key); err != nil {
				t.Fatal(err)
			}
			state = waitState(t, input.ID, func(s snapshot) bool { return s.Status == "pause" })
			if state.Path != "" {
				t.Fatal("restored task exposed a descriptor from the previous process")
			}
			beginCacheTest(t, input)
			if taskIDs[input.ID] != oldID {
				t.Fatal("a new descriptor for the same document discarded its checkpoint")
			}
			state = waitState(t, input.ID, func(s snapshot) bool { return s.Status == "done" })
			if state.Path != input.OutputPath || state.Total != int64(len(want)) || state.Downloaded != int64(len(want)) {
				t.Fatalf("completed descriptor snapshot: %+v", state)
			}
			got := make([]byte, len(want))
			if n, readErr := lease.ReadAt(got, 0); readErr != nil || n != len(want) || !bytes.Equal(got, want) {
				t.Fatalf("downloaded document differs: read=%d error=%v", n, readErr)
			}
			assertNoPrivateOutput(t, logical)
			if httpFixture != nil && httpFixture.peak.Load() < 2 {
				t.Fatal("HTTP descriptor test did not exercise concurrent range writes")
			}
			if err = Pause(input.ID); err != nil {
				t.Fatal(err)
			}
			if err = Remove(input.ID); err != nil {
				t.Fatal(err)
			}
			if err = os.Chmod(backing, 0o600); err != nil {
				t.Fatal(err)
			}
			got, err = os.ReadFile(backing)
			if err != nil || !bytes.Equal(got, want) {
				t.Fatal("pausing/removing a completed task changed its document")
			}
			assertNoPrivateOutput(t, logical)
		})
	}
}
