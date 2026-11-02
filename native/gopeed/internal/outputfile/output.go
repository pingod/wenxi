// Package outputfile routes task-owned logical files to caller-owned output
// handles. These bindings are intentionally process-local: Android reopens its
// persisted document URI and supplies a new descriptor locator on every resume.
package outputfile

import (
	"errors"
	"io"
	"os"
	"path/filepath"
	"sync"
)

// KeyLabel binds a persisted task checkpoint to the Android output journal.
const KeyLabel = "asterlinkOutputKey"

type binding struct {
	owner  string
	target string
}

var bindings = struct {
	sync.RWMutex
	files map[string]binding
}{files: make(map[string]binding)}

// Bind must only be called after the owner's previous writers have stopped.
// The caller retains ownership of the output handle and its document URI.
func Bind(owner, logical, target string) error {
	if owner == "" || !filepath.IsAbs(logical) || !filepath.IsAbs(target) {
		return errors.New("invalid direct output path")
	}
	file, err := openTarget(target, os.O_RDWR, 0)
	if err != nil {
		return err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() {
		return errors.New("direct output must be a regular file")
	}
	if _, err := file.Seek(0, io.SeekCurrent); err != nil {
		return err
	}
	bindings.Lock()
	defer bindings.Unlock()
	for name, entry := range bindings.files {
		if entry.owner == owner {
			delete(bindings.files, name)
		}
	}
	bindings.files[filepath.Clean(logical)] = binding{owner: owner, target: target}
	return nil
}

func Path(logical string) (string, bool) {
	bindings.RLock()
	entry, ok := bindings.files[filepath.Clean(logical)]
	bindings.RUnlock()
	if ok {
		return entry.target, true
	}
	return logical, false
}

func Open(logical string) (*os.File, error) {
	return OpenFile(logical, os.O_RDONLY, 0)
}

func OpenFile(logical string, flag int, perm os.FileMode) (*os.File, error) {
	name, direct := Path(logical)
	if direct {
		// A removed/revoked target must fail, never recreate a different file.
		flag &^= os.O_CREATE
		return openTarget(name, flag, perm)
	}
	return os.OpenFile(name, flag, perm)
}

func Stat(logical string) (os.FileInfo, error) {
	name, direct := Path(logical)
	if !direct {
		return os.Stat(name)
	}
	file, err := openTarget(name, os.O_RDONLY, 0)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	return file.Stat()
}

// Reset prepares only a newly created task's direct output. Resumed tasks keep
// their downloaded bytes and use the saved HTTP ranges or BT piece hashes.
func Reset(logical string, size int64) error {
	_, direct := Path(logical)
	if !direct {
		return nil
	}
	file, err := OpenFile(logical, os.O_RDWR, 0)
	if err != nil {
		return err
	}
	defer file.Close()
	if err = file.Truncate(0); err != nil {
		return err
	}
	if size > 0 {
		return file.Truncate(size)
	}
	return nil
}

// Remove forgets a binding after its writers stop; it never deletes the target.
func Remove(owner string) {
	bindings.Lock()
	defer bindings.Unlock()
	for name, entry := range bindings.files {
		if entry.owner == owner {
			delete(bindings.files, name)
		}
	}
}

func Clear() {
	bindings.Lock()
	bindings.files = make(map[string]binding)
	bindings.Unlock()
}
