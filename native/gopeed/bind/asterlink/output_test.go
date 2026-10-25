package gopeed

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"sync/atomic"
	"testing"
	"time"

	"github.com/GopeedLab/gopeed/internal/outputfile"
)

func directFile(t *testing.T, contents []byte) string {
	t.Helper()
	name := filepath.Join(t.TempDir(), "runtime-output-lease")
	if err := os.WriteFile(name, contents, 0600); err != nil {
		t.Fatal(err)
	}
	return name
}

func directHTTPInput(t *testing.T, id string, f *fixture) request {
	t.Helper()
	return request{ID: id, URL: f.server.URL + "/file", Headers: map[string]string{"Cookie": "test-cookie=local-only"},
		Connections: 4, Retries: 1, SpeedLimit: 512 * 1024, OutputKey: "target-" + id, OutputPath: directFile(t, []byte("old contents"))}
}

func assertNoPrivateOutput(t *testing.T, logical string) {
	t.Helper()
	if _, err := os.Lstat(logical); !os.IsNotExist(err) {
		t.Fatalf("download created a private payload instead of writing to its target: %v", err)
	}
}

func assertOutputNotPersisted(t *testing.T, dir, encodedKey, outputPath string) {
	t.Helper()
	key, err := base64.StdEncoding.DecodeString(encodedKey)
	if err != nil {
		t.Fatal(err)
	}
	storage, err := newEncryptedStorage(dir, key)
	if err != nil {
		t.Fatal(err)
	}
	defer storage.Close()
	encodedPath, _ := json.Marshal(outputPath)
	for _, bucket := range []string{"task", "save"} {
		var stored json.RawMessage
		if err = storage.List(bucket, &stored); err != nil {
			t.Fatal(err)
		}
		if bytes.Contains(stored, encodedPath) || bytes.Contains(stored, []byte(`"outputPath"`)) {
			t.Fatalf("transient output handle persisted in %s checkpoint", bucket)
		}
	}
}

func TestDirectOutputHTTPResumeAcrossLeasesAndRestart(t *testing.T) {
	storage, payload, key := openTestCore(t)
	f := serveFile(t, 2*1024*1024, 0)
	input := directHTTPInput(t, "direct-resume", f)
	beginCacheTest(t, input)
	state := waitState(t, input.ID, func(s snapshot) bool { return s.Downloaded > 0 && s.Status != "done" })
	if state.Path != input.OutputPath {
		t.Fatal("snapshot did not expose the live output handle")
	}
	info, err := os.Stat(input.OutputPath)
	if err != nil || info.Size() != int64(len(f.data)) {
		t.Fatal("new direct output was not preallocated for range recovery")
	}
	logical := filepath.Join(payload, input.ID, "payload.gopeed")
	assertNoPrivateOutput(t, logical)
	if err = Pause(input.ID); err != nil {
		t.Fatal(err)
	}
	oldID := taskIDs[input.ID]
	if core.GetTask(oldID).Meta.Req.Labels[outputKeyLabel] != input.OutputKey {
		t.Fatal("checkpoint has no stable output identity")
	}
	if err = Close(); err != nil {
		t.Fatal(err)
	}
	assertOutputNotPersisted(t, storage, key, input.OutputPath)
	oldPath := input.OutputPath
	input.OutputPath += "-reopened"
	if err = os.Rename(oldPath, input.OutputPath); err != nil {
		t.Fatal(err)
	}
	if err = Open(storage, payload, key); err != nil {
		t.Fatal(err)
	}
	state = waitState(t, input.ID, func(s snapshot) bool { return s.Status == "pause" })
	if state.Path != "" {
		t.Fatal("restored task exposed a handle from the previous process")
	}
	input.URL = f.server.URL + "/refreshed"
	beginCacheTest(t, input)
	if taskIDs[input.ID] != oldID {
		t.Fatal("rebinding the same target discarded its range checkpoint")
	}
	state = waitState(t, input.ID, func(s snapshot) bool { return s.Status == "done" })
	if state.Path != input.OutputPath {
		t.Fatal("completed task still references the old output lease")
	}
	assertPayload(t, state, f.data)
	assertNoPrivateOutput(t, logical)
	if _, err = os.Stat(oldPath); !os.IsNotExist(err) {
		t.Fatal("download recreated the obsolete handle path")
	}
}

