#!/usr/bin/env bash
# Download, build, and install the latest tree-sitter-cli from source.  Try
# to build static binaries that can simply be copied to other machines
# (possibly running legacy OS) and Just Work (TM).
#
# Set `PREFIX` environment variable to specify a custom install dir.  If
# unset, install dir defaults to `THIS-SCRIPT'S-CONTAINING-DIR/.install`.
#
# TODO:
# - [ ] Support Windows build target (amd64)
# - [ ] Support Windows build host (auto-install Git Bash?)
# - [ ] Support Mac OS build target (amd64 and aarch64)
# - [ ] Support Mac OS build host
# - [ ] Auto-install prerequisites `jq` and `zig`
# - [ ] Use `wget` as downloader if `curl` isn't available
# - [ ] Add `--clean` flag to re-download and build from scratch
set -Eeo pipefail

self="$(basename "$0")"
here="$(cd "$(dirname "$0")" && pwd)"
export PREFIX="${PREFIX:-"$here/.install"}"
export DOWNLOAD_DIR="${DOWNLOAD_DIR:-"$here/.download"}"
dbg() { true && (printf '[DBG]: '; printf "$@") >&2 || :; }
error() { (printf '\n%s: ERROR: ' "$self"; printf "$@") >&2; exit 1; }
unquote_json() { sed -E 's|^.*"([^"]+)".*$|\1|'; }

# Target host CPU/OS by default.
TARGET_CPU="$(printf '%s' "${TARGET_CPU:-$(uname -m)}" | tr [A-Z] [a-z])"
TARGET_OS="$(printf '%s' "${TARGET_OS:-$(uname -s)}" | tr [A-Z] [a-z])"

case "$TARGET_OS" in
  win*|mingw*|msys*|cygwin*) TARGET_OS=windows;;
  darwin*) TARGET_OS=macos;;
esac
case "$TARGET_CPU" in
  x86_64|x64|amd64) TARGET_CPU=x86_64;;
  arm64|aarch64) TARGET_CPU=aarch64;;
esac

# Determine zig's target triple based on CPU/OS.
if [ "$TARGET_OS" = windows ] && [ "$TARGET_CPU" = aarch64 ]; then
  target_triple="aarch64-windows-gnu"
elif [ "$TARGET_OS" = windows ] && [ "$TARGET_CPU" = x86_64 ]; then
  target_triple="x86_64-windows-msvc"
elif [ "$TARGET_OS" = linux ]; then
  target_triple="$TARGET_CPU-linux-musl"
elif [ "$TARGET_OS" = macos ]; then
  target_triple="$TARGET_CPU-macos.13"
else
  error 'unsupported CPU/OS target: %s\n' "$TARGET_CPU/$TARGET_OS"
fi
dbg 'zig target triple: %s\n' "$target_triple"

