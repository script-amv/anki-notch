# With only the Command Line Tools installed (no Xcode), SwiftPM needs explicit
# search paths for the Swift Testing framework; with full Xcode plain
# `swift test` works and TESTFLAGS stays empty.
.PHONY: build run test app

DEV := $(shell xcode-select -p)
ifeq ($(DEV),/Library/Developer/CommandLineTools)
FW := $(DEV)/Library/Developer/Frameworks
TESTFLAGS := -Xswiftc -F$(FW) -Xlinker -F$(FW) -Xlinker -rpath -Xlinker $(FW) -Xlinker -rpath -Xlinker $(DEV)/Library/Developer/usr/lib
endif

# make test FILTER=ReviewSessionTests
test:
	swift test $(TESTFLAGS) $(if $(FILTER),--filter "$(FILTER)")

build:
	swift build

run:
	swift run AnkiNotch
