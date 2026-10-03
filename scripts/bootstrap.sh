#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
revision=ba98de7fae2d529b9debe82890765dc66246f4ff
mkdir -p .deps
if [[ ! -d .deps/virtualhid/.git ]]; then
  git clone --no-checkout https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice.git .deps/virtualhid
  git -C .deps/virtualhid checkout --detach "$revision"
  git -C .deps/virtualhid submodule update --init --recursive
fi
if [[ "$(git -C .deps/virtualhid rev-parse HEAD)" != "$revision" ]]; then
  echo 'Unexpected virtual-HID revision. Use a fresh .deps directory.' >&2
  exit 1
fi
if [[ ! -f .deps/virtualhid/vendor/vendor/include/pqrs/unix_domain_stream.hpp ]]; then
  cmake -S .deps/virtualhid/vendor -B .deps/virtualhid/vendor/build -DCPM_SOURCE_CACHE="$PWD/.deps/cpm"
fi
printf '%s  %s\n' ff8c7fdc5e25387c7805fc7509a0fa9cf98f69ba582704f717fddcae47424387 .deps/virtualhid/dist/Karabiner-DriverKit-VirtualHIDDevice-8.6.0.pkg | shasum -a 256 --check