### Check prerequisites.
check_prereq() {
  command -v "$1" >/dev/null 2>&1 && return
  printf '%s: ERROR: missing prerequisite %s.\n' "$self" "'$1'" >&2
  shift; [ $# -gt 0 ] && printf "$@" >&2
  exit 1
}
check_prereq 'curl'
#check_prereq 'zig'
check_prereq 'jq'

if command -v sha256sum >/dev/null 2>&1; then
  :
elif command -v shasum >/dev/null 2>&1; then
  sha256sum() { command shasum -a 256 "$@"; }
else
  error "missing prerequisite 'sha256sum'.\\n"
fi

mkdir -p "$PREFIX" "$DOWNLOAD_DIR"
[ -d "$PREFIX" ] || error 'could not mkdir %s\n' "'$PREFIX'"
[ -d "$DOWNLOAD_DIR" ] || error 'could not mkdir %s\n' "'$DOWNLOAD_DIR'"

### Zscaler Compatibility ###

# Be compatible with corporate Zscaler environments.  If we're on WSL, then
# get Zscaler Root CA from Windows' trust store, append it to a copy of the
# system certificate bundle, and tell OpenSSL to use _that_ as the bundle.
if command -v wslpath >/dev/null && [ -n "$(which wslpath 2>/dev/null)" ]; then
  openssl_dir="$(openssl version -d | sed 's|OPENSSLDIR:[ '$'\t'']*"\([^"]*\)"|\1|')"
  dbg 'In WSL; using openssl dir %s\n' "'$openssl_dir'"
  cp "$openssl_dir/cert.pem" "$PREFIX/cert.pem"

  dbg 'Getting Zscaler Root CA...\n'
  zscaler_root_ca="$(powershell.exe \
    -NoProfile -ExecutionPolicy Bypass -Command 2>/dev/null "$(cat <<'EOF'
# Find the Zscaler Root CA in the Local Machine Trusted Root store.
$certs = Get-ChildItem "Cert:\LocalMachine\Root" |
  Where-Object { $_.Subject -like "*Zscaler*" }

# Export each cert to Base64 (PEM) format.
$pemCert = ""
foreach ($cert in $certs) {
  # Convert cert to raw Base64.
  $base64 = [System.Convert]::ToBase64String($cert.Export(
      [System.Security.Cryptography.X509Certificates.X509ContentType]::Cert
  ))
  # Wrap Base64 text to 64-char lines.
  $base64 = ($base64 -split "(.{64})") |
      Where-Object { $_ } | ForEach-Object { $_ } | Out-String
  # Add header and footer.
  $pemCert +=
      "-----BEGIN CERTIFICATE-----`n" +
      $base64 +
      "-----END CERTIFICATE-----`n"
}
# Dump the PEM-format certificates to standard output.
$pemCert.TrimEnd()
EOF
  )" | tr -d $'\r')" || : # don't fail if not in a zscaler environment
  printf '%s\n' "$zscaler_root_ca"  >> "$PREFIX/cert.pem"
  export SSL_CERT_FILE="$PREFIX/cert.pem"
  dbg 'SSL_CERT_FILE = %s\n' "'$SSL_CERT_FILE'"
fi

# Use Github API to determine latest release of project $1, where $1 is
# GITHUB-ACCOUNT/PROJECT-NAME (e.g., "burntsushi/ripgrep" to get latest
# ripgrep).  Output a JSON object with info about the latest release.
gh_latest_release() {
  (set -eo pipefail
  local filter='(rc|alpha|beta|nightly)'
  dbg 'Getting latest stable %s...\n' "'$(sed 's#.*/##' <<< "$1")'"
  # Get a JSON array of the project's releases.
  curl -kfsSL \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2026-03-10" \
    "https://api.github.com/repos/$1/releases" |
  # Determine latest STABLE release (no betas, prereleases, etc).
  jq '[ .[]
    # Filter out releases tagged "-rc", "-alpha", etc.
    | select(.tag_name | test("[_-]'"$filter"'[_-]?([0-9]+|\\\\b)") | not)

    # Filter out releases explicitly marked prerelease.
    | select(.prerelease | not)
    ]
    # Sort by version.
    | sort_by(.tag_name | sub("^.*?(?<x>[0-9]+(\\.[0-9]+)*).*$"; "\(.x)")
              | split(".") | map(tonumber))
    # Last element is latest release.
    .[-1]')
}

# Read JSON Github asset array from stdin and retrieve the asset whose
# "browser_download_url" matches the given jq regex $1.
gh_getbyurl() {
  jq '.assets[] | select(.browser_download_url | test("'"$1"'"; "i"))'
}

# Escape string $1 to make it usable in a jq regex.
jqreesc() {
  sed -e 's#\([].*+?^$()|{}\[]\)#\\\1#g' -e 's#\(["\]\)#\\\1#g' <<< "$1"
}

# Download a given URL $1 to directory $2.  Optionally give a SHA hash $3
# to verify the download.  Skip the download if a local copy already exists
# and its SHA matches the given SHA.
download_and_extract() {
  local url="$1" dldir="$2" expected_sha="$3"
  local pkg="${url##*/}"
  if [ -z "$url" ] || [ -z "$dldir" ]; then
    printf '%s: ERROR: bad arguments\n' "${FUNCNAME[0]}" >&2
    printf 'Usage: %s URL DST-DIR [SHA]\n' "${FUNCNAME[0]}" >&2
    exit 1
  fi
  mkdir -p "$dldir"
  [ -d "$dldir" ] || error 'could not mkdir %s\n' "'$dldir'"

  # Don't download if we can verify that we already have it.
  local actual_sha= skip_download=false
  if [ -f "$dldir/$pkg" ] && [ -r "$dldir/$pkg" ]; then
    actual_sha="$(sha256sum "$dldir/$pkg" | awk '{print $1}')"
    if [ -n "$expected_sha" ] && [ "$actual_sha" = "$expected_sha" ]; then
      dbg 'Already have %s; skipping download.\n' "$pkg"
      skip_download=true
    fi
  fi
  if ! $skip_download; then
    dbg 'Downloading %s...\n' "'$url'"
    curl -kfL "$url" > "$dldir/$pkg"
    actual_sha="$(sha256sum "$dldir/$pkg" | awk '{print $1}')"

    if [ -n "$expected_sha" ] && [ "$actual_sha" != "$expected_sha" ]; then
      printf '%s: ERROR: downloaded package corrupted.\n' "$self" >&2
      printf '  expected sha = %s\n' "'$expected_sha'" >&2
      printf '  actual sha   = %s\n' "'$actual_sha'" >&2
      printf 'Check your network and firewall settings.\n' >&2
      exit 1
    fi
  fi

  dbg 'Extracting %s...\n' "'$pkg'"
  case "$pkg" in
    *.tar.gz|*.tgz)  (cd "$dldir" && tar xzf "$pkg");;
    *.tar.bz2|*.tbz) (cd "$dldir" && tar xjf "$pkg");;
    *.tar.xz|*.txz)  (cd "$dldir" && tar xJf "$pkg");;
    *zip)            (cd "$dldir" && unzip -q "$pkg");;
    *) error 'unrecogized archive format: %s\n' "$pkg"
  esac
}

