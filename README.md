Installer for statically-linked tree-sitter.  Downloads the latest stable
source package, builds it, and installs it to a **non-system-wide**
directory.

## Prerequisites

To run the bootstrapper, you must have the following tools must installed
and available in your `$PATH`:
- [curl](https://curl.se/) - you likely already have this
- [sha256sum](https://linux.die.net/man/1/sha256sum) or
  [shasum](https://linux.die.net/man/1/shasum) - only need one or the
  other, and you likely already have one of them
- [jq](https://jqlang.org/)
- musl/libclang development tools.  On Debian-based systems:
  ```bash
  sudo apt-get update && sudo apt-get install -y musl-tools musl-dev clang libclang-dev
  ```

## Installation

Run `./bootstrap.sh` to install tree-sitter to the directory given by
environment variable `PREFIX`.  If `PREFIX` is unspecified, the install
directory defaults to `<BOOTSTRAP-SCRIPT-DIR>/.install`.

# Legal

This software is distributed under the [Zero-Clause BSD License](LICENSE).
The license covers only the script(s) and source code included in this
distribution.  **It DOES NOT cover the software downloaded by the
script(s)**.  The software packages downloaded by the script(s) have their
own copyright holders, and are covered by their own respective licenses.
