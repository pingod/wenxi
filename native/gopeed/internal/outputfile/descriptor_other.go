//go:build !linux && !android

package outputfile

import "os"

func openTarget(name string, flag int, perm os.FileMode) (*os.File, error) {
	return os.OpenFile(name, flag, perm)
}
