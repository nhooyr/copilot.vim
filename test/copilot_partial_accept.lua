-- Run with: nvim --headless -u NONE -n -i NONE -l test/copilot_partial_accept.lua
local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
local temporary = vim.fn.tempname()
vim.fn.mkdir(temporary .. '/autoload/copilot', 'p')
vim.fn.writefile(vim.split([[
function! CopilotTestNotify(method, params) dict abort
  call add(g:test_notifications, {'method': a:method, 'params': deepcopy(a:params)})
endfunction
function! CopilotTestRequest(method, params, ...) dict abort
  let g:test_requests += 1
  let request = {'method': a:method, 'params': a:params, 'resolve': [], 'reject': []}
  call add(g:test_pending, request)
  return request
endfunction
function! copilot#client#New() abort
  return {'client_id': 1, 'Notify': function('CopilotTestNotify'), 'Request': function('CopilotTestRequest')}
endfunction
function! copilot#client#Cancel(request) abort
  let a:request.cancelled = v:true
endfunction
function! copilot#client#Result(request, callback) abort
  call add(a:request.resolve, a:callback)
endfunction
function! copilot#client#Error(request, callback) abort
  call add(a:request.reject, a:callback)
endfunction
function! CopilotTestReply(index, result, ...) abort
  for Callback in g:test_pending[a:index - 1][a:0 ? 'reject' : 'resolve']
    call Callback(a:result)
  endfor
endfunction
]], '\n', { plain = true }), temporary .. '/autoload/copilot/client.vim')
vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(temporary)
vim.cmd('source ' .. vim.fn.fnameescape(root .. '/autoload/copilot.vim'))
vim.g.test_requests = 0
vim.g.test_pending = {}
vim.g.test_notifications = {}
vim.fn['copilot#Client']()
vim.g.copilot_idle_delay = 60000
vim.g.copilot_filetypes = { ['*'] = true }
vim.o.hidden = true

local update, advance
for _, script in ipairs(vim.fn.getscriptinfo()) do
  if script.name == root .. '/autoload/copilot.vim' then
    update = vim.fn['<SNR>' .. script.sid .. '_UpdatePreview']
    advance = '<SNR>' .. script.sid .. '_Advance'
  end
end
local ns = vim.fn['copilot#NvimNs']()
local steps, item, failure
local function eq(actual, expected, message)
  assert(vim.deep_equal(actual, expected), message .. '\nexpected: ' .. vim.inspect(expected)
    .. '\nactual: ' .. vim.inspect(actual))
end
local function stop_timer()
  vim.fn.timer_stop(vim.g._copilot_timer or -1)
  vim.g._copilot_timer = nil
end
local function check(text, lines, lengths)
  return function()
    vim.fn['copilot#Schedule']()
    stop_timer()
    eq(vim.fn['copilot#GetDisplayedSuggestion']().text, text, 'remaining suggestion')
    local marks = vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, { details = true })
    eq(#marks, text == '' and 0 or 1, 'ghost text is present without another response')
    if text ~= '' then
      eq(marks[1][4].virt_text[1][1], vim.split(text, '\n', { plain = true })[1], 'ghost text')
    end
    if lines then eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), lines, 'buffer text') end
    if lengths then
      local actual = {}
      for _, notification in ipairs(vim.g.test_notifications) do
        if notification.method == 'textDocument/didPartiallyAcceptCompletion' then
          eq(notification.params.item, item, 'original completion item')
          actual[#actual + 1] = notification.params.acceptedLength
        end
      end
      eq(actual, lengths, 'cumulative UTF-16 acceptance lengths')
    end
  end
end
local function refresh(expected)
  return function()
    local before = vim.g.test_requests
    vim.g.copilot_idle_delay = 5
    vim.fn['copilot#Schedule']()
    eq(vim.wait(expected and 1000 or 30, function() return vim.g.test_requests > before end, 5),
      expected, 'completion refresh is requested')
    vim.g.copilot_idle_delay = 60000
  end
end
function _G.copilot_test_step(index)
  local ok, error = xpcall(steps[index], debug.traceback)
  if not ok then failure = error end
end
for key, method in pairs({ ['<M-f>'] = 'copilot#AcceptWord', ['<M-a>'] = 'copilot#Accept' }) do
  vim.keymap.set('i', key, function() return vim.fn[method]('') end,
    { expr = true, silent = true, replace_keycodes = false })
end
local function run(name, line, column, text, actions)
  stop_timer()
  vim.cmd.enew()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { line })
  vim.api.nvim_win_set_cursor(0, { 1, column })
  vim.g.test_notifications = {}
  vim.g.test_requests = 0
  vim.g.test_pending = {}
  item = { insertText = text, range = {
    start = { line = 0, character = 0 },
    ['end'] = { line = 0, character = vim.str_utfindex(line, 'utf-16') },
  } }
  steps = { function()
    vim.b._copilot = { suggestions = { item }, choice = 0 }
    update()
    eq(#vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, {}), 1, 'initial suggestion is visible')
  end }
  local keys = 'i<Cmd>lua copilot_test_step(1)<CR>'
  for _, action in ipairs(actions) do
    if type(action) == 'string' then keys = keys .. action
    else
      steps[#steps + 1] = action
      keys = keys .. '<Cmd>lua copilot_test_step(' .. #steps .. ')<CR>'
    end
  end
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys .. '<Esc>', true, false, true), 'xt', false)
  stop_timer()
  assert(not failure, name .. ': ' .. tostring(failure))
  for _, request in ipairs(vim.g.test_pending) do
    eq(request.method, 'textDocument/inlineCompletion', 'no error telemetry was emitted')
  end
  print('PASS ' .. name)
