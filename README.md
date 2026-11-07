# smart-splits-backend-rex

[smart-splits.nvim](https://github.com/smart-splits-nvim/smart-splits.nvim) v3 backend for
[Rex](https://www.superlogical.com/rex/docs/installation), the multiplexer for all work.

With this backend, smart-splits moves between Neovim windows and Rex panes as if they were one
grid, and resizes Rex panes when the Neovim window is at an edge.

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  'smart-splits-nvim/smart-splits.nvim',
  version = '^3.0.0',
  dependencies = {
    {
      'rawnly/smart-splits-backend-rex',
      opts = {
        -- bin = 'rex',     -- name or path of the rex executable
        -- timeout = 2000,  -- ms to wait for a rex command
      },
    },
  },
  opts = {
    mux = {
      backend = 'smart-splits-backend-rex',
    },
  },
  keys = function()
    local ss = require('smart-splits')
    return {
      { '<C-h>', ss.move_cursor_left },
      { '<C-j>', ss.move_cursor_down },
      { '<C-k>', ss.move_cursor_up },
      { '<C-l>', ss.move_cursor_right },
      { '<A-h>', ss.resize_left },
      { '<A-j>', ss.resize_down },
      { '<A-k>', ss.resize_up },
      { '<A-l>', ss.resize_right },
    }
  end,
}
```

Run `:checkhealth smart-splits` to verify the backend can reach the Rex server.

### Options

| Option | Default | Description |
| --- | --- | --- |
| `enable` | `true` | Set to `false` to never detect the backend |
| `bin` | `'rex'` | Name or path of the `rex` executable |
| `timeout` | `2000` | Milliseconds to wait for a `rex` command |

## Rex key bindings

The optional Rex-side module in `rex/lua/smart-splits-rex/init.lua` registers actions for focusing and resizing panes. It does **not** register any key bindings; choose your own. The Neovim plugin installation above is still required.

### With Amber

After installing [Amber](https://github.com/rawnly/amber) on the Rex server, add this to your Rex config:

```lua
local amber = dofile(os.getenv('HOME') .. '/.local/share/rex/amber/amber.lua')

amber.setup({
  plugins = {
    {
      'rawnly/smart-splits-backend-rex',
      main = 'smart-splits-rex',
      ---@type SmartSplitsRexOptions
      opts = { resize_amount = 3 },
    },
  },
})
```

The repository must contain the Rex module on the Git ref being installed; if it has not been published yet, use a local checkout as described below. Amber does not install plugins during configuration loads or checks. Install explicitly, then reload:

```sh
rex config check
rex config reload
rex do amber_install plugin=rawnly/smart-splits-backend-rex
rex config reload
```

Amber records the installed commit in its lockfile. Use `rex do amber_update plugin=rawnly/smart-splits-backend-rex` to update it, or `rex do amber_restore plugin=rawnly/smart-splits-backend-rex` to restore the locked commit; reload after either action. Restore refuses dirty checkouts.

For development, add `path = '/absolute/path/to/smart-splits-backend-rex'` to the plugin spec. The path must be on the Rex server; Amber loads it but does not install, update, or lock it. Add this checkout to your Lua Language Server workspace library for the `SmartSplitsRexOptions` annotation to provide completion.

Without a manager, call `dofile('/absolute/path/to/smart-splits-backend-rex/rex/lua/smart-splits-rex/init.lua').setup({})` in Rex's config.

### Bind the actions

`smart_splits_focus` and `smart_splits_resize` take a `direction` (`left`, `right`, `up`, or `down`) and an optional `key`. When Neovim is foreground, the action forwards `key` to it; supply the key matching your binding. Without a key, the action reports an error rather than swallowing a Neovim input. In other panes, focus moves to the neighboring pane and resize uses the optional `amount`, the `resize_amount` setup option, or 3, in that order. The resize and key-forwarding actions use the Rex client, so an app client must be available.

For example, to opt into Ctrl+h/j/k/l navigation and Alt+h/j/k/l resizing, add this **separately** to your Rex config:

```lua
for key, direction in pairs({ h = 'left', j = 'down', k = 'up', l = 'right' }) do
  rex.bind('ctrl+' .. key, 'smart_splits_focus', { direction = direction, key = 'ctrl+' .. key })
  rex.bind('alt+' .. key, 'smart_splits_resize', { direction = direction, key = 'alt+' .. key })
end
```

These bindings intercept the selected keys in all panes; only choose keys you want to reserve. Reload the config after adding them.

### Foreground detection (including Yazi and broot)

Rex bindings run before the terminal receives a key. The module must distinguish an editor
from an ordinary pane before deciding whether to forward the key or operate on the Rex layout.

Rex's `process.foreground` can describe the **process-group leader**, not the editor currently
using the terminal. For example, when Yazi or broot launches Neovim, the leader may still be
`yazi` or `broot`. Checking only its name loses both navigation and resize keys.

The module first recognizes Vim-family executables using the process name and executable paths,
including Nix's `.nvim-wrapped`. Otherwise, it uses one `ps` snapshot to find live Vim processes
in that terminal's **foreground process group**. It does not search arbitrary descendants or
other terminals, and ignores stopped, traced, zombie, and dead processes. Detection is repeated
on each key, so exiting, suspending, or resuming the editor needs no persistent pane marker.
Actions also check that the source pane is still focused after detection.

For remote Rex sessions, API calls follow `ctx.server`, but `rex.exec` still runs on the
machine executing the Lua action. Comparing RPC host IDs alone cannot make a local `ps` safe.
The module delegates detection to the terminal server's read-only `smart_splits_is_vim` action
through `client.action`, without forwarding the original `server` field. That action runs the
same detector in a server-local context and returns `{ is_vim = true/false }`. CLI scripts
also delegate, even when their context has no `server` field.

Call `setup()` on **both the home server and each terminal server**. If the destination has an
older module without the detector action, detection fails with an upgrade/setup message; it
never falls back to scanning that server's PIDs on the caller's machine.

The process-group fallback requires:

- A Unix Rex server with `rex.exec`, `server.status`, `session.describe_block`, and `client.action` support.
- `ps` on the server's PATH, supporting `pid`, `pgid`, `tpgid`, `stat`, and `comm` columns
  (macOS/BSD `ps` or Linux procps). Each scan has a one-second timeout.
- The terminal block and the executing server to report the same `host_id`. A remote PID must
  never be looked up on the wrong machine. Load the module on the terminal's owning server.

An unknown host, failed process query, failed scan, or focus change reports an error instead of
silently treating the pane as a shell and moving or resizing the wrong pane. Directly recognized
editors do not need `ps`. SSH sessions or nested multiplexers that hide the editor in another
process namespace are not automatically detected.

Custom actions can reuse the same detector. The terminal server must register it with `setup()`:

```lua
local smart_splits = dofile('/absolute/path/to/smart-splits-backend-rex/rex/lua/smart-splits-rex/init.lua')
smart_splits.setup()
-- Inside an action's run(ctx, args):
local is_vim, err = smart_splits.is_vim(ctx)
if is_vim == nil then
  error(err, 0)
end
```

`is_vim(ctx)` returns `true`, `false`, or `nil, error`. Pass the original action context so the
server and session information are preserved. In a CLI script, pass `rex.session_id` and
`rex.block_id` as the corresponding context fields. The destination must have this module
loaded; calling `setup()` only in the CLI script does not install it on the server.
Prefer the supplied actions for key bindings; they also handle key forwarding and focus checks.

### Resizing

`alt+h/j/k/l` need no Rex binding if you only resize from Neovim: unbound keys pass through to
the editor, and smart-splits calls Rex at the edge. To resize from ordinary panes too, use the
`smart_splits_resize` bindings above. Those bindings reserve the keys in all panes.

On macOS, Option must be sent as Alt, otherwise Option+h types `˙` and `<A-h>` never fires in
Neovim. Check with `:lua print(vim.fn.getcharstr())` and press Option+h; it should print `<M-h>`.

## How it works

The backend is a thin wrapper around the [`rex` CLI](https://www.superlogical.com/rex/docs/automate/cli).
Every terminal Rex opens has `rex` on its `PATH` and sets `REX_SESSION` and `REX_BLOCK`, so the CLI
already acts on the pane Neovim is running in. Nothing needs to be defined in your Rex `init.lua`
besides the key bindings above.

| smart-splits | Rex |
| --- | --- |
| `detect()` | `REX_SESSION`/`REX_BLOCK` are set and `rex` is executable |
| `move(direction)` | `rex do -e <script>`, which calls `rex.session.focus_direction` |
| `move(direction, { at_edge = 'wrap' })` | the same script with `wrap = true` |
| `move(direction, { at_edge = 'split' })` | `rex split --split=<right\|left\|above\|below>` when there is no neighbor |
| `resize(direction, { amount })` | `rex do pane.resize direction=<direction> amount=<amount>` |

Notes:

- `rex focus` exits 0 even at the edge of the layout, so moving runs a small Lua script through
  `rex do` instead. It verifies the source pane and compares the actual focused block before and
  after navigation. Revision changes alone (such as unzooming or renaming) do not count as moving.
  A confirmed edge returns `false`; API failures and malformed output never trigger `at_edge = 'split'`.
- Resizing runs the app's `pane.resize` action, so the Rex app must be running with Remote Control
  turned on in its settings.

## Development

See [CONTRIBUTING.md](CONTRIBUTING.md). Unit tests stub Rex APIs and the CLI; the process-group
regression test uses a real temporary PTY with a clean Neovim. Neither needs Rex installed.
Run `mise run test-rex` for both Rex-side suites, or `luajit tests/rex/test.lua` for just the unit tests.
With Rex installed, `mise run test-rex-server` also checks actual server-side detection in an
isolated Rex server, without changing your normal Rex configuration or sessions.

## License

MIT
