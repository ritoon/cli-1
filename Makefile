.SECONDEXPANSION:

NPM_VERSION=3.8.7
NODE_VERSION=6.0.0

DIST_DIR?=dist
CACHE_DIR?=tmp/cache
VERSION=$(shell ./bin/version)
REVISION=$(shell git log -n 1 --pretty=format:"%H")

ifeq (,$(findstring working directory clean,$(shell git status 2> /dev/null | tail -n1)))
	DIRTY=-dirty
endif
CHANNEL?:=$(shell git rev-parse --abbrev-ref HEAD)$(DIRTY)

WORKSPACE?=tmp/dev/heroku
AUTOUPDATE=yes
NODE_OS=$(OS)

$(CACHE_DIR)/node-v$(NODE_VERSION)/%:
	@mkdir -p $(@D)
	curl -fsSLo $@ https://nodejs.org/dist/v$(NODE_VERSION)/$*

$(WORKSPACE)/lib/node: NODE_OS      := $(shell go env GOOS)
$(WORKSPACE)/lib/node: ARCH    := $(subst amd64,x64,$(shell go env GOARCH))
tmp/%/heroku/lib/node: $(CACHE_DIR)/node-v$(NODE_VERSION)/node-v$(NODE_VERSION)-$$(NODE_OS)-$$(NODE_ARCH).tar.gz
	@mkdir -p $(@D)
	tar -C $(@D) -xzf $<
	cp $(@D)/node-v$(NODE_VERSION)-$(NODE_OS)-$(NODE_ARCH)/bin/node $@
	rm -rf $(@D)/node-*
	@touch $@

tmp/windows-%/heroku/lib/node.exe: $(CACHE_DIR)/node-v$(NODE_VERSION)/win-$$(NODE_ARCH)/node.exe
	@mkdir -p $(@D)
	cp $< $@
	@touch $@

NPM_ARCHIVE=$(CACHE_DIR)/npm-v$(NPM_VERSION).tar.gz
$(NPM_ARCHIVE):
	@mkdir -p $(@D)
	curl -fsSLo $@ https://github.com/npm/npm/archive/v$(NPM_VERSION).tar.gz
tmp/%/heroku/lib/npm: $(NPM_ARCHIVE)
	@mkdir -p $(@D)
	tar -C $(@D) -xzf $(NPM_ARCHIVE)
	mv $(@D)/npm-* $@
	@touch $@

$(WORKSPACE)/lib/plugins.json: package.json $(WORKSPACE)/lib/npm $(WORKSPACE)/lib/node$$(EXT) | $(WORKSPACE)/bin/heroku
	@mkdir -p $(@D)
	cp package.json $(@D)/package.json
	$(WORKSPACE)/bin/heroku build:plugins
	@ # this doesn't work in the CLI for some reason
	cd $(WORKSPACE)/lib && ./npm/cli.js dedupe > /dev/null
	cd $(WORKSPACE)/lib && ./npm/cli.js prune > /dev/null

tmp/%/heroku/lib/plugins.json: $(WORKSPACE)/lib/plugins.json
	@mkdir -p $(@D)
	cp $(WORKSPACE)/lib/plugins.json $@
	cp $(WORKSPACE)/lib/package.json $(@D)/package.json
	@rm -rf $(@D)/node_modules
	cp -r $(WORKSPACE)/lib/node_modules $(@D)

tmp/%/heroku/VERSION: bin/version
	@mkdir -p $(@D)
	echo $(VERSION) > $@

tmp/%/heroku/lib/cacert.pem: resources/cacert.pem
	@mkdir -p $(@D)
	cp $< $@

BUILD_TAGS=release
SOURCES := $(shell ls | grep '\.go')
LDFLAGS=-ldflags "-X=main.Version=$(VERSION) -X=main.Channel=$(CHANNEL) -X=main.GitSHA=$(REVISION) -X=main.NodeVersion=$(NODE_VERSION) -X=main.Autoupdate=$(AUTOUPDATE)"
GOOS=$(OS)
$(WORKSPACE)/bin/heroku: OS   := $(shell go env GOOS)
$(WORKSPACE)/bin/heroku: ARCH := $(shell go env GOARCH)
$(WORKSPACE)/bin/heroku: AUTOUPDATE=no
$(WORKSPACE)/bin/heroku: BUILD_TAGS=dev
tmp/%/heroku/bin/heroku: $(SOURCES)
	GOOS=$(GOOS) GOARCH=$(ARCH) GO386=$(GO386) GOARM=$(GOARM) go build -tags $(BUILD_TAGS) -o $@ $(LDFLAGS)