func TestDirectOutputHTTPChangedKeyStartsNewTask(t *testing.T) {
	_, payload, _ := openTestCore(t)
	f := serveFile(t, 1024*1024, 0)
	input := directHTTPInput(t, "replace-target", f)
	beginCacheTest(t, input)
	waitState(t, input.ID, func(s snapshot) bool { return s.Downloaded > 0 && s.Status != "done" })
	if err := Pause(input.ID); err != nil {
		t.Fatal(err)
	}
	oldID, oldPath := taskIDs[input.ID], input.OutputPath
	oldBytes, err := os.ReadFile(oldPath)
	if err != nil {
		t.Fatal(err)
	}
	// Matching lengths are not sufficient to identify a resumable output.
	input.OutputPath = directFile(t, make([]byte, len(f.data)))
	input.OutputKey = "replacement-target"
	input.SpeedLimit = 0
	beginCacheTest(t, input)
	if taskIDs[input.ID] == oldID {
		t.Fatal("a different target inherited the old target's completed ranges")
	}
	assertPayload(t, waitState(t, input.ID, func(s snapshot) bool { return s.Status == "done" }), f.data)
	unchanged, err := os.ReadFile(oldPath)
	if err != nil || !bytes.Equal(unchanged, oldBytes) {
		t.Fatal("replacing a target changed or deleted the previous output")
	}
	assertNoPrivateOutput(t, filepath.Join(payload, input.ID, "payload.gopeed"))
}

func TestDirectOutputHTTPTruncatedTargetRestarts(t *testing.T) {
	openTestCore(t)
	f := serveFile(t, 1024*1024, 0)
	input := directHTTPInput(t, "truncated-output", f)
	beginCacheTest(t, input)
	waitState(t, input.ID, func(s snapshot) bool { return s.Downloaded > 0 && s.Status != "done" })
	if err := Pause(input.ID); err != nil {
		t.Fatal(err)
	}
	oldID := taskIDs[input.ID]
	if err := os.Truncate(input.OutputPath, 10); err != nil {
		t.Fatal(err)
	}
	input.SpeedLimit = 0
	beginCacheTest(t, input)
	if taskIDs[input.ID] == oldID {
		t.Fatal("a truncated direct output retained an invalid range checkpoint")
	}
	assertPayload(t, waitState(t, input.ID, func(s snapshot) bool { return s.Status == "done" }), f.data)
}

func TestDirectOutputHTTPStreamingAndRetry(t *testing.T) {
	for _, mode := range []string{"empty", "unknown-length", "retry"} {
		t.Run(mode, func(t *testing.T) {
			_, payload, _ := openTestCore(t)
			want := []byte("abcdefgh")
			if mode == "empty" {
				want = nil
			}
			var attempts atomic.Int32
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				attempt := attempts.Add(1)
				if mode != "retry" && r.Header.Get("Range") != "" {
					if len(want) == 0 {
						w.Header().Set("Content-Range", "bytes */0")
						w.WriteHeader(416)
					} else {
						w.Header().Set("Content-Range", "bytes 0-0/*")
						w.WriteHeader(206)
						w.Write(want[:1])
					}
					return
				}
				if mode == "unknown-length" {
					w.(http.Flusher).Flush()
				} else {
					w.Header().Set("Content-Length", strconv.Itoa(len(want)))
				}
				if mode == "retry" && attempt == 2 {
					w.Write(want[:4])
					return
				}
				w.Write(want)
			}))
			t.Cleanup(server.Close)
			input := request{ID: "stream-output", URL: server.URL, Connections: 4, Retries: 2,
				OutputKey: "stream-target", OutputPath: directFile(t, bytes.Repeat([]byte("stale"), 20))}
			beginCacheTest(t, input)
			state := waitState(t, input.ID, func(s snapshot) bool { return s.Status == "done" })
			assertPayload(t, state, want)
			if state.Downloaded != int64(len(want)) {
				t.Fatal("direct streaming progress includes discarded bytes")
			}
			assertNoPrivateOutput(t, filepath.Join(payload, input.ID, "payload.gopeed"))
		})
	}
}

