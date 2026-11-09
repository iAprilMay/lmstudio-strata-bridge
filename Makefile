# Strata <-> LM Studio bridge — verification entry points.
#
# `make verify` is the one command to run before calling the tree healthy:
# type check + unit tests + read-only environment probe. Nothing here starts,
# stops, or modifies LM Studio, Strata, or any app file.
#
# Run from inside lmstudio-strata-bridge/ (this Makefile lives there).

PT_ENGINE := engines/pt
GGUF_ENGINE := engines/gguf

.PHONY: verify env shim-test llama-test
verify: env shim-test llama-test
	@echo "verify: all green"

shim-test:
	cd $(PT_ENGINE) && node test/sse.test.mjs

llama-test:
	cd $(GGUF_ENGINE) && node test/llama.test.mjs

env:
	bash tools/check_env.sh
