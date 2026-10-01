# Talos for NVIDIA DGX Spark: kernel, NVIDIA extension, installer image, and ISO.
#
#   make signing-key   create the module signing key (once; keep it)
#   make               build _out/installer-arm64.tar, _out/metal-arm64.iso, _out/SHA256SUMS
#   make push          push the installer image to $(IMAGE):$(TAG)

TALOS_VERSION     := v1.14.1
TALOS_COMMIT      := 2f86b9d2a29b413deddd7122a8420b8913813615
TALOS_REPOSITORY  := https://github.com/siderolabs/talos.git
KERNEL_RELEASE    := 6.17.13-talos-dgx1022
SOURCE_DATE_EPOCH := 1789481248

TAG         ?= $(TALOS_VERSION)-$(lastword $(subst -, ,$(KERNEL_RELEASE)))
IMAGE       ?= ghcr.io/kindlingai/talos-dgx-kernel/installer
SIGNING_KEY ?= $(CURDIR)/keys/module-signing.pem
JOBS        ?=
PROGRESS    ?= auto

BUILDER        ?= talos-dgx-kernel
BUILDKIT_IMAGE := moby/buildkit:v0.33.1@sha256:cec9f139f45e93c5c69c60f8b07cfad9f43f4ef6b6a6cd917527fea5ff2e3dea

OUT       := $(CURDIR)/_out
TALOS_SRC := $(CURDIR)/.work/talos
IMAGER    := talos-dgx-kernel/imager:$(TALOS_VERSION)

export TALOS_VERSION TALOS_COMMIT KERNEL_RELEASE SOURCE_DATE_EPOCH SIGNING_KEY JOBS OUT TALOS_SRC

BAKE   := docker buildx bake --builder $(BUILDER) --progress $(PROGRESS)
IMAGER_RUN := docker run --rm -i --env SOURCE_DATE_EPOCH \
	--volume $(OUT)/oci:/oci:ro --volume $(OUT):/out $(IMAGER) - --output /out

.PHONY: all builder signing-key kernel talos-source talos installer iso push clean

all: installer iso
	cd $(OUT) && shasum -a 256 installer-arm64.tar metal-arm64.iso > SHA256SUMS
	cat $(OUT)/SHA256SUMS

builder:
	docker buildx inspect $(BUILDER) >/dev/null 2>&1 || \
		docker buildx create --name $(BUILDER) --driver docker-container --driver-opt image=$(BUILDKIT_IMAGE)

# Every build signs modules with this key and embeds its certificate in the
# kernel, so the same key reproduces the same artifacts.
signing-key: $(SIGNING_KEY)

$(SIGNING_KEY):
	mkdir -p $(@D)
	umask 077 && openssl req -new -nodes -utf8 -sha512 -days 36500 -batch -x509 \
		-config kernel/x509.genkey -outform PEM -out $@ -keyout $@

kernel: builder
	@test -f "$(SIGNING_KEY)" || { echo "SIGNING_KEY=$(SIGNING_KEY): run 'make signing-key' or point SIGNING_KEY at the existing key" >&2; exit 1; }
	$(BAKE) kernel

talos-source: $(TALOS_SRC)/.git/talos-dgx-kernel-$(TALOS_COMMIT)

$(TALOS_SRC)/.git/talos-dgx-kernel-$(TALOS_COMMIT): talos/source.patch
	rm -rf $(TALOS_SRC)
	git init -q $(TALOS_SRC)
	git -C $(TALOS_SRC) fetch -q --depth=1 $(TALOS_REPOSITORY) $(TALOS_COMMIT)
	git -C $(TALOS_SRC) -c advice.detachedHead=false checkout -q FETCH_HEAD
	git -C $(TALOS_SRC) apply $(CURDIR)/talos/source.patch
	touch $@

talos: kernel talos-source
	$(BAKE) talos

installer: talos
	rm -f $(OUT)/installer-arm64.tar
	$(IMAGER_RUN) < talos/installer.yaml

iso: talos
	rm -f $(OUT)/metal-arm64.iso
	$(IMAGER_RUN) < talos/iso.yaml

push:
	crane push $(OUT)/installer-arm64.tar $(IMAGE):$(TAG) | tee $(OUT)/installer.ref

clean:
	rm -rf $(OUT) $(CURDIR)/.work