end

run('repeat word acceptance without waiting for a refresh', '', 0, 'alpha beta gamma', {
  '<M-f>', check(' beta gamma'), refresh(true), check(' beta gamma'),
  '<M-f>', check(' gamma', nil, { 5, 10 }),
  '<M-a>', check('', { 'alpha beta gamma' }),
})
run('word acceptance across a newline', '', 0, 'alpha\nbeta gamma', {
  '<M-f>', check('\nbeta gamma'), '<M-f>', check(' gamma', nil, { 5, 10 }),
  '<M-a>', check('', { 'alpha', 'beta gamma' }),
})
run('existing closing suffix is retained until accepted', 'print()', 6, 'print("hello world")', {
  '<M-f>', check(' world")', { 'print("hello)' }),
  '<M-f>', check('")', nil, { 12, 18 }),
  '<M-a>', check('', { 'print("hello world")' }),
})
run('matching typing preserves the closing suffix', 'print()', 6, 'print(foo, bar)', {
  '<M-f>', check(', bar)'), ', ', check('bar)'),
  '<M-f>', check(')', { 'print(foo, bar)' }, { 9, 14 }),
  '<M-a>', check('', { 'print(foo, bar)' }),
})
run('partial notifications count UTF-16 and newlines', '', 0, '😀 one\n二 three', {
  '<M-f>', check(' one\n二 three', nil, { 2 }),
  '<M-f>', check('\n二 three', nil, { 2, 6 }),
  '<M-f>', check(' three', nil, { 2, 6, 8 }),
})
run('full word acceptance clears the suggestion', '', 0, 'alpha', {
  '<M-f>', check('', { 'alpha' }),
})
run('incompatible edits invalidate the remaining suggestion', '', 0, 'alpha beta', {
  '<M-f>', check(' beta'), 'X', check(''), refresh(true),
})
run('pending cycling callbacks preserve the remaining suggestion', '', 0, 'alpha beta gamma', {
  function()
    vim.cmd([[
      let g:pending_copilot = b:_copilot
      let alternative = copy(b:_copilot.suggestions[0])
      let alternative.insertText = 'other alternative'
      call add(b:_copilot.suggestions, alternative)
    ]])
  end,
  '<M-f>', function() vim.cmd('call ' .. advance .. '(1, g:pending_copilot)') end,
  check(' beta gamma'),
})

local function reply(index, text)
  return function()
    local position = vim.g.test_pending[index].params.position
    vim.fn.CopilotTestReply(index, { items = text and {
      { insertText = text, range = { start = position, ['end'] = position } },
    } or {} })
  end
end
run('new suggestions replace the retained preview', '', 0, 'alpha beta', {
  '<M-f>', refresh(true), check(' beta'), reply(1, ' bravo'), check(' bravo'),
  function() eq(vim.b._copilot.deleteChars, nil, 'new suggestions use their own replacement range') end,
  '<M-a>', check('', { 'alpha bravo' }),
})
run('empty refreshes preserve the retained preview', '', 0, 'alpha beta', {
  '<M-f>', refresh(true), reply(1), check(' beta'), '<M-a>', check('', { 'alpha beta' }),
})
run('failed refreshes preserve the retained preview', '', 0, 'alpha beta', {
  '<M-f>', refresh(true),
  function() vim.fn.CopilotTestReply(1, { message = 'unavailable' }, true) end,
  check(' beta'), '<M-a>', check('', { 'alpha beta' }),
})
run('typing invalidates retained previews and stale replies', '', 0, 'alpha beta', {
  '<M-f>', refresh(true), 'X', check(''), refresh(true),
  function() eq(vim.g.test_pending[1].cancelled, true, 'the superseded request is cancelled') end,
  reply(1, ' stale'), check(''), reply(2, ' fresh'), check(' fresh'),
  '<M-a>', check('', { 'alphaX fresh' }),
})
run('partial acceptance during a refresh cancels stale replies', '', 0, 'alpha beta gamma', {
  '<M-f>', refresh(true), '<M-f>', check(' gamma'), refresh(true),
  reply(1, ' stale'), check(' gamma'), reply(2, ' delta'), check(' delta'),
  '<M-a>', check('', { 'alpha beta delta' }),
})
vim.fn.delete(temporary, 'rf')
vim.cmd('qa!')
