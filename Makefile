.PHONY: build app cli bridge deps test install uninstall probe

# A stable signing identity keeps macOS privacy approvals across rebuilds (an ad-hoc
# signature changes every build). The first "Apple Development" identity in the
# keychain is used automatically; override with SIGN_IDENTITY="name" or SIGN_IDENTITY=-.
export SIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | grep -o '"Apple Development[^"]*"' | head -1 | tr -d '"' | grep . || echo -)

build: cli bridge app

cli:
	swift build -c release

app: cli bridge
	xcodegen generate
	xcodebuild -project ProTypeUltra.xcodeproj -scheme ProTypeUltra -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData build -quiet
	bash scripts/assemble-app.sh

deps:
	bash scripts/bootstrap.sh

bridge: deps
	mkdir -p build
	clang++ -std=c++23 -O2 -isystem .deps/virtualhid/include -isystem .deps/virtualhid/vendor/vendor/include Bridge/output.cpp -framework IOKit -framework CoreFoundation -o build/protype-output

test:
	swift test

probe: cli
	.build/release/protype probe

install: build
	bash scripts/install.sh

uninstall:
	sudo bash scripts/uninstall.sh