func TestDirectOutputRemoveStopsWritesAndRetainsTarget(t *testing.T) {
	_, payload, _ := openTestCore(t)
	f := serveFile(t, 1024*1024, 0)
	input := directHTTPInput(t, "remove-output", f)
	beginCacheTest(t, input)
	waitState(t, input.ID, func(s snapshot) bool { return s.Downloaded > 0 && s.Status != "done" })
	if err := Remove(input.ID); err != nil {
		t.Fatal(err)
	}
	before, err := os.ReadFile(input.OutputPath)
	if err != nil {
		t.Fatal("removing a native task deleted its Android-owned target")
	}
	time.Sleep(120 * time.Millisecond)
	after, err := os.ReadFile(input.OutputPath)
	if err != nil || !bytes.Equal(before, after) {
		t.Fatal("the removed task continued to write its target")
	}
	logical := filepath.Join(payload, input.ID, "payload.gopeed")
	if _, bound := outputfile.Path(logical); bound {
		t.Fatal("removed task retained its output lease")
	}
	assertNoPrivateOutput(t, logical)
}

func TestDirectOutputTorrentFilesAndEmptyFile(t *testing.T) {
	_, payload, _ := openTestCore(t)
	data, selected := torrentFixture(t, 256*1024)
	_, info, err := parseTorrent(data)
	if err != nil {
		t.Fatal(err)
	}
	// b.bin begins inside a piece shared with a.txt. Completing its checksum
	// requires the adjacent piece bytes while its own payload stays external.
	for index, want := range [][]byte{[]byte("not selected\n"), selected, {}} {
		input := request{ID: "direct-torrent-" + strconv.Itoa(index), TorrentData: data, TorrentIndex: index,
			Connections: 32, OutputKey: "torrent-target-" + strconv.Itoa(index), OutputPath: directFile(t, []byte("stale bytes"))}
		beginCacheTest(t, input)
		state := waitState(t, input.ID, func(s snapshot) bool { return s.Status == "done" })
		if state.Path != input.OutputPath {
			t.Fatal("torrent snapshot did not reference the chosen output")
		}
		assertPayload(t, state, want)
		logical := filepath.Join(payload, input.ID, info.Files[index].Path)
		assertNoPrivateOutput(t, logical)
		if err = Remove(input.ID); err != nil {
			t.Fatal(err)
		}
		assertPayload(t, state, want)
		if _, bound := outputfile.Path(logical); bound {
			t.Fatal("removed torrent retained its output binding")
		}
	}
}

func TestDirectOutputTorrentResumeAcrossLeasesAndRestart(t *testing.T) {
	storage, payload, key := openTestCore(t)
	data, want := torrentFixture(t, 2*1024*1024)
	input := request{ID: "bt-direct-resume", TorrentData: data, TorrentIndex: 1, Connections: 32,
		SpeedLimit: 512 * 1024, OutputKey: "stable-bt-target", OutputPath: directFile(t, nil)}
	beginCacheTest(t, input)
	waitState(t, input.ID, func(s snapshot) bool { return s.Downloaded > 0 && s.Status != "done" })
	if err := Pause(input.ID); err != nil {
		t.Fatal(err)
	}
	oldID := taskIDs[input.ID]
	if err := Close(); err != nil {
		t.Fatal(err)
	}
	assertOutputNotPersisted(t, storage, key, input.OutputPath)
	oldPath := input.OutputPath
	input.OutputPath += "-reopened"
	if err := os.Rename(oldPath, input.OutputPath); err != nil {
		t.Fatal(err)
	}
	if err := Open(storage, payload, key); err != nil {
		t.Fatal(err)
	}
	beginCacheTest(t, input)
	if taskIDs[input.ID] != oldID {
		t.Fatal("torrent output rebind discarded its checkpoint")
	}
	state := waitState(t, input.ID, func(s snapshot) bool { return s.Status == "done" })
	assertPayload(t, state, want)
	assertNoPrivateOutput(t, torrentTaskPath(core.GetTask(oldID)))
}

