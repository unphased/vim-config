.PHONY: all test smoke

all: test

test:
	cargo fmt -- --check
	cargo clippy --all-targets -- -D warnings
	cargo test

smoke:
	cargo build --quiet --release
	python3 smoke.py
