# Contributing

Thank you for your interest in contributing to this Rex backend!

## Development Setup

Install [mise](https://mise.jdx.dev/getting-started.html), then install the project tools:

```sh
mise trust
mise install
```

The Lua test dependencies still require LuaJIT and LuaRocks. On macOS:

```sh
brew install luajit luarocks
LUAJIT_PREFIX="$(brew --prefix luajit)"
ROCKS=(--lua-version=5.1 --lua-dir="$LUAJIT_PREFIX" --local)
luarocks "${ROCKS[@]}" install busted 2.3.0
luarocks "${ROCKS[@]}" install nlua 0.3.2
eval "$(luarocks "${ROCKS[@]}" path --bin)"
```

### Running Tests

Run all checks before submitting a PR:

```sh
mise run check
```

This runs:
- Formatting checks (Stylua, yamlfmt, prettier, tombi)
- Selene linting
- LuaLS type checking
- Busted test suite

Individual commands:

```sh
mise run test        # Run tests
mise run lint        # Run linters
mise run fmt-check   # Check formatting
mise run fmt         # Auto-format code
mise run typecheck   # Type checking
```

To run the tests against Neovim nightly:

```sh
MISE_NEOVIM_VERSION=nightly mise run test
```

Install the nightly build first with `mise install neovim@nightly`. CI tests both stable and nightly Neovim.

## Implementation Guidelines

### Backend Protocol

Your backend must implement the v3 protocol:

```lua
---@class SmartSplitsBackend
---@field name string
---@field protocol_version string  -- "3.0.0"
---@field detect fun():boolean
---@field move SmartSplitsBackendMove
---@field resize? SmartSplitsBackendResize
---@field health? fun()
```

### Type Annotations

Use LuaCATS type annotations extensively. All functions should have:
- Parameter types with `@param`
- Return types with `@return`
- Class definitions with `@class` and `@field`

Example:

```lua
---@param direction SmartSplitsDirection
---@param opts? SmartSplitsBackendMoveOpts
---@return boolean
function M.move(direction, opts)
  -- implementation
end
```

### Testing

All new functionality should include tests. The test suite uses:
- Busted test framework
- nlua (Neovim Lua interpreter)
- smart-splits core's `protocol_tests` for conformance

Neovim backend tests follow the pattern `tests/core/*_spec.lua`.

The Rex-side tests also run without a Rex server:

```sh
nvim --headless -u NONE -i NONE -l tests/rex/test.lua
nvim --headless -u NONE -i NONE -l tests/rex/process_integration.lua
```

The first suite stubs Rex APIs and covers forwarding, process matching, foreground groups,
remote/CLI delegation, malformed remote responses, failures, and host/focus safety. The second
creates a temporary PTY and starts a clean Neovim as a child of a blocking launcher, like Yazi
or broot. It checks actual process-group detection
through launch, suspend, resume, and exit, then stops its own test processes. It needs Unix
`ps` (macOS/BSD or Linux procps); it does not read or change your editor or Rex configuration.
Both suites run as part of `mise run test`.

With Rex installed, also run:

```sh
mise run test-rex-server
```

This optional suite starts an isolated Rex server with a temporary config and socket. It creates
its own terminal, checks shell/editor/exit detection through the real `client.action` RPC, and
stops its own session and server. The caller's `rex.exec` is disabled to catch accidental local
PID scans, including in a simulated forwarded action context. Your normal server is not changed.

To test across machines, set `REX_TEST_SERVER` to a test server endpoint that has the updated
module loaded with `setup()`. Set `REX_TEST_NVIM` to the Neovim executable on that server:

```sh
REX_TEST_SERVER=unix:///tmp/forwarded-rex.sock REX_TEST_NVIM=nvim mise run test-rex-server
```

The endpoint can be an SSH-forwarded Unix socket. The suite still creates and removes only its
own test session; it does not start or stop an externally supplied server. Run the PTY and live
server suites on both macOS and Linux when changing process detection or RPC routing.

## Code Style

- Use 2-space indentation
- Single quotes for strings
- Maximum line length: 120 characters
- Sort requires alphabetically

These are enforced by Stylua, yamlfmt, prettier, tombi, and actionlint.

## Pull Request Process

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Run `mise run check` to ensure all checks pass
5. Submit a pull request

## Questions?

Open an issue if you have questions about implementing a backend.
