SHELL := /usr/bin/env bash

SH_FILES := $(wildcard *.sh) $(wildcard tests/*.sh)

.PHONY: all check lint syntax smoke sums clean

all: check

check: lint syntax smoke

lint:
	@command -v shellcheck >/dev/null 2>&1 || { echo "[FAIL] 缺 shellcheck: apt install shellcheck"; exit 1; }
	@echo "[INFO] shellcheck ($(words $(SH_FILES)) 个文件)"
	@shellcheck -S warning $(SH_FILES) && echo "[ OK ] shellcheck 通过"

syntax:
	@set -e; for f in $(SH_FILES); do bash -n "$$f"; done
	@echo "[ OK ] bash -n 通过"

smoke:
	@bash tests/smoke.sh

sums:
	@sha256sum leclite.sh > SHA256SUMS
	@cat SHA256SUMS

clean:
	@rm -f SHA256SUMS.bak