### Libclang - needed by tree-sitter dependency bindgen ###

# We're hard-coding v21.1.0 for libclang, as that's the clang version used
# by zig-0.16.  TODO: support aarch64-linux in addition to x86_64-linux.
if false; then
  dbg 'Getting libclang...\n'
  libclang_tag="21.1.0"
  [ "$TARGET_OS" = linux ] || error '!!! TODO: Windows and Mac OS support !!!\n'
  [ "$TARGET_CPU" = x86_64 ] || error '!!! TODO: aarch64 support !!!\n'
  libclang_pkg="LLVM-$libclang_tag-Linux-X64.tar.xz"
  libclang_url="https://github.com/llvm/llvm-project/releases/download/llvmorg-$libclang_tag/$libclang_pkg"
  dldir="$DOWNLOAD_DIR/libclang-$TARGET_CPU-$TARGET_OS"
  mkdir -p "$dldir"
  [ -d "$dldir" ] || error 'could not mkdir %s\n' "'$dldir'"

  if [ -f "$dldir/$libclang_pkg" ]; then
    dbg '%s already downloaded; skipping...\n' "$libclang_pkg"
  else
    dbg 'downloading %s...\n' "$libclang_url"
    curl -kfL "$libclang_url" > "$dldir/$libclang_pkg"
  fi

  dbg 'extracting %s...\n' "$libclang_pkg"
  (cd "$dldir"
  tar --strip-components=1 --wildcards '*/lib' -xJ < "$libclang_pkg")
  export LIBCLANG_PATH="$DOWNLOAD_DIR/libclang-$TARGET_CPU-$TARGET_OS/lib"
  while read d; do
    BINDGEN_EXTRA_CLANG_ARGS="$BINDGEN_EXTRA_CLANG_ARGS -I$d"
  done \
  <<< "$(find "$DOWNLOAD_DIR/libclang-$TARGET_CPU-$TARGET_OS" -iname 'include' -a -type d)"

  dbg 'pulling some shenanigans to make bindgen cooperate with zig...\n'
  zig_libc_dir="$(zig env |
    grep $'^[ \t]*\.lib_dir[ \t]*=' |
    sed $'s|^.*"\\([^"]*\\)".*$|\\1|g')"
  BINDGEN_EXTRA_CLANG_ARGS="$BINDGEN_EXTRA_CLANG_ARGS \
    -I$zig_libc_dir/libc/musl/include \
    -I$zig_libc_dir/libc/include/x86_64-linux-musl"
  BINDGEN_EXTRA_CLANG_ARGS="$BINDGEN_EXTRA_CLANG_ARGS -target x86_64-linux-musl"
  export BINDGEN_EXTRA_CLANG_ARGS

  dbg 'BINDGEN_EXTRA_CLANG_ARGS:\n'
  for i in $BINDGEN_EXTRA_CLANG_ARGS; do dbg '    %s\n' "$i"; done