func TestDirectOutputCompletedTorrentStaysStoppedAcrossRestart(t *testing.T) {
	storageDir, payload, key := openTestCore(t)
	data, _ := torrentFixture(t, 32*1024)
	_, info, err := parseTorrent(data)
	if err != nil {
		t.Fatal(err)
	}
	// Without a live binding, restoring an uploader for this completed empty
	// document would create a replacement file in the private payload tree.
	input := request{ID: "completed-output", TorrentData: data, TorrentIndex: 2,
		Connections: 16, OutputKey: "completed-document", OutputPath: directFile(t, []byte("stale"))}
	beginCacheTest(t, input)
	state := waitState(t, input.ID, func(s snapshot) bool { return s.Status == "done" })
	assertPayload(t, state, nil)
	logical := filepath.Join(payload, input.ID, info.Files[input.TorrentIndex].Path)
	assertNoPrivateOutput(t, logical)
	taskID := taskIDs[input.ID]
	if err = Close(); err != nil {
		t.Fatal(err)
	}

	// Simulate a process that was killed after completion, before Android
	// stopped the torrent and released its document descriptor.
	decodedKey, err := base64.StdEncoding.DecodeString(key)
	if err != nil {
		t.Fatal(err)
	}
	checkpoint, err := newEncryptedStorage(storageDir, decodedKey)
	if err != nil {
		t.Fatal(err)
	}
	var saved map[string]any
	found, err := checkpoint.Get("task", taskID, &saved)
	if err == nil && found {
		saved["uploading"] = true
		err = checkpoint.Put("task", taskID, saved)
	}
	closeErr := checkpoint.Close()
	if err != nil || !found || closeErr != nil {
		t.Fatalf("could not prepare completed crash checkpoint: found=%v, get/put=%v, close=%v", found, err, closeErr)
	}
	if err = Open(storageDir, payload, key); err != nil {
		t.Fatal(err)
	}
	if core.GetTask(taskID).Uploading {
		t.Fatal("restored direct output started uploading without a document descriptor")
	}
	state = waitState(t, input.ID, func(s snapshot) bool { return s.Status == "done" })
	if state.Path != "" {
		t.Fatal("completed checkpoint exposed a stale output descriptor")
	}
	assertNoPrivateOutput(t, logical)
	beginCacheTest(t, input)
	state = waitState(t, input.ID, func(s snapshot) bool { return s.Status == "done" })
	if taskIDs[input.ID] != taskID || state.Path != input.OutputPath {
		t.Fatal("rebinding the completed document discarded its result")
	}
	assertPayload(t, state, nil)
	assertNoPrivateOutput(t, logical)
}

func TestDirectOutputRejectsInvalidOrUnavailableTargets(t *testing.T) {
	openTestCore(t)
	f := serveFile(t, 8192, 0)
	valid := directHTTPInput(t, "invalid-output", f)
	missing := filepath.Join(t.TempDir(), "missing")
	for _, fields := range [][2]string{{valid.OutputPath, ""}, {"", valid.OutputKey}, {"relative", valid.OutputKey}, {t.TempDir(), valid.OutputKey}, {missing, valid.OutputKey}} {
		input := valid
		input.OutputPath, input.OutputKey = fields[0], fields[1]
		encoded, _ := json.Marshal(input)
		if err := Begin(string(encoded)); err == nil {
			t.Fatalf("accepted invalid output fields: %v", fields)
		}
	}
	if _, err := os.Stat(missing); !os.IsNotExist(err) {
		t.Fatal("an unavailable target was silently recreated")
	}
}
