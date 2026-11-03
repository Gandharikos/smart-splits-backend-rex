local h = require('tests.helpers')

local HANDLED = { code = 0, stdout = '{"handled":true}\n' }
local AT_EDGE = { code = 0, stdout = '{"handled":false}\n' }

---@param call string[]
---@return string[] `rex do` arguments after the script
local function focus_args(call)
  assert.are.same({ 'do', '-e' }, { call[1], call[2] })
  return vim.list_slice(call, 4)
end

describe('move()', function()
  before_each(function()
    h.reset_backend()
  end)

  after_each(function()
    h.restore()
  end)

  for _, direction in ipairs({ 'left', 'right', 'up', 'down' }) do
    it('focuses ' .. direction, function()
      local backend = require('smart-splits-backend-rex')
      h.respond('do -e', HANDLED)
      assert.is_true(backend.move(direction))
      assert.are.equal(1, #h.calls)
      assert.are.same({ 'direction=' .. direction, 'wrap=false' }, focus_args(h.calls[1]))
    end)
  end

  it('returns false at the edge with at_edge=stop', function()
    local backend = require('smart-splits-backend-rex')
    h.respond('do -e', AT_EDGE)
    assert.is_false(backend.move('left', { at_edge = 'stop' }))
    assert.are.equal(1, #h.calls)
  end)

  it('asks Rex to wrap with at_edge=wrap', function()
    local backend = require('smart-splits-backend-rex')
    h.respond('do -e', HANDLED)
    assert.is_true(backend.move('left', { at_edge = 'wrap' }))
    assert.are.same({ 'direction=left', 'wrap=true' }, focus_args(h.calls[1]))
  end)

  it('returns false when wrapping has nowhere to go', function()
    local backend = require('smart-splits-backend-rex')
    h.respond('do -e', AT_EDGE)
    assert.is_false(backend.move('left', { at_edge = 'wrap' }))
  end)

  it('returns false when rex fails', function()
    local backend = require('smart-splits-backend-rex')
    h.respond('do -e', { code = 1 })
    assert.is_false(backend.move('left'))
  end)

  it('returns false on unexpected output', function()
    local backend = require('smart-splits-backend-rex')
    h.respond('do -e', { code = 0, stdout = 'nope' })
    assert.is_false(backend.move('left'))
  end)

  for _, response in ipairs({
    { code = 1 },
    { code = 124 },
    { code = 0, stdout = 'not JSON' },
    { code = 0, stdout = '{}' },
    { code = 0, stdout = '{"handled":"false"}' },
    { code = 0, stdout = 'null' },
  }) do
    it('does not split after a failed or invalid focus result: ' .. vim.inspect(response), function()
      local backend = require('smart-splits-backend-rex')
      h.respond('do -e', response)
      assert.is_false(backend.move('right', { at_edge = 'split' }))
      assert.are.equal(1, #h.calls)
    end)
  end

  it('splits at the edge with at_edge=split', function()
    local backend = require('smart-splits-backend-rex')
    h.respond('do -e', AT_EDGE)
    assert.is_true(backend.move('up', { at_edge = 'split' }))
    assert.are.equal(2, #h.calls)
    assert.are.same({ 'split', '--split=above' }, h.calls[2])
  end)

  it('does not split when a neighbor exists', function()
    local backend = require('smart-splits-backend-rex')
    h.respond('do -e', HANDLED)
    assert.is_true(backend.move('right', { at_edge = 'split' }))
    assert.are.equal(1, #h.calls)
  end)

  it('reports failure when creating a split fails', function()
    h.respond('do -e', AT_EDGE)
    h.respond('split', { code = 1 })
    assert.is_false(require('smart-splits-backend-rex').move('left', { at_edge = 'split' }))
  end)

  it('does nothing outside Rex', function()
    local backend = require('smart-splits-backend-rex')
    h.leave_rex()
    assert.is_false(backend.move('right'))
    assert.are.same({}, h.calls)
  end)
end)
