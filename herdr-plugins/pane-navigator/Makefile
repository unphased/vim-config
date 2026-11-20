.PHONY: all build test smoke

all: test

build:
	cargo build --quiet --release

test:
	cargo fmt -- --check
	cargo clippy --all-targets -- -D warnings
	cargo test
	$(MAKE) smoke

# E2E against a throwaway headless Herdr session (never the live one).
smoke: build
	./smoke-recency.sh
