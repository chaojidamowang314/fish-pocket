#!/usr/bin/env bash
# Download python.org's pinned iOS build of CPython (Python.xcframework plus its
# standard library) into vendor/python/ios, checked against its sha256, and make
# the copy the app uses, vendor/python/rooted:
#   - libpython and every extension module (lib-dynload) depend on DshRoot
#     instead of libSystem, the same one load command fetch-nodejs-mobile.sh
#     changes for Node, so Python sees the engine's filesystem view;
#   - what cannot run or only serves CPython's own development is pruned: the
#     test suite and its extension modules, IDLE, Tk, and optimised bytecode
#     that never loads (-O is not offered).
# The app's build phase (app/project.yml) installs the standard library into
# the bundle and turns each extension module into a framework, as CPython's
# Apple/iOS documentation describes (Python.xcframework/build/utils.sh).
set -euo pipefail
version="3.15.2"
sha256="0f9fc7f61ceb8278a69fc7ec6089aad81789a96fa42f31cfe6d2f5f860d20a62"
root="$(cd "$(dirname "$0")/.." && pwd)"
dir="$root/vendor/python"
archive="$dir/python-$version-iOS-XCframework.tar.gz"
mkdir -p "$dir"
if [ ! -f "$archive" ]; then
  curl -fL --retry 3 -o "$archive.part" "https://www.python.org/ftp/python/$version/python-$version-iOS-XCframework.tar.gz"
  mv "$archive.part" "$archive"
fi
echo "$sha256  $archive" | shasum -a 256 -c -
rm -rf "$dir/ios"
mkdir -p "$dir/ios"
tar xzf "$archive" -C "$dir/ios"
rm -rf "$dir/rooted"
mkdir -p "$dir/rooted"
cp -R "$dir/ios/Python.xcframework" "$dir/rooted/"
framework="$dir/rooted/Python.xcframework"

stdlib="$framework/lib/python3.15"
rm -rf "$stdlib/test" "$stdlib/idlelib" "$stdlib/tkinter" "$stdlib/turtledemo" "$stdlib/turtle.py" "$stdlib/__phello__"
find "$stdlib" -name '*.opt-1.pyc' -delete -o -name '*.opt-2.pyc' -delete
for dynload in "$framework"/ios-*/lib-*/python3.15/lib-dynload; do
  # _remote_debugging attaches to other processes, which an app cannot do.
  rm -f "$dynload"/_test*.so "$dynload"/_ctypes_test*.so "$dynload"/_xxtestfuzz*.so "$dynload"/xx*.so "$dynload"/_remote_debugging*
done

# Unsigned, as python.org ships them: the app's build signs each one, and an
# extension module's framework must be signed with its own bundle identifier.
for binary in "$framework"/ios-*/Python.framework/Python "$framework"/ios-*/lib-*/python3.15/lib-dynload/*.so; do
  install_name_tool -change /usr/lib/libSystem.B.dylib @rpath/DshRoot.framework/DshRoot "$binary" 2>/dev/null
done
echo "Python.xcframework ready: $dir/ios, $dir/rooted"
