#!/bin/zsh
# Fetches pinned third-party sources as tarballs (much faster than SwiftPM's full-history git mirror).
set -e
cd "$(dirname "$0")/.."
GRDB_VERSION=7.11.1
if [[ ! -f Vendor/GRDB/Package.swift ]]; then
  mkdir -p Vendor
  curl -fsSL "https://codeload.github.com/groue/GRDB.swift/tar.gz/refs/tags/v$GRDB_VERSION" -o /tmp/grdb.tgz
  rm -rf Vendor/GRDB && mkdir -p Vendor/GRDB
  tar -xzf /tmp/grdb.tgz -C Vendor/GRDB --strip-components 1
  rm -rf Vendor/GRDB/Tests Vendor/GRDB/Documentation Vendor/GRDB/Playgrounds Vendor/GRDB/*.xcworkspace
  # Drop the test target (its sources aren't vendored).
  python3 - <<'PY'
p = "Vendor/GRDB/Package.swift"
s = open(p).read()
i = s.find(".testTarget(")
if i >= 0:
    depth, j = 0, i + len(".testTarget")
    while True:
        c = s[j]
        if c == "(": depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0: break
        j += 1
    end = j + 1
    if s[end:end+1] == ",": end += 1
    s = s[:i] + s[end:]
    open(p, "w").write(s)
PY
  echo "GRDB $GRDB_VERSION → Vendor/GRDB"
fi

# Neural voice engine (sherpa-onnx C API, prebuilt for Apple silicon).
SHERPA_VERSION=1.13.8
if [[ ! -f Vendor/sherpa/lib/libsherpa-onnx-c-api.dylib ]]; then
  S=sherpa-onnx-v$SHERPA_VERSION-osx-arm64-shared
  curl -fsSL "https://github.com/k2-fsa/sherpa-onnx/releases/download/v$SHERPA_VERSION/$S.tar.bz2" -o /tmp/sherpa.tbz
  mkdir -p Vendor/sherpa/include Vendor/sherpa/lib
  tar -xjf /tmp/sherpa.tbz -C /tmp
  cp /tmp/$S/include/sherpa-onnx/c-api/c-api.h Vendor/sherpa/include/
  cp /tmp/$S/lib/libsherpa-onnx-c-api.dylib /tmp/$S/lib/libonnxruntime.dylib Vendor/sherpa/lib/
  printf 'module SherpaOnnx {\n    header "c-api.h"\n    export *\n}\n' > Vendor/sherpa/include/module.modulemap
fi
