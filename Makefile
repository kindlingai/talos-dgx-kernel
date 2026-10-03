# Build every supported .6 installer sequentially; Linux is built once per page size.
SHELL := /bin/bash
.DEFAULT_GOAL := all
.NOTPARALLEL:

TALOS_VERSION     := v1.14.1
TALOS_COMMIT      := 2f86b9d2a29b413deddd7122a8420b8913813615
TALOS_REPOSITORY  := https://github.com/siderolabs/talos.git
SOURCE_DATE_EPOCH := 1789481248
TAG               := v1.14.1-dgx1022.6
ifneq ($(TAG),v1.14.1-dgx1022.6)
$(error This branch only publishes TAG=v1.14.1-dgx1022.6)
endif
VARIANTS          := proprietary-4k open-4k open-64k
VARIANT           ?= open-64k
ifeq ($(filter $(VARIANT),$(VARIANTS)),)
$(error Unsupported VARIANT=$(VARIANT); choose $(VARIANTS))
endif
DRIVER_FLAVOR     := $(firstword $(subst -, ,$(VARIANT)))
KERNEL_PAGE_SIZE  := $(lastword $(subst -, ,$(VARIANT)))
KERNEL_RELEASE    := 6.17.13-talos-dgx1022.6-$(KERNEL_PAGE_SIZE)
KERNEL_CONFIG     := kernel/config-$(KERNEL_PAGE_SIZE)
ifneq ($(DRIVER_FLAVOR)-$(KERNEL_PAGE_SIZE),$(VARIANT))
$(error DRIVER_FLAVOR/KERNEL_PAGE_SIZE contradict VARIANT)
endif
ifneq ($(KERNEL_RELEASE),6.17.13-talos-dgx1022.6-$(KERNEL_PAGE_SIZE))
$(error KERNEL_RELEASE contradicts page geometry)
endif
ifneq ($(KERNEL_CONFIG),kernel/config-$(KERNEL_PAGE_SIZE))
$(error KERNEL_CONFIG contradicts page geometry)
endif
KBUILD_BUILD_VERSION := $(shell python3 scripts/kernel-fingerprint.py $(KERNEL_CONFIG))

IMAGE       ?= ghcr.io/kindlingai/talos-dgx-kernel/installer
SIGNING_KEY ?= $(CURDIR)/keys/module-signing.pem
PROGRESS    ?= auto
BUILDER     ?= talos-dgx-kernel
REQUIRE_EXISTING_BUILDER ?= false
MODULE_SIGNING_CERT_SHA256 = $(shell bash scripts/signing-key-id.sh "$(SIGNING_KEY)" 2>/dev/null)
BUILDKIT_IMAGE := moby/buildkit:v0.33.1@sha256:cec9f139f45e93c5c69c60f8b07cfad9f43f4ef6b6a6cd917527fea5ff2e3dea

OUT       := $(CURDIR)/_out
TALOS_SRC := $(CURDIR)/.work/talos-$(KERNEL_PAGE_SIZE)
ifneq ($(TALOS_SRC),$(CURDIR)/.work/talos-$(KERNEL_PAGE_SIZE))
$(error Refusing to replace a Talos source directory outside the page-specific .work path)
endif
IMAGER    := talos-dgx-kernel/imager:$(TALOS_VERSION)-$(KERNEL_PAGE_SIZE)
VARIANT_OUT := $(OUT)/variants/$(VARIANT)

export TALOS_VERSION TALOS_COMMIT KERNEL_RELEASE KERNEL_CONFIG KERNEL_PAGE_SIZE DRIVER_FLAVOR VARIANT TAG
export KBUILD_BUILD_VERSION SOURCE_DATE_EPOCH SIGNING_KEY OUT TALOS_SRC MODULE_SIGNING_CERT_SHA256

BAKE := docker buildx bake --builder $(BUILDER) --progress $(PROGRESS) --allow fs.read=$(SIGNING_KEY)
IMAGER_RUN := docker run --rm -i --env SOURCE_DATE_EPOCH \
	--volume $(OUT)/oci:/oci:ro --volume $(VARIANT_OUT):/out $(IMAGER) - --output /out

.PHONY: all variant package builder signing-key check-signing-key kernel dispram talos-source talos installer iso push release test cache-usage print-variant verify

# Intentionally ordered even under make -j: no dual 16-worker Linux compiles.
all:
	$(MAKE) dispram
	$(MAKE) talos VARIANT=open-4k
	$(MAKE) package VARIANT=proprietary-4k
	$(MAKE) package VARIANT=open-4k
	$(MAKE) talos VARIANT=open-64k
	$(MAKE) package VARIANT=open-64k
	python3 scripts/artifacts.py finalize $(OUT)
	$(MAKE) verify

