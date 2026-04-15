.PHONY: test test-file clean fmt fmt-check lint health

# Test runner
PLENARY_DIR ?= /tmp/plenary.nvim

# Clone plenary if not exists
$(PLENARY_DIR):
	git clone --depth 1 https://github.com/nvim-lua/plenary.nvim $(PLENARY_DIR)

# Run all tests
test: $(PLENARY_DIR)
	@echo "Running tests..."
	nvim --headless --noplugin -u tests/minimal_init.lua \
		-c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua', sequential = true}"

# Run a specific test file
test-file: $(PLENARY_DIR)
	@echo "Running $(FILE)..."
	nvim --headless --noplugin -u tests/minimal_init.lua \
		-c "PlenaryBustedFile $(FILE)"

# Clean temporary files
clean:
	rm -rf $(PLENARY_DIR)

# Generate documentation tags
docs:
	@echo "Generating help tags..."
	nvim --headless -c "helptags doc/" -c "qa"

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