fi

# Map the host compiler target probe explicitly to Zig's naming convention.
# export CC_x86_64_unknown_linux_gnu="$DOWNLOAD_DIR/zig-wrapper cc -target x86_64-linux-gnu"
# export CXX_x86_64_unknown_linux_gnu="$DOWNLOAD_DIR/zig-wrapper c++ -target x86_64-linux-gnu"
#
# # Re-verify the musl cross-compilation pipeline strings.
# export CC_x86_64_unknown_linux_musl="$DOWNLOAD_DIR/zig-wrapper cc -target x86_64-linux-musl"
# export CXX_x86_64_unknown_linux_musl="$DOWNLOAD_DIR/zig-wrapper c++ -target x86_64-linux-musl"
#
# # Need a wrapper script to convert to zig's expected target triple.
# cat << 'EOF' > "$DOWNLOAD_DIR/zig-wrapper"
# #!/usr/bin/env bash
# # TOOL=''
# # case "$1" in
# #   cc|c++) TOOL="$1"; shift;;
# # esac
#
# # Reconstruct the arguments, swapping out the incompatible Rust triple
# ARGS=()
# for arg in "$@"; do
#   if [ "$arg" = "x86_64-unknown-linux-musl" ]; then
#     ARGS+=("x86_64-linux-musl")
#   elif [ "$arg" = "x86_64-unknown-linux-gnu" ]; then
#     ARGS+=("x86_64-linux-gnu")
#   else
#     ARGS+=("$arg")
#   fi
# done
#
# # If the command is running a preprocess/compile flag, use 'zig cc'
# # Otherwise, fall back to the base zig binary
# if [[ " $* " == *" -E "* ]] || [[ " $* " == *" -c "* ]]; then
#   exec zig $TOOL "${ARGS[@]}"
# else
#   exec zig "${ARGS[@]}"
# fi
# EOF
# chmod +x "$DOWNLOAD_DIR/zig-wrapper"

dbg 'bindgen/zig shenanigans complete.\n'

### Rust ###

export RUSTUP_HOME="$PREFIX/rust"
export CARGO_HOME="$PREFIX/rust"
[ -f "$CARGO_HOME/env" ] && . "$CARGO_HOME/env"

mkdir -p "$CARGO_HOME"
[ -d "$CARGO_HOME" ] || error 'could not mkdir %s\n' "'$CARGO_HOME'"

if [ -f "$CARGO_HOME/.install-success" ]; then
  dbg 'rust already installed; skipping...\n'
