REGISTRY := local

# This repository ships one enclave app, so the build arg defaults to it and
# `make` needs no ENCLAVE_APP=.
ENCLAVE_APP ?= source-verification

# Resources given to the enclave by `make run` / `make run-debug`. This image
# carries a ~200 MB compiler and run.sh mounts a 6G tmpfs for verification
# scratch, which only bounds anything if the enclave has memory above it — so
# the default is 8 GiB, not the 512 MiB that cannot boot this image. The Nitro
# allocator must be configured to at least this (see
# /etc/nitro_enclaves/allocator.yaml); note it reserves huge pages, so it may
# need a fresh host to find contiguous memory.
CPU_COUNT := 2
MEMORY := 8192M

# The measured verifier: the Move compiler baked into the enclave image.
#
# It is the official sui release, pinned by version AND by the digest of the
# extracted binary. The PCRs are only meaningful if someone else can arrive at
# the same image; a released artifact is content-addressed, so reproducing the
# image is a download and a digest check -- no build step. The digest is what
# actually pins the image; the version records which release it came from.
#
# A mismatch is reported rather than ignored. If you hit one, the honest reading
# is that you fetched a different binary from the published one -- not that the
# check is wrong. Use the pinned release to reproduce the PCRs exactly.
VERIFIER := verifier/sui
VERIFIER_VERSION := testnet-v1.77.2
VERIFIER_SHA256 := c902aa06bf0c1e157e9f86c65efec504cd0fbc5c74dd472e3fd6dcab86fe3fa3

# The SHA-256 tool differs by host: sha256sum on the Linux enclave host, shasum
# on macOS for local reproduction. Use whichever exists.
SHA256 := $(shell command -v sha256sum >/dev/null 2>&1 && echo sha256sum || echo shasum -a 256)

.DEFAULT_GOAL :=
.PHONY: default
default: out/nitro.eif

out:
	mkdir -p out

# The verifier is part of the image, so the EIF depends on it: changing it changes
# the PCRs.
out/nitro.eif: $(shell git ls-files src) $(VERIFIER) | out
	docker build \
		--pull \
		--tag $(REGISTRY)/enclaveos \
		--progress=plain \
		--platform linux/amd64 \
		--provenance=false \
		--output type=local,rewrite-timestamp=true,dest=out\
		-f Containerfile \
		--build-arg ENCLAVE_APP=$(ENCLAVE_APP) \
		.

.PHONY: run
run: out/nitro.eif
	sudo nitro-cli \
		run-enclave \
		--cpu-count $(CPU_COUNT) \
		--memory $(MEMORY) \
		--eif-path out/nitro.eif

.PHONY: run-debug
run-debug: out/nitro.eif
	sudo nitro-cli \
		run-enclave \
		--cpu-count $(CPU_COUNT) \
		--memory $(MEMORY) \
		--eif-path out/nitro.eif \
		--debug-mode \
		--attach-console

.PHONY: update
update:
	./update.sh


# Build the Move compiler that gets baked into the enclave image.
#
# GIT_REVISION is passed because `bin_version::bin_version!()` runs `git rev-parse`
# at compile time, and git refuses the bind-mounted checkout as dubiously owned
# when cargo runs as root -- the build then fails with "unable to query git
# revision". safe.directory covers the same ground for any other git call.
.PHONY: verifier
verifier: $(VERIFIER)

$(VERIFIER):
	mkdir -p $(dir $(VERIFIER))
	curl -fsSL "https://github.com/MystenLabs/sui/releases/download/$(VERIFIER_VERSION)/sui-$(VERIFIER_VERSION)-ubuntu-x86_64.tgz" \
		| tar -xz -C $(dir $(VERIFIER)) ./sui
	@actual=$$($(SHA256) $(VERIFIER) | cut -d" " -f1); \
	if [ "$$actual" != "$(VERIFIER_SHA256)" ]; then \
		echo "verifier digest mismatch:"; \
		echo "  expected $(VERIFIER_SHA256)"; \
		echo "  actual   $$actual"; \
		echo "The PCRs this produces will not match the published ones."; \
		exit 1; \
	fi; \
	echo "verifier digest matches $(VERIFIER_SHA256)"
