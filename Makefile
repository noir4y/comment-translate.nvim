.PHONY: deps test-real-parsers test test-file clean fmt fmt-check lint health docs

# Test runner
PLENARY_DIR ?= /tmp/plenary.nvim
TEST_DEPS_DIR ?= /tmp/comment-translate-test-deps
NVIM ?= nvim

# Reproducible test-only parsers and queries (no personal runtime changes).
deps: $(PLENARY_DIR)
	COMMENT_TRANSLATE_TEST_DEPS_DIR="$(abspath $(TEST_DEPS_DIR))" \
		XDG_DATA_HOME="$(abspath $(TEST_DEPS_DIR))/data" XDG_CACHE_HOME="$(abspath $(TEST_DEPS_DIR))/cache" \
		XDG_CONFIG_HOME="$(abspath $(TEST_DEPS_DIR))/config" XDG_STATE_HOME="$(abspath $(TEST_DEPS_DIR))/state" \
		$(NVIM) --headless --noplugin -i NONE -u NONE -l tests/setup_parsers.lua

# FILE is optional; without it, run the entire suite in strict mode.
test-real-parsers: deps
	@$(NVIM) --version
	COMMENT_TRANSLATE_TEST_RTP="$(abspath $(TEST_DEPS_DIR))/runtime" \
		COMMENT_TRANSLATE_TEST_REQUIRE_PARSERS=1 \
		XDG_STATE_HOME="$(abspath $(TEST_DEPS_DIR))/state" \
		$(MAKE) $(if $(FILE),test-file,test) PLENARY_DIR="$(PLENARY_DIR)"

# Clone plenary if not exists
$(PLENARY_DIR):
	git clone --depth 1 https://github.com/nvim-lua/plenary.nvim $(PLENARY_DIR)

# Run all tests
test: $(PLENARY_DIR)
	@echo "Running tests..."
	PLENARY_DIR="$(PLENARY_DIR)" $(NVIM) --headless --noplugin -i NONE -u tests/minimal_init.lua \
		-c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua', sequential = true}"

# Run a specific test file
test-file: $(PLENARY_DIR)
	@echo "Running $(FILE)..."
	PLENARY_DIR="$(PLENARY_DIR)" COMMENT_TRANSLATE_TEST_FILE="$(FILE)" \
		$(NVIM) --headless --noplugin -i NONE -u tests/minimal_init.lua \
		-c "lua require('plenary.busted').run(vim.env.COMMENT_TRANSLATE_TEST_FILE)"

# Clean temporary files
clean:
	rm -rf $(PLENARY_DIR)

# Generate documentation tags
docs:
	@echo "Generating help tags..."
	nvim --headless -i NONE -c "helptags doc/" -c "qa"

# Health check
health: $(PLENARY_DIR)
	nvim --headless -i NONE -u tests/minimal_init.lua \
		-c "runtime plugin/comment-translate.lua" \
		-c "enew" \
		-c "set filetype=lua" \
		-c "CommentTranslateHealth" \
		-c "lua print(table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n'))" \
		-c "qa"

# Format Lua files
fmt:
	stylua lua plugin tests

# Check Lua formatting
fmt-check:
	stylua --check lua plugin tests

# Lint Lua files
lint:
	luacheck lua plugin tests
