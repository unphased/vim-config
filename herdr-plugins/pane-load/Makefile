.PHONY: all test smoke

all: test

test:
	cargo fmt -- --check
	cargo clippy --all-targets -- -D warnings
	cargo test
	python3 -m unittest discover -v -p 'test_recording_*.py'

smoke:
	cargo build --quiet --release
	python3 smoke.py
