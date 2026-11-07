-- Optional live Rex test. Uses an isolated server, or REX_TEST_SERVER with this module installed.
-- Run with nvim --headless -u NONE -i NONE -l tests/rex/server_integration.lua.
local uv = vim.uv or vim.loop
local directory = vim.fn.tempname()
local endpoint = vim.env.REX_TEST_SERVER or ('unix://' .. directory .. '/server.sock')
local module_path = vim.fn.fnamemodify('rex/lua/smart-splits-rex/init.lua', ':p')
local server, session, block
local server_log = ''

local function command(args)
  local argv = { 'rex', '--autostart=false', '-S', endpoint }
  vim.list_extend(argv, args)
  local result = vim.system(argv, { text = true }):wait(10000)
  assert(result.code == 0, (result.stderr or '') .. '\n' .. server_log)
  return result.stdout or ''
end

local function detect(forwarded)
  local script = ([[
    local plugin = dofile(%q)
    local ctx = { session_id = rex.session_id, block_id = rex.block_id }
    if %s then
      ctx.server = 'terminal-host'
      rex.args = nil
    end
    rex.exec = function() error('must not scan PIDs in the caller runtime') end
    local is_vim, err = plugin.is_vim(ctx)
    assert(is_vim ~= nil, err)
    return { is_vim = is_vim }
  ]]):format(module_path, tostring(forwarded))
  return vim.json.decode(command({ 'do', '-s', session, '-b', block, '-e', script, '--json' })).is_vim
end

local function wait_for(predicate, message)
  assert(vim.wait(10000, predicate, 50), message .. '\n' .. server_log)
end

local ok, err = pcall(function()
  if not vim.env.REX_TEST_SERVER then
    vim.fn.mkdir(directory, 'p')
    local config = directory .. '/init.lua'
    vim.fn.writefile({ ('dofile(%q).setup()'):format(module_path) }, config)
    server = vim.system({
      'rex',
      'server',
      'run',
      '--listen',
      endpoint,
      '--state-dir',
      directory .. '/state',
      '--restore=false',
      '--config',
      config,
    }, {
      stderr = function(_, data)
        server_log = server_log .. (data or '')
      end,
    })
    wait_for(function()
      return uv.fs_stat(directory .. '/server.sock') ~= nil
    end, 'server did not start')
  end

  local created = vim.json.decode(command({
    'new',
    'smart-splits-test',
    '--shell=none',
    '--json',
    '--',
    '/bin/sh',
    '-c',
    'printf "LAUNCHER_READY\\n"; read start; "$@"; printf "EDITOR_EXITED\\n"; read finish',
    'launcher',
    vim.env.REX_TEST_NVIM or vim.v.progpath,
    '-u',
    'NONE',
    '-i',
    'NONE',
    '-n',
  }))
  session = created.session_id
  block = created.initial_windows[1].block_ids[1]
  local function captured(marker)
    return command({ 'capture', '-s', session, '-b', block, '--trim' }):find(marker, 1, true) ~= nil
  end
  wait_for(function()
    return captured('LAUNCHER_READY')
  end, 'launcher did not start')
  assert(detect(false) == false, 'CLI must detect a shell via the server')
  assert(detect(true) == false, 'forwarded context must detect a shell via the server')

  command({ 'send-key', '-s', session, '-b', block, 'enter' })
  wait_for(function()
    return detect(false) == true
  end, 'server did not detect the editor inside the launcher process group')
  assert(detect(true) == true, 'forwarded context must detect the editor via the server')

  command({ 'send', '-s', session, '-b', block, ':qa!' })
  command({ 'send-key', '-s', session, '-b', block, 'enter' })
  wait_for(function()
    return captured('EDITOR_EXITED')
  end, 'editor did not exit')
  assert(detect(false) == false and detect(true) == false, 'server must not retain stale editor state')
end)

if session then
  local cleaned, cleanup_error = pcall(command, { 'kill', session })
  if not cleaned then
    ok, err = false, tostring(err) .. '\ncleanup: ' .. tostring(cleanup_error)
  end
end
if server then
  server:kill('sigterm')
  server:wait(5000)
end
vim.fn.delete(directory, 'rf')
assert(ok, err)
print('Live Rex tests passed (CLI/server delegation, forwarded context, editor launch and exit)')
