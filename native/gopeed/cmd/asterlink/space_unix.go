//go:build !windows

package main

import (
	"os"
	"path/filepath"
	"syscall"
)

// availableSpace reports the free bytes for the volume that holds path. The
// destination directory may not exist yet, so walk up to the nearest existing
// parent, mirroring the Windows implementation.
func availableSpace(path string) (uint64, error) {
	absolute, err := filepath.Abs(path)
	if err != nil {
		return 0, err
	}
	for {
		if _, err := os.Stat(absolute); err == nil {
			break
		}
		parent := filepath.Dir(absolute)
		if parent == absolute {
			return 0, os.ErrNotExist
		}
		absolute = parent
	}
	var stat syscall.Statfs_t
	if err := syscall.Statfs(absolute, &stat); err != nil {
		return 0, err
	}
	// Bsize is the preferred block size; Bavail excludes blocks reserved for
	// root, which matches what an unprivileged download can actually write.
	return uint64(stat.Bavail) * uint64(stat.Bsize), nil
}
