//go:build linux || android

package outputfile

import (
	"errors"
	"os"
	"strconv"
	"strings"

	"golang.org/x/sys/unix"
)

// Android grants access to an already-open descriptor. Reopening its procfs
// path can fail under scoped storage even though the descriptor is writable.
// Callers use ReadAt/WriteAt; duplicates share the original seek position.
func openTarget(name string, flag int, perm os.FileMode) (*os.File, error) {
	const prefix = "/proc/self/fd/"
	if !strings.HasPrefix(name, prefix) {
		return os.OpenFile(name, flag, perm)
	}
	value := strings.TrimPrefix(name, prefix)
	fd, err := strconv.Atoi(value)
	if err != nil || fd < 0 || strconv.Itoa(fd) != value {
		return nil, errors.New("invalid direct output descriptor")
	}
	duplicate, err := unix.FcntlInt(uintptr(fd), unix.F_DUPFD_CLOEXEC, 0)
	if err != nil {
		return nil, &os.PathError{Op: "dup", Path: name, Err: err}
	}
	file := os.NewFile(uintptr(duplicate), name)
	if file == nil {
		unix.Close(duplicate)
		return nil, errors.New("invalid duplicated output descriptor")
	}
	mode, err := unix.FcntlInt(file.Fd(), unix.F_GETFL, 0)
	if err == nil {
		access, requested := mode&unix.O_ACCMODE, flag&(os.O_WRONLY|os.O_RDWR)
		if mode&unix.O_APPEND != 0 || flag&os.O_APPEND != 0 ||
			(requested == os.O_RDWR && access != unix.O_RDWR) ||
			(requested == os.O_WRONLY && access == unix.O_RDONLY) ||
			(requested == os.O_RDONLY && access == unix.O_WRONLY) {
			err = errors.New("direct output descriptor does not support requested access")
		}
	}
	if err == nil && flag&os.O_TRUNC != 0 {
		err = file.Truncate(0)
	}
	if err != nil {
		file.Close()
		return nil, err
	}
	return file, nil
}