else
  dbg 'installing rust...\n'
  rm -rf "$CARGO_HOME" "$RUSTUP_HOME"
  dldir="$DOWNLOAD_DIR/rust"
  mkdir -p "$dldir"
  [ -d "$dldir" ] || error 'could not mkdir %s\n' "'$dldir'"

  curl -kfsSL --proto '=https' --tlsv1.2 "https://sh.rustup.rs" \
    > "$dldir/rustup-init.sh"
  chmod +x "$dldir/rustup-init.sh"
  "$dldir/rustup-init.sh" \
    --no-modify-path \
    --target="x86_64-unknown-linux-musl" -y
  . "$CARGO_HOME/env"

#   cat > "$CARGO_HOME/config.toml" <<EOF
# [target.x86_64-unknown-linux-musl]
# linker = "cargo-zigbuild"
# EOF

  dbg 'Installing cargo-zigbuid...\n'
  cargo install cargo-zigbuild

  dbg 'Doing rustup stuff...\n'
  rustup update
  rustup toolchain install stable
  touch "$CARGO_HOME/.install-success"
fi

# Make sure the installer worked.
command -v cargo >/dev/null || error 'failed to install rust\n'
[ "$TARGET_OS" = linux ] || error '!!! TODO: Windows and Mac OS support !!!\n'
rustup default stable
rustup target add x86_64-unknown-linux-musl
rustup target add aarch64-unknown-linux-musl
rustup show

### Tree-Sitter ###

dbg 'Getting tree-sitter...\n'
treesitter_latest_json="$(gh_latest_release "tree-sitter/tree-sitter")"
treesitter_latest_tag="$(jq -r '.tag_name' <<< "$treesitter_latest_json")"
treesitter_download_url="https://github.com/tree-sitter/tree-sitter/archive/refs/tags/$treesitter_latest_tag.tar.gz"
dbg 'tree-sitter latest tag: %s\n' "'$treesitter_latest_tag'"
dbg 'tree-sitter download URL: %s\n' "'$treesitter_download_url'"

download_and_extract \
  "$treesitter_download_url" "$DOWNLOAD_DIR/tree-sitter"

# Build tree-sitter.
treesitter_srcdir="$(ls -1d "$DOWNLOAD_DIR"/tree-sitter/*/ | tail -n1)"
dbg 'tree-sitter srcdir: %s\n' "'$treesitter_srcdir'"
(
  cd "$treesitter_srcdir"
  [ "$TARGET_OS" = linux ] || error '!!! TODO: Windows and Mac OS support !!!\n'

  # Tree-sitter depends on QuickJS, and `cargo zigbuild` alone won't build
  # QuickJS statically, so manually inject target-specific env vars.
  # export CC="zig cc -target x86_64-linux-musl"
  # export CXX="zig c++ -target x86_64-linux-musl"
  # export CFLAGS="-O2 -fno-strict-aliasing -g0"
  # export CXXFLAGS="$CFLAGS"
  # export RUSTFLAGS="-C target-feature=+crt-static"
  dbg 'running `cargo build`...\n'
  cargo build --release --target x86_64-unknown-linux-musl -p tree-sitter-cli
)

dbg 'searching for tree-sitter binary...\n'
treesitter_bin="$(while read bin; do
  [ -x "$bin" ] || continue
  printf '%s\n' "$bin"; break;
done <<< "$(find "$treesitter_srcdir" -iname 'tree-sitter')")"
[ -n "$treesitter_bin" ] || error 'tree-sitter binary not found\n'

dbg 'found %s\n' "'$treesitter_bin'"
command -v strip >/dev/null && strip "$treesitter_bin"
dbg 'installing %s to %s...\n' "$treesitter_bin" "$PREFIX/bin"
mkdir -p "$PREFIX/bin"
[ -d "$PREFIX/bin" ] || error 'unabled to mkdir %s\n' "'$PREFIX/bin'"
cp "$treesitter_bin" "$PREFIX/bin"

printf '\n================\n'
printf 'tree-sitter installed successfully to\n  %s\n' "'$PREFIX/bin'"
ldd "$PREFIX/bin/$(basename "$treesitter_bin")"
