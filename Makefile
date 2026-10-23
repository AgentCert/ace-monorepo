# Root entry points. Only `push` publishes and only `install` deploys; every
# other target stays local. Paths are anchored to this Makefile, so
# `make -f /path/to/ace-monorepo/Makefile ...` works from any directory.
#
# Each script takes its own options, so each has its own variable:
#   BUILD_ARGS  scripts/build-and-push.sh options for build/push,
#               e.g. BUILD_ARGS="--only certifier --allow-build-cache"
#   SETUP_ARGS  scripts/setup.sh options for install,
#               e.g. SETUP_ARGS="--restart"
# --allow-build-cache, the one option both scripts share, is also forwarded
# from BUILD_ARGS to install.
ACE_ROOT := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
.DEFAULT_GOAL := build
BUILD_ARGS ?=
SETUP_ARGS ?=

.PHONY: all build push install test-scripts help
all: build

# --local makes build-and-push.sh itself reject a --push/--kind-load smuggled
# in through BUILD_ARGS.
build:
	"$(ACE_ROOT)/scripts/build-and-push.sh" --local $(BUILD_ARGS)

push:
	"$(ACE_ROOT)/scripts/build-and-push.sh" --push $(BUILD_ARGS)

install:
	$(if $(filter --push,$(SETUP_ARGS)),$(error SETUP_ARGS must not contain --push: run `make push` to publish))
	"$(ACE_ROOT)/scripts/setup.sh" --deploy $(filter --allow-build-cache,$(BUILD_ARGS)) $(SETUP_ARGS)

test-scripts:
	python3 "$(ACE_ROOT)/scripts/tests/test-script-modes.py"
	bash "$(ACE_ROOT)/scripts/tests/test-registry-tooling.sh"
	bash "$(ACE_ROOT)/scripts/tests/test-cloud-profile.sh"

help:
	@echo 'make build         Build every image in deploy/images.txt locally (default)'
	@echo 'make push          Explicitly build and publish all images'
	@echo 'make install       Explicitly configure and deploy ACE'
	@echo 'make test-scripts  Run the offline script test suites (no registry or cluster)'
	@echo ''
	@echo 'BUILD_ARGS="..."   Options for scripts/build-and-push.sh (build, push),'
	@echo '                   e.g. BUILD_ARGS="--only certifier --allow-build-cache"'
	@echo 'SETUP_ARGS="..."   Options for scripts/setup.sh (install), e.g. SETUP_ARGS="--restart"'
	@echo '                   --allow-build-cache in BUILD_ARGS also applies to install'
