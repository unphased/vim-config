.PHONY: all test test-pi test-claude

PI_PACKAGE_ROOT ?= /Users/slu/.n/lib/node_modules/@earendil-works/pi-coding-agent

all: test

test: test-pi test-claude

test-pi:
	cd pi && PI_PACKAGE_ROOT="$(PI_PACKAGE_ROOT)" node test-render.mjs

test-claude:
	python3 claude/test-hook.py
