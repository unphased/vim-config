.PHONY: all build test

all: test

build:
	cargo build --quiet --release

test:
	cargo fmt -- --check
	cargo clippy --all-targets -- -D warnings
	cargo test
