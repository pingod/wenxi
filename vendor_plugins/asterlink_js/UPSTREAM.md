# Embedded runtime

QuickJS-NG 0.14.0, upstream https://github.com/quickjs-ng/quickjs/tree/v0.14.0.
Sources copied without changes from the official v0.14.0 tag archive.
UPSTREAM-SHA256.json records the pinned files. The third-party pub archive
evaluated during prototyping was not identical to this tag and is not used.
The original MIT license is in src/quickjs/LICENSE and source headers.

Only the engine is linked. quickjs-libc, filesystem, process, module downloads and
native module loading are not linked or exposed. bridge.c is the AsterLink adapter.
No code is fetched during platform builds. Update the pinned sources and rerun the
native runtime and source package tests when upgrading QuickJS.
