//go:build linux || android

package outputfile

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sync"
	"testing"
)

func TestGrantedDescriptorSupportsConcurrentPositionedIO(t *testing.T) {
	Clear()
	t.Cleanup(Clear)
	root := t.TempDir()
	lease, err := os.OpenFile(filepath.Join(root, "document"), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	defer lease.Close()
	locator := fmt.Sprintf("/proc/self/fd/%d", lease.Fd())
	if os.Geteuid() != 0 {
		if err = lease.Chmod(0); err != nil {
			t.Fatal(err)
		}
		if reopened, openErr := os.OpenFile(locator, os.O_RDWR, 0); openErr == nil {
			reopened.Close()
			t.Fatal("descriptor path unexpectedly reopened without permission")
		} else if !os.IsPermission(openErr) {
			t.Fatal(openErr)
		}
	}
	logical := filepath.Join(root, "cache", "payload")
	if err = Bind("task", logical, locator); err != nil {
		t.Fatal(err)
	}
	if err = Reset(logical, 8192); err != nil {
		t.Fatal(err)
	}
	if _, err = lease.Seek(11, io.SeekStart); err != nil {
		t.Fatal(err)
	}
	var writers sync.WaitGroup
	want := make([]byte, 8192)
	for index := 0; index < 8; index++ {
		data := bytes.Repeat([]byte{byte(index + 1)}, 1024)
		copy(want[index*1024:], data)
		writers.Add(1)
		go func(offset int64, data []byte) {
			defer writers.Done()
			file, openErr := OpenFile(logical, os.O_WRONLY, 0)
			if openErr != nil {
				t.Error(openErr)
				return
			}
			defer file.Close()
			if file.Fd() == lease.Fd() {
				t.Error("writer took ownership of the caller's descriptor")
			}
			if n, writeErr := file.WriteAt(data, offset); writeErr != nil || n != len(data) {
				t.Errorf("write: %d %v", n, writeErr)
			}
		}(int64(index*1024), data)
	}
	writers.Wait()
	file, err := Open(logical)
	if err != nil {
		t.Fatal(err)
	}
	got := make([]byte, len(want))
	if n, readErr := file.ReadAt(got, 0); readErr != nil || n != len(want) || !bytes.Equal(got, want) {
		t.Fatalf("read: %d %v", n, readErr)
	}
	file.Close()
	info, err := Stat(logical)
	if err != nil || info.Size() != int64(len(want)) {
		t.Fatalf("stat: %v %v", info, err)
	}
	if position, seekErr := lease.Seek(0, io.SeekCurrent); seekErr != nil || position != 11 {
		t.Fatalf("positioned I/O changed the shared seek position: %d %v", position, seekErr)
	}
	Remove("task")
	if _, err = lease.WriteAt([]byte{9}, 0); err != nil {
		t.Fatal("removing a binding closed the caller's descriptor:", err)
	}
	if _, err = os.Stat(logical); !os.IsNotExist(err) {
		t.Fatal("direct I/O created a private payload:", err)
	}
}

func TestGrantedDescriptorRejectsReadOnlyAndPipeOutputs(t *testing.T) {
	Clear()
	t.Cleanup(Clear)
	root := t.TempDir()
	path := filepath.Join(root, "readonly")
	if err := os.WriteFile(path, []byte("preserved"), 0o600); err != nil {
		t.Fatal(err)
	}
	readOnly, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer readOnly.Close()
	logical := filepath.Join(root, "payload")
	if err = Bind("task", logical, fmt.Sprintf("/proc/self/fd/%d", readOnly.Fd())); err == nil {
		t.Fatal("accepted a read-only output descriptor")
	}
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	defer writer.Close()
	if err = Bind("task", logical, fmt.Sprintf("/proc/self/fd/%d", writer.Fd())); err == nil {
		t.Fatal("accepted a non-seekable output")
	}
	got, err := io.ReadAll(readOnly)
	if err != nil || string(got) != "preserved" {
		t.Fatal("validation altered or closed the caller's file:", err)
	}
}
