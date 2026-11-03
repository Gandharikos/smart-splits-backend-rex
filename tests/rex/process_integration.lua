-- Real PTY/process-group regression test. No Rex server or user configuration is changed.
-- Run with nvim --headless -u NONE -i NONE -l tests/rex/process_integration.lua.
local plugin = dofile('rex/lua/smart-splits-rex/init.lua')
local uv = vim.uv or vim.loop
local output = ''
local job
local stopped_pid

local function wait_for(predicate, description)
  assert(vim.wait(5000, predicate, 25), 'timed out: ' .. description .. '\n' .. output)
end

local ok, err = pcall(function()
  -- Non-interactive sh, like a blocking file-manager opener, keeps its child in
  -- its own process group. The read after nvim prevents sh from exec'ing it.
  job = vim.fn.jobstart({
    '/bin/sh',
    '-c',
    'printf "LAUNCHER_READY\\n"; read start; "$@"; printf "EDITOR_EXITED\\n"; read finish',
    'launcher',
    vim.v.progpath,
    '-u',
    'NONE',
    '-i',
    'NONE',
    '-n',
  }, {
    pty = true,
    width = 80,
    height = 24,
    on_stdout = function(_, data)
      output = output .. table.concat(data, '\n')
    end,
  })
  assert(job > 0, 'could not start PTY launcher')
  local pid = vim.fn.jobpid(job)
  local snapshot = ''
  rex = {
    block = {
      call = function()
        return { foreground = { pid = pid, name = 'sh' } }
      end,
    },
    call = function()
      return { host_id = 'local-test' }
    end,
    session = {
      describe_block = function()
        return { block = { host_id = 'local-test' } }
      end,
    },
    exec = function(argv, opts)
      local result = vim.system(argv, { text = true }):wait(opts.timeout * 1000)
      snapshot = result.stdout or ''
      return { ok = result.code == 0, stdout = snapshot, stderr = result.stderr or '' }
    end,
  }
  local ctx = { block_id = 'test-pty' }
  wait_for(function()
    return output:find('LAUNCHER_READY', 1, true) ~= nil
  end, 'launcher startup')
  assert(plugin.is_vim(ctx) == false, 'shell alone must not be detected as Vim')

  vim.fn.chansend(job, '\n')
  wait_for(function()
    return plugin.is_vim(ctx) == true
  end, 'editor in launcher foreground group')

  local editor_pid
  for line in snapshot:gmatch('[^\r\n]+') do
    local process_pid, group, terminal_group, _, command = line:match('^%s*(%d+)%s+(%d+)%s+([%-]?%d+)%s+(%S+)%s+(.+)$')
    if tonumber(group) == pid and tonumber(terminal_group) == pid and command:match('nvim$') then
      editor_pid = tonumber(process_pid)
    end
  end
  assert(editor_pid, 'editor must share the launcher foreground process group')
  assert(uv.kill(editor_pid, 'sigstop'))
  stopped_pid = editor_pid
  wait_for(function()
    return plugin.is_vim(ctx) == false
  end, 'suspended editor no longer handles keys')
  assert(uv.kill(editor_pid, 'sigcont'))
  stopped_pid = nil
  wait_for(function()
    return plugin.is_vim(ctx) == true
  end, 'resumed editor handles keys')

  vim.fn.chansend(job, ':qa!\r')
  wait_for(function()
    return output:find('EDITOR_EXITED', 1, true) ~= nil
  end, 'editor exit')
  assert(plugin.is_vim(ctx) == false, 'exited editor must not leave a stale marker')
end)

if stopped_pid then
  uv.kill(stopped_pid, 'sigcont')
end
if job and job > 0 then
  vim.fn.jobstop(job)
  vim.fn.jobwait({ job }, 3000)
end
assert(ok, err)
print('Real PTY process-group tests passed (launch, suspend, resume, exit)')
