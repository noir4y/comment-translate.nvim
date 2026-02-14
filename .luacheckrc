std = "lua51"

globals = {
  "vim",
}

files["tests/**/*.lua"] = {
  globals = {
    "vim",
    "describe",
    "it",
    "before_each",
    "after_each",
    "setup",
    "teardown",
    "pending",
    "assert",
  },
}
