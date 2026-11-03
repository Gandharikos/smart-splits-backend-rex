local h = require('tests.helpers')

local function view(block, revision)
  return {
    revision = revision,
    active_window_id = 'window:1',
    windows = { { window_id = 'window:1', focused_block_id = block } },
  }
end

describe('Rex focus script', function()
  local script, api, snapshot, calls

  before_each(function()
    h.reset_backend()
    require('smart-splits-backend-rex.rex').focus('left')
    script = assert(loadstring(h.calls[1][3]))
    snapshot = view('block:test', 1)
    calls = 0
    api = {
      block_id = 'block:test',
      args = { direction = 'left', wrap = false },
      session = {
        view = function()
          return snapshot
        end,
        focus_direction = function(args)
          calls = calls + 1
          assert.are.same({ direction = 'left', wrap = false }, args)
          snapshot = view('block:neighbor', 2)
          return { revision = 2 }
        end,
      },
    }
    setfenv(script, { rex = api, assert = getfenv(0).assert, ipairs = ipairs })
  end)

  after_each(function()
    h.restore()
  end)

  it('reports a change to the focused block', function()
    assert.are.same({ handled = true }, script())
    assert.are.equal(1, calls)
  end)

  it('does not confuse unzoom or label changes with navigation', function()
    api.session.focus_direction = function()
      snapshot = view('block:test', 2)
      return { revision = 2 }
    end
    assert.are.same({ handled = false }, script())
  end)

  it('recognizes an unchanged edge', function()
    api.session.focus_direction = function()
      return { revision = 1 }
    end
    assert.are.same({ handled = false }, script())
  end)

  it('does not navigate from a different focused pane', function()
    snapshot = view('block:other', 1)
    assert.has_error(script, 'smart-splits: source pane is no longer focused')
    assert.are.equal(0, calls)
  end)

  it('propagates API failure instead of reporting an edge', function()
    api.session.focus_direction = function()
      return nil, 'session not found'
    end
    assert.has_error(script, 'session not found')
  end)

  it('rejects missing focus after navigation', function()
    api.session.focus_direction = function()
      snapshot = { windows = {} }
      return { revision = 2 }
    end
    assert.has_error(script, 'smart-splits: no focused pane after navigation')
  end)
end)