# Optional bounded single-variant build. `make` remains the full release matrix.
variant: dispram talos
	$(MAKE) package VARIANT=$(VARIANT)

builder:
	@if ! docker buildx inspect $(BUILDER) >/dev/null 2>&1; then \
		test "$(REQUIRE_EXISTING_BUILDER)" != true || { echo "Required persisted builder missing: $(BUILDER)" >&2; exit 1; }; \
		docker buildx create --name $(BUILDER) --driver docker-container --driver-opt image=$(BUILDKIT_IMAGE); \
	fi
	docker buildx inspect $(BUILDER)

signing-key: $(SIGNING_KEY)
$(SIGNING_KEY):
	mkdir -p $(@D)
	umask 077 && openssl req -new -nodes -utf8 -sha512 -days 36500 -batch -x509 \
		-config kernel/x509.genkey -outform PEM -out $@ -keyout $@

check-signing-key:
	@test -f "$(SIGNING_KEY)" || { echo "Provide the existing module signing key with SIGNING_KEY" >&2; exit 1; }
	@test -n "$(MODULE_SIGNING_CERT_SHA256)" || { echo "Invalid signing key/certificate" >&2; exit 1; }

kernel: check-signing-key builder
	$(BAKE) kernel

dispram: builder
	$(BAKE) dispram-extension

talos-source: $(TALOS_SRC)/.git/talos-dgx-kernel-$(TALOS_COMMIT)-$(KERNEL_RELEASE)
$(TALOS_SRC)/.git/talos-dgx-kernel-$(TALOS_COMMIT)-$(KERNEL_RELEASE): talos/source.patch scripts/prepare-talos.py
	rm -rf $(TALOS_SRC)
	git init -q $(TALOS_SRC)
	git -C $(TALOS_SRC) fetch -q --depth=1 $(TALOS_REPOSITORY) $(TALOS_COMMIT)
	git -C $(TALOS_SRC) -c advice.detachedHead=false checkout -q FETCH_HEAD
	git -C $(TALOS_SRC) apply $(CURDIR)/talos/source.patch
	python3 scripts/prepare-talos.py $(TALOS_SRC) $(KERNEL_RELEASE) $(KERNEL_PAGE_SIZE)
	touch $@

talos: kernel talos-source
	$(BAKE) talos
	python3 scripts/artifacts.py shared $(OUT) $(VARIANT)

# Internal packaging stage: reject missing/stale shared kernel and Talos exports.
package: check-signing-key builder
	python3 scripts/artifacts.py check-shared $(OUT) $(VARIANT)
	$(BAKE) nvidia-extension
	$(MAKE) installer iso VARIANT=$(VARIANT)
	python3 scripts/artifacts.py variant $(OUT) $(VARIANT)

installer:
	mkdir -p $(VARIANT_OUT)
	python3 scripts/render-profile.py installer $(VARIANT) > $(VARIANT_OUT)/installer.yaml
	rm -f $(VARIANT_OUT)/installer-arm64.tar
	$(IMAGER_RUN) < $(VARIANT_OUT)/installer.yaml
	mv $(VARIANT_OUT)/installer-arm64.tar $(OUT)/installer-arm64-$(VARIANT).tar

iso:
	mkdir -p $(VARIANT_OUT)
	python3 scripts/render-profile.py iso $(VARIANT) > $(VARIANT_OUT)/iso.yaml
	rm -f $(VARIANT_OUT)/metal-arm64.iso
	$(IMAGER_RUN) < $(VARIANT_OUT)/iso.yaml
	mv $(VARIANT_OUT)/metal-arm64.iso $(OUT)/metal-arm64-$(VARIANT).iso

verify:
	python3 scripts/artifacts.py verify $(OUT)

push: verify
	python3 scripts/publish-installers.py $(OUT) $(IMAGE) $(TAG)

# Existing releases are never overwritten. CI compares OCI-DIGESTS on a rerun.
release: verify
	python3 scripts/artifacts.py notes $(OUT) > $(OUT)/release.md
	gh release create $(TAG) --verify-tag --title $(TAG) --notes-file $(OUT)/release.md \
		$(foreach v,$(VARIANTS),$(OUT)/installer-arm64-$(v).tar $(OUT)/metal-arm64-$(v).iso) \
		$(OUT)/SHA256SUMS $(OUT)/OCI-DIGESTS $(OUT)/VARIANTS.json

test:
	python3 -m unittest discover -s tests -v

cache-usage:
	docker buildx du --builder $(BUILDER)

print-variant:
	@printf '%s\n' '$(VARIANT)' '$(KERNEL_RELEASE)' '$(KBUILD_BUILD_VERSION)' '$(KERNEL_CONFIG)' '$(TALOS_SRC)' '$(IMAGER)' '$(TAG)'
