# AIrtg collector - Docker image builds.
#
#   make              checks, then the image for this machine, then its tests
#                     (same as `make all`)
#   make check        static checks: scripts, compose.yaml, versions
#   make build        the image for this machine, loaded as $(IMAGE):$(VERSION)
#   make test         build, then run the image's tests (scripts/test.sh)
#   make package      one image archive per platform and SHA256SUMS in dist/
#   make push         build every platform and push $(IMAGE):$(VERSION) and :latest
#   make clean        remove dist/
#
# A new version in VERSION pushed to main makes CI create the tag
# v<version>, its GitHub release and push the image.

IMAGE     ?= ghcr.io/airtg-io/airtg-collector
NAME      := airtg-collector
DIST      := dist
VERSION   ?= $(shell cat VERSION 2>/dev/null || echo dev)
REVISION  ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)
PLATFORMS := linux/amd64 linux/arm64
DOCKER    ?= docker

comma := ,
empty :=
space := $(empty) $(empty)
BUILD = $(DOCKER) buildx build \
	--build-arg VERSION=$(VERSION) --build-arg REVISION=$(REVISION)

.DEFAULT_GOAL := all
.PHONY: all check build test package push clean help

all: check test ## Checks, then build and test the image for this machine

check: ## Static checks: scripts, compose.yaml, versions
	@set -e; \
	for f in scripts/*.sh; do sh -n $$f; done; \
	if command -v shellcheck >/dev/null; then shellcheck scripts/*.sh; else echo "shellcheck not installed: skipped"; fi; \
	grep -Eq '^[0-9]+\.[0-9]+(\.[0-9]+)?$$' VERSION || { echo "VERSION: expected MAJOR.MINOR or MAJOR.MINOR.PATCH"; exit 1; }; \
	grep -q "image: $(IMAGE):\$${AIRTG_COLLECTOR_VERSION:-$(VERSION)}\$$" compose.yaml || \
		{ echo "compose.yaml: the default image must be $(IMAGE):$(VERSION)"; exit 1; }; \
	poller=$$(sed -n 's/^ARG SNMP_POLLER_VERSION=//p' Dockerfile); \
	grep -q "^| snmp-poller | $$poller |" README.md || \
		{ echo "README.md: the components table must list snmp-poller $$poller"; exit 1; }; \
	if $(DOCKER) compose version >/dev/null 2>&1; then $(DOCKER) compose -f compose.yaml config -q; fi
	@echo "checks passed"

build: ## The image for this machine, loaded as <image>:<VERSION>
	$(BUILD) --load -t $(IMAGE):$(VERSION) .

test: build ## Build, then run the image's tests
	scripts/test.sh $(IMAGE):$(VERSION)

# docker save of each platform's image, tagged $(IMAGE):$(VERSION):
# `docker load` restores it ready for compose.yaml, without a registry.
package: ## One image archive per platform and SHA256SUMS in dist/
	@set -e; mkdir -p $(DIST); \
	for p in $(PLATFORMS); do \
		name=$(NAME)-$(VERSION)-$${p%/*}-$${p#*/}; \
		$(BUILD) --platform $$p --load -t $(IMAGE):$(VERSION) .; \
		$(DOCKER) save $(IMAGE):$(VERSION) | gzip -9 > $(DIST)/$$name.tar.gz; \
		echo "packaged $(DIST)/$$name.tar.gz"; \
	done; \
	cd $(DIST) && sha256sum *.tar.gz > SHA256SUMS
	@echo "wrote $(DIST)/SHA256SUMS"
	@# The last platform's image is loaded now: reload this machine's.
	$(BUILD) --load -t $(IMAGE):$(VERSION) .

# Needs a builder that can push multi-platform images (docker-container
# driver: docker buildx create --use) and docker login to the registry.
push: ## Build every platform and push <image>:<VERSION> and :latest
	$(BUILD) --platform $(subst $(space),$(comma),$(PLATFORMS)) --push \
		-t $(IMAGE):$(VERSION) -t $(IMAGE):latest .

clean: ## Remove dist/
	rm -rf $(DIST)

help: ## List targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-10s %s\n", $$1, $$2}'
