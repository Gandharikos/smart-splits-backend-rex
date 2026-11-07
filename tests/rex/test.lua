-- Run with nvim --headless -u NONE -l tests/rex/test.lua (or luajit) from the repository root.
local plugin = dofile('rex/lua/smart-splits-rex/init.lua')
local ctx = { session_id = 'session:1', block_id = 'block:1' }
local state
local count = 0

local function reset()
  ctx.server = nil
  state = {
    actions = {},
    bindings = {},
    calls = {},
    foreground = { pid = 100, name = 'yazi' },
    output = '100 100 100 S+ /usr/bin/yazi\n',
    host = 'host:1',
    server_host = 'host:1',
    focused = ctx.block_id,
    scans = 0,
    process_queries = 0,
    remote_calls = 0,
    remote_is_vim = false,
  }
  rex = {
    bind = function(key)
      state.bindings[#state.bindings + 1] = key
    end,
    action = function(action)
      state.actions[action.name] = action
    end,
    block = {
      call = function(creator, method, args)
        assert(creator == 'com.superlogical.terminal' and method == 'process')
        assert(args.block_id == ctx.block_id)
        state.process_queries = state.process_queries + 1
        if state.process_error then
          return nil, state.process_error
        end
        return { foreground = state.foreground }
      end,
    },
    call = function(method, args)
      if method == 'client.action' then
        state.remote_calls = state.remote_calls + 1
        assert(args.action == 'smart_splits_is_vim')
        assert(args.session_id == ctx.session_id and args.block_id == ctx.block_id)
        assert(args.server == nil and args.servers == nil, 'must execute on the destination, not route back')
        if state.remote_error then
          return nil, state.remote_error
        end
        return state.remote_response or { result = { is_vim = state.remote_is_vim }, client_actions = {} }
      end
      assert(method == 'server.status')
      return { host_id = state.server_host }
    end,
    exec = function(argv, opts)
      state.scans = state.scans + 1
      assert(table.concat(argv, ' ') == 'ps -ax -o pid=,pgid=,tpgid=,stat=,comm=')
      assert(opts.timeout == 1)
      if state.exec_error then
        return nil, state.exec_error
      end
      return { ok = not state.scan_failed, stdout = state.output, stderr = state.stderr or '' }
    end,
    session = {
      describe_block = function(args)
        assert(args.block_id == ctx.block_id)
        return { block = { host_id = state.host } }
      end,
      view = function()
        if state.view_error then
          return nil, state.view_error
        end
        return {
          active_window_id = 'window:1',
          windows = { { window_id = 'window:1', focused_block_id = state.focused } },
        }
      end,
      focus_direction = function(args)
        state.calls[#state.calls + 1] = { name = 'focus', args = args }
        return nil, state.focus_error
      end,
    },
    client = {
      queue = function(name, args)
        state.calls[#state.calls + 1] = { name = name, args = args }
      end,
    },
  }
  plugin.setup()
end

local function test(name, fn)
  reset()
  local ok, err = pcall(fn)
  assert(ok, name .. ': ' .. tostring(err))
  count = count + 1
end

local function run(action, args, context)
  state.actions['smart_splits_' .. action].run(context or ctx, args)
end

local function rejects(action, message, context)
  local ok, err = pcall(run, action, { direction = 'left', key = 'ctrl+h' }, context)
  assert(not ok and tostring(err):find(message, 1, true), tostring(err))
  assert(#state.calls == 0)
end

local function forwards()
  run('focus', { direction = 'left', key = 'ctrl+h' })
  run('resize', { direction = 'down', key = 'alt+j' })
  assert(#state.calls == 2)
  assert(state.calls[1].name == 'pane.send_key' and state.calls[1].args.key == 'ctrl+h')
  assert(state.calls[2].name == 'pane.send_key' and state.calls[2].args.key == 'alt+j')
end

test('registers repeatable actions without binding keys', function()
  assert(#state.bindings == 0)
  assert(state.actions.smart_splits_focus.repeats and state.actions.smart_splits_resize.repeats)
end)

for _, name in ipairs({
  'vi',
  'vim',
  'nvim',
  'view',
  'gvim',
  'gview',
  'vimdiff',
  'nvimdiff',
  'gvimdiff',
  'lvim',
  'vimx',
}) do
  test('direct foreground ' .. name, function()
    state.foreground = { name = name }
    forwards()
    assert(state.scans == 0)
  end)
end

for _, field in ipairs({ 'name', 'argv0', 'path', 'invoked_path' }) do
  test('recognizes executable via ' .. field, function()
    state.foreground = { name = 'wrapper', [field] = '/nix/store/editor/bin/.nvim-wrapped' }
    forwards()
    assert(state.scans == 0)
  end)
end

for _, launcher in ipairs({ 'yazi', 'br', 'broot', 'fish', 'sh' }) do
  test(launcher .. ' launches Neovim in the same foreground group', function()
    state.foreground.name = launcher
    state.output = '100 100 100 S+ ' .. launcher .. '\n101 100 100 S+ /nix/store/editor/bin/nvim\n'
    forwards()
    assert(state.scans == 2)
  end)
end

test('foreground PID need not be the process group leader', function()
  state.foreground.pid = 105
  state.output = '105 100 100 S+ yazi\n106 100 100 S+ nvim\n'
  forwards()
end)

test('macOS command paths can contain spaces and Nix wrappers', function()
  state.output = '100 100 100 S+ yazi\n101 100 100 S+ /path with spaces/.nvim-wrapped\n'
  forwards()
end)

test('does not mistake nvim-prefixed programs for Neovim', function()
  state.foreground = { pid = 100, name = 'nvim-helper' }
  state.output = '100 100 100 S+ nvim-helper\n'
  assert(plugin.is_vim(ctx) == false)
end)

test('ignores other process groups, detached servers, and other terminals', function()
  state.output = state.output .. '101 101 100 S nvim\n102 102 102 S+ nvim\n103 103 -1 Ss nvim\n104 100 -1 S nvim\n'
  assert(plugin.is_vim(ctx) == false)
end)

for _, status in ipairs({ 'T', 'T+', 't', 'Z', 'Z+', 'X' }) do
  test('ignores stopped or dead process state ' .. status, function()
    state.output = state.output .. '101 100 100 ' .. status .. ' nvim\n'
    assert(plugin.is_vim(ctx) == false)
  end)
end

test('handles editor start, suspend, resume and exit without stale state', function()
  local launcher = state.output
  assert(plugin.is_vim(ctx) == false)
  state.output = launcher .. '101 100 100 S+ nvim\n'
  assert(plugin.is_vim(ctx) == true)
  state.output = launcher .. '101 100 100 T nvim\n'
  assert(plugin.is_vim(ctx) == false)
  state.output = launcher .. '101 100 100 S+ nvim\n'
  assert(plugin.is_vim(ctx) == true)
  state.output = launcher
  assert(plugin.is_vim(ctx) == false)
end)

test('ordinary panes focus without wrapping and resize', function()
  run('focus', { direction = 'left' })
  assert(state.calls[1].name == 'focus' and state.calls[1].args.direction == 'left')
  assert(state.calls[1].args.wrap == false)
  run('resize', { direction = 'down' })
  assert(state.calls[2].name == 'pane.resize' and state.calls[2].args.amount == 3)
end)

test('resize amount precedence', function()
  plugin.setup({ resize_amount = 7 })
  run('resize', { direction = 'right' })
  assert(state.calls[1].args.amount == 7)
  run('resize', { direction = 'up', amount = 9 })
  assert(state.calls[2].args.direction == 'up' and state.calls[2].args.amount == 9)
end)

test('missing key is an error when forwarding to Vim', function()
  state.foreground = { name = 'nvim' }
  for _, action in ipairs({ 'focus', 'resize' }) do
    local ok, err = pcall(run, action, { direction = 'left' })
    assert(not ok and tostring(err):find('key is required', 1, true))
    ok, err = pcall(run, action, { direction = 'left', key = '' })
    assert(not ok and tostring(err):find('key is required', 1, true))
  end
  assert(#state.calls == 0)
end)

test('no foreground process is not an editor', function()
  state.foreground = nil
  assert(plugin.is_vim(ctx) == false and state.scans == 0)
end)

test('propagates process query errors', function()
  state.process_error = 'process unavailable'
  rejects('focus', 'process unavailable')
  rejects('resize', 'process unavailable')
end)

test('rejects missing block context', function()
  rejects('focus', 'no terminal block', {})
end)

test('rejects missing PID for group scan', function()
  state.foreground.pid = nil
  rejects('focus', 'no valid PID')
end)

test('never scans local PIDs for a foreign host', function()
  state.host = 'host:remote'
  rejects('focus', 'another host')
  assert(state.scans == 0)
end)

test('requires a verified host identity before scanning', function()
  state.server_host = nil
  rejects('resize', 'cannot verify')
  assert(state.scans == 0)
end)

test('direct editor detection needs no local process scan even for remote blocks', function()
  state.foreground = { name = 'nvim' }
  state.host = 'host:remote'
  forwards()
  assert(state.scans == 0)
end)

test('reports missing ps executable', function()
  state.exec_error = 'ps not found'
  rejects('focus', 'ps not found')
end)

test('reports ps errors and timeouts instead of moving the pane', function()
  state.scan_failed = true
  rejects('focus', 'foreground process scan failed')
  state.stderr = 'ps: unsupported column'
  rejects('resize', 'unsupported column')
end)

for _, output in ipairs({ '', 'garbage', '101 100 100 S+ nvim\n', '100 100 -1 S yazi\n' }) do
  test('rejects missing or stale foreground snapshot: ' .. output, function()
    state.output = output
    rejects('focus', 'foreground process changed')
  end)
end

test('does not act on another pane after focus changed during detection', function()
  state.focused = 'block:other'
  rejects('focus', 'focused pane changed')
  rejects('resize', 'focused pane changed')
  state.foreground = { name = 'nvim' }
  rejects('focus', 'focused pane changed')
end)

test('propagates view errors', function()
  state.view_error = 'session unavailable'
  rejects('focus', 'session unavailable')
end)

test('propagates focus errors', function()
  state.focus_error = 'cannot focus'
  local ok, err = pcall(run, 'focus', { direction = 'left' })
  assert(not ok and tostring(err):find('cannot focus', 1, true))
end)

for _, is_vim in ipairs({ true, false }) do
  test('server detector returns an explicit boolean: ' .. tostring(is_vim), function()
    if is_vim then
      state.output = state.output .. '101 100 100 S+ nvim\n'
    end
    local result = state.actions.smart_splits_is_vim.run(ctx)
    assert(type(result) == 'table' and result.is_vim == is_vim)
    assert(state.scans == 1 and state.remote_calls == 0 and #state.calls == 0)
  end)

  test('remote detection never uses local process data: ' .. tostring(is_vim), function()
    ctx.server = 'ymir'
    state.remote_is_vim = is_vim
    -- Both RPC host IDs can say ymir while rex.exec would still run on the Mac.
    state.host, state.server_host = 'host:remote', 'host:remote'
    state.output = ''
    assert(plugin.is_vim(ctx) == is_vim)
    assert(state.remote_calls == 1 and state.scans == 0 and state.process_queries == 0)
  end)

  test('CLI detection executes on its target server: ' .. tostring(is_vim), function()
    rex.args = {}
    rex.session_id = ctx.session_id
    state.remote_is_vim = is_vim
    assert(plugin.is_vim({ block_id = ctx.block_id }) == is_vim)
    assert(state.remote_calls == 1 and state.scans == 0 and state.process_queries == 0)
  end)
end

test('remote editor forwards focus and resize keys', function()
  ctx.server = 'ymir'
  state.remote_is_vim = true
  forwards()
  assert(state.remote_calls == 2 and state.scans == 0)
end)

test('remote shell focuses and resizes without forwarding keys', function()
  ctx.server = 'ymir'
  run('focus', { direction = 'left' })
  run('resize', { direction = 'down' })
  assert(state.calls[1].name == 'focus' and state.calls[2].name == 'pane.resize')
  assert(state.remote_calls == 2 and state.scans == 0)
end)

test('empty server name is a local context', function()
  ctx.server = ''
  assert(plugin.is_vim(ctx) == false)
  assert(state.scans == 1 and state.remote_calls == 0)
end)

test('remote context requires a session', function()
  rejects('focus', 'no session', { block_id = ctx.block_id, server = 'ymir' })
  assert(state.remote_calls == 0 and state.scans == 0)
end)

for _, message in ipairs({ 'action not found', 'host unreachable', 'ps not found', 'process unavailable' }) do
  test('remote failures do not fall back to local PIDs: ' .. message, function()
    ctx.server = 'ymir'
    state.remote_error = message
    rejects('focus', message)
    rejects('resize', message)
    assert(state.scans == 0 and state.process_queries == 0)
  end)
end

for _, response in ipairs({ 3, 'invalid', {}, { result = true }, { result = {} }, { result = { is_vim = 'false' } } }) do
  test('rejects malformed remote detector responses', function()
    ctx.server = 'ymir'
    state.remote_response = response
    rejects('focus', 'invalid server-side Vim detection response')
    assert(state.scans == 0)
  end)
end

test('remote focus changes still prevent forwarding or resizing', function()
  ctx.server = 'ymir'
  state.remote_is_vim = true
  state.focused = 'block:other'
  rejects('focus', 'focused pane changed')
  rejects('resize', 'focused pane changed')
end)

test('detector action called with remote context also delegates', function()
  ctx.server = 'ymir'
  state.remote_is_vim = true
  assert(state.actions.smart_splits_is_vim.run(ctx).is_vim == true)
  assert(state.remote_calls == 1 and state.scans == 0)
end)

test('detector action propagates local scan errors', function()
  state.exec_error = 'ps not found'
  rejects('is_vim', 'ps not found')
end)

print(('Rex module tests passed (%d cases)'):format(count))