tmp/%/heroku/bin/heroku.exe: $(SOURCES) resources/exe/heroku-codesign-cert.pfx
	GOOS=$(GOOS) GOARCH=$(GOARCH) go build $(LDFLAGS) -o $@ -tags $(BUILD_TAGS)
	@osslsigncode -pkcs12 resources/exe/heroku-codesign-cert.pfx \
		-pass '$(HEROKU_WINDOWS_SIGNING_PASS)' \
		-n 'Heroku CLI' \
		-i https://toolbelt.heroku.com/ \
		-in $@ -out $@.signed
	mv $@.signed $@

resources/exe/heroku-codesign-cert.pfx:
	@gpg --yes --passphrase '$(HEROKU_WINDOWS_SIGNING_PASS)' -o resources/exe/heroku-codesign-cert.pfx -d resources/exe/heroku-codesign-cert.pfx.gpg

$(DIST_DIR)/$(VERSION)/heroku-v$(VERSION)-%.tar.xz: %
	@mkdir -p $(@D)
	cp resources/standalone/install tmp/$*/heroku/install
	cp resources/standalone/README tmp/$*/heroku/README
	tar -C tmp/$* -c heroku | xz -2 > $@

comma:=,
empty:=
space:=$(empty) $(empty)
DIST_TARGETS=$(DIST_DIR)/$(VERSION)/heroku-v$(VERSION)-darwin-amd64.tar.xz \
						 $(DIST_DIR)/$(VERSION)/heroku-v$(VERSION)-linux-amd64.tar.xz \
						 $(DIST_DIR)/$(VERSION)/heroku-v$(VERSION)-linux-386.tar.xz \
						 $(DIST_DIR)/$(VERSION)/heroku-v$(VERSION)-linux-arm.tar.xz \
						 $(DIST_DIR)/$(VERSION)/heroku-v$(VERSION)-windows-amd64.tar.xz \
						 $(DIST_DIR)/$(VERSION)/heroku-v$(VERSION)-windows-386.tar.xz \
						 $(DIST_DIR)/$(VERSION)/heroku-v$(VERSION)-freebsd-amd64.tar.xz \
						 $(DIST_DIR)/$(VERSION)/heroku-v$(VERSION)-freebsd-386.tar.xz \
						 $(DIST_DIR)/$(VERSION)/heroku-v$(VERSION)-openbsd-amd64.tar.xz \
						 $(DIST_DIR)/$(VERSION)/heroku-v$(VERSION)-openbsd-386.tar.xz
MANIFEST := $(DIST_DIR)/$(VERSION)/manifest.json
$(MANIFEST): $(WORKSPACE)/bin/heroku $(DIST_TARGETS)
	$(WORKSPACE)/bin/heroku build:manifest --dir $(@D) --version $(VERSION) --channel $(CHANNEL) --targets $(subst $(space),$(comma),$(DIST_TARGETS)) > $@

$(MANIFEST).sig: $(MANIFEST)
	@gpg --armor -u 0F1B0520 --output $@ --detach-sig $<

