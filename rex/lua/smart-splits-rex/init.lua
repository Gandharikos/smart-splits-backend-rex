-- Rex actions for smart-splits-backend-rex. Key bindings are configured by the user.

---@class SmartSplitsRexOptions
---@field resize_amount? number Default resize amount passed to Rex. Defaults to 3.

local M = { version = '0.1.0', author = 'rawnly' }

local vim_names = {
  vi = true,
  vim = true,
  nvim = true,
  view = true,
  gvim = true,
  gview = true,
  vimdiff = true,
  nvimdiff = true,
  gvimdiff = true,
  lvim = true,
  vimx = true,
}

---@param command string?
---@return string
local function executable_name(command)
  local name = (command or ''):match('([^/\\]+)$') or ''
  -- Nix may expose the wrapped executable rather than the wrapper's name.
  return name:lower():gsub('^%.', ''):gsub('%-wrapped$', '')
end

---@param foreground table
---@return boolean
local function named_vim(foreground)
  for _, field in ipairs({ 'name', 'argv0', 'path', 'invoked_path' }) do
    if vim_names[executable_name(foreground[field])] then
      return true
    end
  end
  return false
end

---@param ctx table
---@param foreground table
---@return boolean? is_vim
---@return string? error
local function group_has_vim(ctx, foreground)
  if type(foreground.pid) ~= 'number' or foreground.pid <= 0 then
    return nil, 'foreground process has no valid PID'
  end

  -- Only reached in a server-local action context, never through remote RPC routing.
  -- A block may still run on another host. Its PIDs must never be looked up locally.
  local server, server_error = rex.call('server.status', {})
  local description, block_error = rex.session.describe_block({ block_id = ctx.block_id })
  local host = description and description.block and description.block.host_id
  if not server or not server.host_id or not host or host == '' then
    return nil, server_error or block_error or 'cannot verify the terminal host'
  end
  if host ~= server.host_id then
    return nil, 'terminal is on another host; load smart-splits-rex on the terminal host'
  end

  -- One snapshot avoids both recursive child searches (which include background jobs)
  -- and assuming the API's foreground PID is the process-group leader.
  local result, exec_error = rex.exec({ 'ps', '-ax', '-o', 'pid=,pgid=,tpgid=,stat=,comm=' }, { timeout = 1 })
  if not result or not result.ok then
    return nil, exec_error or (result and result.stderr ~= '' and result.stderr) or 'foreground process scan failed'
  end
  local processes, leader = {}, nil
  for line in result.stdout:gmatch('[^\r\n]+') do
    local pid, group, terminal_group, state, command = line:match('^%s*(%d+)%s+(%d+)%s+([%-]?%d+)%s+(%S+)%s+(.+)$')
    if pid then
      local process = {
        pid = tonumber(pid),
        group = tonumber(group),
        terminal_group = tonumber(terminal_group),
        state = state,
        name = executable_name(command),
      }
      processes[#processes + 1] = process
      if process.pid == foreground.pid then
        leader = process
      end
    end
  end
  if not leader or leader.group <= 0 or leader.group ~= leader.terminal_group then
    return nil, 'foreground process changed or has no controlling terminal; retry the key'
  end
  for _, process in ipairs(processes) do
    if
      process.group == leader.group
      and process.terminal_group == leader.group
      and not process.state:find('[TtZX]')
      and vim_names[process.name]
    then
      return true
    end
  end
  return false
end

---Detect the terminal's active editor, including one launched by Yazi or broot.
---Remote action contexts and CLI scripts delegate detection to the terminal's server.
---@param ctx table
---@return boolean? is_vim nil means detection failed, not that the pane is a shell.
---@return string? error
function M.is_vim(ctx)
  if not ctx.block_id then
    return nil, 'no terminal block in the action context'
  end
  -- RPCs follow ctx.server, but rex.exec always runs on the Lua runtime's machine.
  -- rex.args is present only in CLI scripts, which may also target a remote server.
  if (ctx.server and ctx.server ~= '') or rex.args ~= nil then
    local session_id = ctx.session_id or rex.session_id
    if not session_id or session_id == '' then
      return nil, 'no session in the detection context'
    end
    local response, err = rex.call('client.action', {
      action = 'smart_splits_is_vim',
      session_id = session_id,
      block_id = ctx.block_id,
    })
    if not response then
      return nil,
        'server-side Vim detection failed; load smart-splits-rex with setup() on the terminal server: '
          .. (err or 'no response')
    end
    local result = type(response) == 'table' and response.result
    if type(result) ~= 'table' or type(result.is_vim) ~= 'boolean' then
      return nil, 'invalid server-side Vim detection response'
    end
    return result.is_vim
  end

  local proc, err = rex.block.call('com.superlogical.terminal', 'process', { block_id = ctx.block_id })
  if not proc then
    return nil, err or 'cannot query the terminal process'
  end
  local fg = proc.foreground
  if not fg then
    return false
  end
  if named_vim(fg) then
    return true
  end
  return group_has_vim(ctx, fg)
end

local function forward_if_vim(ctx, args)
  local vim, err = M.is_vim(ctx)
  if vim == nil then
    error('smart-splits: ' .. err, 0)
  end
  -- rex.exec yields to other actions. Do not send keys or resize a newly focused pane.
  local view, view_error = rex.session.view({})
  if not view then
    error('smart-splits: ' .. (view_error or 'cannot query session focus'), 0)
  end
  local focused
  for _, window in ipairs(view.windows or {}) do
    if window.window_id == view.active_window_id then
      focused = window.focused_block_id
      break
    end
  end
  if focused ~= ctx.block_id then
    error('smart-splits: focused pane changed; retry the key', 0)
  end
  if not vim then
    return false
  end
  if not args.key or args.key == '' then
    error('smart-splits: key is required to forward to Neovim', 0)
  end
  rex.client.queue('pane.send_key', { key = args.key })
  return true
end

---@param opts? SmartSplitsRexOptions
function M.setup(opts)
  opts = opts or {}
  rex.action({
    name = 'smart_splits_is_vim',
    title = 'Smart Splits: Detect Vim',
    run = function(ctx)
      local is_vim, err = M.is_vim(ctx)
      if is_vim == nil then
        error('smart-splits: ' .. err, 0)
      end
      -- client.action omits a bare true result, so return an explicit boolean field.
      return { is_vim = is_vim }
    end,
  })
  rex.action({
    name = 'smart_splits_focus',
    title = 'Smart Splits: Focus Pane',
    repeats = true,
    args = {
      type = 'object',
      required = { 'direction' },
      properties = {
        direction = { type = 'string', enum = { 'left', 'right', 'up', 'down' } },
        key = { type = 'string' },
      },
    },
    run = function(ctx, args)
      if forward_if_vim(ctx, args) then
        return
      end
      local _, err = rex.session.focus_direction({ direction = args.direction, wrap = false })
      if err then
        error('smart-splits: ' .. err, 0)
      end
    end,
  })
  rex.action({
    name = 'smart_splits_resize',
    title = 'Smart Splits: Resize Pane',
    repeats = true,
    args = {
      type = 'object',
      required = { 'direction' },
      properties = {
        direction = { type = 'string', enum = { 'left', 'right', 'up', 'down' } },
        key = { type = 'string' },
        amount = { type = 'integer', minimum = 1 },
      },
    },
    run = function(ctx, args)
      if forward_if_vim(ctx, args) then
        return
      end
      rex.client.queue('pane.resize', { direction = args.direction, amount = args.amount or opts.resize_amount or 3 })
    end,
  })
end

return M
