# usage: make [CONFIG=debug|release]

ifeq ($(CONFIG), debug)
	CFLAGS=-Onone -g
else
	CFLAGS=-O
endif

PLIST=$(shell grep -A1 $(1) src/Info.plist | tail -1 | cut -d'>' -f2 | cut -d'<' -f1)
HAS_SIGN_IDENTITY=$(shell security find-identity -v -p codesigning | grep -q "Apple Development" && echo 1 || echo 0)
BUILD_NUM=$(shell git rev-list --count HEAD 2>/dev/null || echo 1)


Memmon.app: SDK_PATH=$(shell xcrun --show-sdk-path --sdk macosx)
Memmon.app: src/*
	@mkdir -p Memmon.app/Contents/MacOS/
	swiftc ${CFLAGS} src/main.swift -target x86_64-apple-macos10.10 \
	-emit-executable -sdk ${SDK_PATH} -o bin_x64
	swiftc ${CFLAGS} src/main.swift -target arm64-apple-macos10.10 \
	-emit-executable -sdk ${SDK_PATH} -o bin_arm64
	lipo -create bin_x64 bin_arm64 -o Memmon.app/Contents/MacOS/Memmon
	@rm bin_x64 bin_arm64
	@echo 'APPL????' > Memmon.app/Contents/PkgInfo
	@mkdir -p Memmon.app/Contents/Resources/
	@cp src/AppIcon.icns Memmon.app/Contents/Resources/AppIcon.icns
	@cp src/Info.plist Memmon.app/Contents/Info.plist
	@/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUM}" Memmon.app/Contents/Info.plist
	@touch Memmon.app
	@echo
ifeq ($(HAS_SIGN_IDENTITY),1)
	codesign -v -s 'Apple Development' --options=runtime --timestamp Memmon.app
else
	codesign -v -s - Memmon.app
endif
	@echo
	@echo 'Verify Signature...'
	@echo
	codesign -dvv Memmon.app
	@echo
	codesign -vvv --deep --strict Memmon.app
ifeq ($(HAS_SIGN_IDENTITY),1)
	@echo
	-spctl -vvv --assess --type exec Memmon.app
endif


.PHONY: test
test: SDK_PATH=$(shell xcrun --show-sdk-path --sdk macosx)
test:
	swiftc -Onone src/main.swift -emit-executable -sdk ${SDK_PATH} -o bin_selftest
	./bin_selftest --self-test; s=$$?; rm -f bin_selftest; exit $$s


.PHONY: clean
clean:
	rm -rf Memmon.app bin_x64 bin_arm64 bin_selftest


.PHONY: release
release: VERSION=$(call PLIST,CFBundleShortVersionString)
release: Memmon.app
	tar -czf "Memmon_v${VERSION}.tar.gz" Memmon.app
