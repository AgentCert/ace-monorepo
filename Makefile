.DEFAULT_GOAL := build
BUILD_ARGS ?=

.PHONY: all build push install test-scripts help
all: build

build:
	./scripts/build-and-push.sh $(BUILD_ARGS)

push:
	./scripts/build-and-push.sh --push $(BUILD_ARGS)

install:
	./scripts/setup.sh --deploy $(BUILD_ARGS)

test-scripts:
	python3 scripts/tests/test-script-modes.py
	bash scripts/tests/test-registry-tooling.sh
	bash scripts/tests/test-cloud-profile.sh

help:
	@echo 'make build   Build every image in deploy/images.txt locally (default)'
	@echo 'make push    Explicitly build and publish all images'
	@echo 'make install Explicitly configure and deploy ACE'
	@echo 'BUILD_ARGS="--allow-build-cache" enables build caching'