PREVIOUS_VERSION:=$(shell curl -fsSL https://cli-assets.heroku.com/branches/$(CHANNEL)/manifest.json | jq -r '.version')
DIST_PATCHES:=$(DIST_DIR)/$(PREVIOUS_VERSION)/heroku-v$(PREVIOUS_VERSION)-darwin-amd64.tar.patch \
						  $(DIST_DIR)/$(PREVIOUS_VERSION)/heroku-v$(PREVIOUS_VERSION)-linux-amd64.tar.patch \
						  $(DIST_DIR)/$(PREVIOUS_VERSION)/heroku-v$(PREVIOUS_VERSION)-linux-386.tar.patch \
						  $(DIST_DIR)/$(PREVIOUS_VERSION)/heroku-v$(PREVIOUS_VERSION)-linux-arm.tar.patch \
						  $(DIST_DIR)/$(PREVIOUS_VERSION)/heroku-v$(PREVIOUS_VERSION)-windows-amd64.tar.patch \
						  $(DIST_DIR)/$(PREVIOUS_VERSION)/heroku-v$(PREVIOUS_VERSION)-windows-386.tar.patch \
						  $(DIST_DIR)/$(PREVIOUS_VERSION)/heroku-v$(PREVIOUS_VERSION)-freebsd-amd64.tar.patch \
						  $(DIST_DIR)/$(PREVIOUS_VERSION)/heroku-v$(PREVIOUS_VERSION)-freebsd-386.tar.patch \
						  $(DIST_DIR)/$(PREVIOUS_VERSION)/heroku-v$(PREVIOUS_VERSION)-openbsd-amd64.tar.patch \
						  $(DIST_DIR)/$(PREVIOUS_VERSION)/heroku-v$(PREVIOUS_VERSION)-openbsd-386.tar.patch

$(DIST_DIR)/$(PREVIOUS_VERSION)/heroku-v$(PREVIOUS_VERSION)-%.tar.patch: $(DIST_DIR)/$(VERSION)/heroku-v$(VERSION)-%.tar.xz
	$(WORKSPACE)/bin/heroku build:bsdiff --new $< --channel $(CHANNEL) --target $* --out $@

DEB_VERSION:=$(firstword $(subst -, ,$(VERSION)))-1
DEB_BASE:=heroku_$(DEB_VERSION)
$(DIST_DIR)/$(VERSION)/apt/$(DEB_BASE)_%.deb: %
	@mkdir -p tmp/$(DEB_BASE)_$*.apt/DEBIAN
	@mkdir -p tmp/$(DEB_BASE)_$*.apt/usr/bin
	@mkdir -p tmp/$(DEB_BASE)_$*.apt/usr/lib
	sed -e "s/Architecture: ARCHITECTURE/Architecture: $(if $(filter amd64,$*),amd64,$(if $(filter 386,$*),i386,armel))/" resources/deb/control | \
	  sed -e "s/Version: VERSION/Version: $(DEB_VERSION)/" \
		> tmp/$(DEB_BASE)_$*.apt/DEBIAN/control
	cp -r tmp/debian-$*/heroku tmp/$(DEB_BASE)_$*.apt/usr/lib/
	ln -s ../lib/heroku/bin/heroku tmp/$(DEB_BASE)_$*.apt/usr/bin/heroku
	sudo chown -R root tmp/$(DEB_BASE)_$*.apt
	sudo chgrp -R root tmp/$(DEB_BASE)_$*.apt
	mkdir -p $(@D)
	dpkg --build tmp/$(DEB_BASE)_$*.apt $@
	sudo rm -rf tmp/$(DEB_BASE)_$*.apt

$(DIST_DIR)/$(VERSION)/apt/Packages: $(DIST_DIR)/$(VERSION)/apt/$(DEB_BASE)_amd64.deb $(DIST_DIR)/$(VERSION)/apt/$(DEB_BASE)_386.deb $(DIST_DIR)/$(VERSION)/apt/$(DEB_BASE)_arm.deb
	cd $(@D) && apt-ftparchive packages . > Packages
	gzip -c $@ > $@.gz

$(DIST_DIR)/$(VERSION)/apt/Release: $(DIST_DIR)/$(VERSION)/apt/Packages
	cd $(@D) && apt-ftparchive -c ../../../resources/deb/apt-ftparchive.conf release . > Release
	@gpg --digest-algo SHA512 -abs -u 0F1B0520 -o $@.gpg $@

$(CACHE_DIR)/git/Git-%.exe:
	@mkdir -p $(CACHE_DIR)/git
	curl -fsSLo $@ https://cli-assets.heroku.com/git/Git-$*.exe

$(DIST_DIR)/$(VERSION)/heroku-windows-%.exe: tmp/windows-%/heroku/VERSION $(CACHE_DIR)/git/Git-2.8.1-32-bit.exe $(CACHE_DIR)/git/Git-2.8.1-64-bit.exe
	@mkdir -p $(@D)
	rm -rf tmp/windows-$*-installer
	cp -r tmp/windows-$* tmp/windows-$*-installer
	cp $(CACHE_DIR)/git/Git-2.8.1-64-bit.exe tmp/windows-$*-installer/heroku/git.exe
	sed -e "s/!define Version 'VERSION'/!define Version '$(VERSION)'/" resources/exe/heroku.nsi |\
		sed -e "s/InstallDir .*/InstallDir \"\$$PROGRAMFILES$(if $(filter amd64,$*),64,)\\\Heroku\"/" \
		> tmp/windows-$*-installer/heroku/heroku.nsi
	makensis tmp/windows-$*-installer/heroku/heroku.nsi > /dev/null
	@osslsigncode -pkcs12 resources/exe/heroku-codesign-cert.pfx \
		-pass '$(HEROKU_WINDOWS_SIGNING_PASS)' \
		-n 'Heroku CLI' \
		-i https://toolbelt.heroku.com/ \
		-in tmp/windows-$*-installer/heroku/installer.exe -out $@

$(DIST_DIR)/$(VERSION)/heroku-osx.pkg: tmp/darwin-amd64/heroku/VERSION
	@echo "TODO OSX"

.PHONY: build
build: $(WORKSPACE)/bin/heroku $(WORKSPACE)/lib/npm $(WORKSPACE)/lib/node $(WORKSPACE)/lib/plugins.json $(WORKSPACE)/lib/cacert.pem

.PHONY: clean
clean:
	rm -rf tmp dist $(CACHE_DIR) $(DIST_DIR)

.PHONY: test
test: build
	$(WORKSPACE)/bin/heroku version
	$(WORKSPACE)/bin/heroku plugins
	$(WORKSPACE)/bin/heroku status

.PHONY: all
all: darwin linux windows freebsd openbsd

TARGET_DEPS =  tmp/$$(OS)-$$(ARCH)/heroku/bin/heroku$$(EXT) \
						   tmp/$$(OS)-$$(ARCH)/heroku/lib/npm           \
						   tmp/$$(OS)-$$(ARCH)/heroku/lib/plugins.json  \
						   tmp/$$(OS)-$$(ARCH)/heroku/lib/cacert.pem

%-amd64: ARCH      := amd64
%-amd64: NODE_ARCH := x64
%-386:   ARCH      := 386
%-386:   NODE_ARCH := x86
%-arm:   ARCH      := arm
%-arm:   NODE_ARCH := armv7l

darwin: OS := darwin
darwin: ARCH := amd64
darwin: NODE_ARCH := x64
.PHONY: darwin
darwin: $(TARGET_DEPS) tmp/$$(OS)-$$(ARCH)/heroku/lib/node

LINUX_TARGETS  := linux-amd64 linux-386 linux-arm
DEBIAN_TARGETS := debian-amd64 debian-386 debian-arm
linux-% debian-%j:      OS    := linux
linux-arm debian-arm:   GOARM := 6
linux-386 debian-386:   GO386 := 387
debian-%: AUTOUPDATE := no
debian-%: OS         := debian
debian-%: NODE_OS    := linux
debian-%: GOOS       := linux
.PHONY: linux debian $(LINUX_TARGETS) $(DEBIAN_TARGETS)
linux: $(LINUX_TARGETS)
debian: $(DEBIAN_TARGETS)
$(LINUX_TARGETS) $(DEBIAN_TARGETS): $(TARGET_DEPS) tmp/$$(OS)-$$(ARCH)/heroku/lib/node

FREEBSD_TARGETS := freebsd-amd64 freebsd-386
freebsd-%: OS := freebsd
.PHONY: freebsd $(FREEBSD_TARGETS)
freebsd: $(FREEBSD_TARGETS)
$(FREEBSD_TARGETS): $(TARGET_DEPS)

OPENBSD_TARGETS := openbsd-amd64 openbsd-386
openbsd-%: OS := openbsd
.PHONY: openbsd $(OPENBSD_TARGETS)
openbsd: $(OPENBSD_TARGETS)
$(OPENBSD_TARGETS): $(TARGET_DEPS)

WINDOWS_TARGETS := windows-amd64 windows-386
windows-%: OS := windows
windows-%: EXT := .exe
.PHONY: windows $(WINDOWS_TARGETS)
windows: $(WINDOWS_TARGETS)
$(WINDOWS_TARGETS): $(TARGET_DEPS) tmp/windows-$$(ARCH)/heroku/lib/node.exe

.PHONY: distwin
distwin: $(DIST_DIR)/$(VERSION)/heroku-windows-amd64.exe $(DIST_DIR)/$(VERSION)/heroku-windows-386.exe

.PHONY: disttxz
disttxz: $(MANIFEST) $(MANIFEST).sig $(DIST_TARGETS)

.PHONY: disttxpatch
disttxzpatch: $(MANIFEST) $(DIST_TARGETS) $(DIST_PATCHES)

.PHONY: releasetxz
releasetxz: $(MANIFEST) $(MANIFEST).sig $(addprefix releasetxz/,$(DIST_TARGETS))
	aws s3 cp --cache-control max-age=300 $(DIST_DIR)/$(VERSION)/manifest.json s3://heroku-cli-assets/branches/$(CHANNEL)/manifest.json
	aws s3 cp --cache-control max-age=300 $(DIST_DIR)/$(VERSION)/manifest.json.sig s3://heroku-cli-assets/branches/$(CHANNEL)/manifest.json.sig

.PHONY: releasetxz/%
releasetxz/%.tar.xz: %.tar.xz
	aws s3 cp --cache-control max-age=86400 $< s3://heroku-cli-assets/branches/$(CHANNEL)/$(VERSION)/$(notdir $<)

.PHONY: distosx
distosx: $(DIST_DIR)/$(VERSION)/heroku-osx.pkg

.PHONY: releaseosx
releaseosx: $(DIST_DIR)/$(VERSION)/heroku-osx.pkg
	aws s3 cp --cache-control max-age=3600 $(DIST_DIR)/$(VERSION)/heroku-osx.pkg s3://heroku-cli-assets/branches/$(CHANNEL)/heroku-osx.pkg

.PHONY: distdeb
distdeb: $(DIST_DIR)/$(VERSION)/apt/Packages $(DIST_DIR)/$(VERSION)/apt/Release

.PHONY: release
release: releasewin releasedeb releasetxz
	@if type cowsay >/dev/null 2>&1; then cowsay -f stegosaurus Released $(CHANNEL)/$(VERSION); fi;

.PHONY: releasedeb
releasedeb: $(DIST_DIR)/$(VERSION)/apt/Packages $(DIST_DIR)/$(VERSION)/apt/Release
	aws s3 cp --cache-control max-age=86400 $(DIST_DIR)/$(VERSION)/apt/$(DEB_BASE)_amd64.deb s3://heroku-cli-assets/branches/$(CHANNEL)/apt/$(DEB_BASE)_amd64.deb
	aws s3 cp --cache-control max-age=86400 $(DIST_DIR)/$(VERSION)/apt/$(DEB_BASE)_386.deb s3://heroku-cli-assets/branches/$(CHANNEL)/apt/$(DEB_BASE)_386.deb
	aws s3 cp --cache-control max-age=86400 $(DIST_DIR)/$(VERSION)/apt/$(DEB_BASE)_arm.deb s3://heroku-cli-assets/branches/$(CHANNEL)/apt/$(DEB_BASE)_arm.deb
	aws s3 cp --cache-control max-age=300 $(DIST_DIR)/$(VERSION)/apt/Packages s3://heroku-cli-assets/branches/$(CHANNEL)/apt/Packages
	aws s3 cp --cache-control max-age=300 $(DIST_DIR)/$(VERSION)/apt/Packages.gz s3://heroku-cli-assets/branches/$(CHANNEL)/apt/Packages.gz
	aws s3 cp --cache-control max-age=300 $(DIST_DIR)/$(VERSION)/apt/Release s3://heroku-cli-assets/branches/$(CHANNEL)/apt/Release
	aws s3 cp --cache-control max-age=300 $(DIST_DIR)/$(VERSION)/apt/Release.gpg s3://heroku-cli-assets/branches/$(CHANNEL)/apt/Release.gpg

.PHONY: releasewin
releasewin: $(DIST_DIR)/$(VERSION)/heroku-windows-amd64.exe $(DIST_DIR)/$(VERSION)/heroku-windows-386.exe
	aws s3 cp --cache-control max-age=3600 $(DIST_DIR)/$(VERSION)/heroku-windows-amd64.exe s3://heroku-cli-assets/branches/$(CHANNEL)/heroku-windows-amd64.exe
	aws s3 cp --cache-control max-age=3600 $(DIST_DIR)/$(VERSION)/heroku-windows-386.exe s3://heroku-cli-assets/branches/$(CHANNEL)/heroku-windows-386.exe

NODES = node-v$(NODE_VERSION)-darwin-x64.tar.gz \
node-v$(NODE_VERSION)-linux-x64.tar.gz \
node-v$(NODE_VERSION)-linux-x86.tar.gz \
node-v$(NODE_VERSION)-linux-armv7l.tar.gz \
win-x64/node.exe \
win-x86/node.exe

NODE_TARGETS := $(foreach node, $(NODES), $(CACHE_DIR)/node-v$(NODE_VERSION)/$(node))
.PHONY: deps
deps: $(NPM_ARCHIVE) $(NODE_TARGETS) $(CACHE_DIR)/git/Git-2.8.1-64-bit.exe $(CACHE_DIR)/git/Git-2.8.1-32-bit.exe

.DEFAULT_GOAL=build
