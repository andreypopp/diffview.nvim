local Job = require("plenary.job")
local PathLib = require("diffview.path").PathLib
local async = require("plenary.async")

local api = vim.api
local M = {}

---@alias vector any[]

local mapping_callbacks = {}
local path_sep = package.config:sub(1, 1)
local setlocal_opr_templates = {
  set = [[setl ${option}=${value}]],
  remove = [[exe 'setl ${option}-=${value}']],
  append = [[exe 'setl ${option}=' . (&${option} == "" ? "" : &${option} . ",") . '${value}']],
  prepend = [[exe 'setl ${option}=${value}' . (&${option} == "" ? "" : "," . &${option})]],
}

---@type PathLib
M.path = PathLib({ separator = "/" })

---Echo string with multiple lines.
---@param msg string|string[]
---@param hl? string Highlight group name.
---@param schedule? boolean Schedule the echo call.
function M.echo_multiln(msg, hl, schedule)
  if schedule then
    vim.schedule(function()
      M.echo_multiln(msg, hl, false)
    end)
    return
  end

  vim.cmd("echohl " .. (hl or "None"))
  if type(msg) ~= "table" then
    msg = vim.split(msg, "\n")
  end
  for _, line in ipairs(msg) do
    line = line:gsub('"', [[\"]])
    vim.cmd(string.format('echom "%s"', line))
  end
  vim.cmd("echohl None")
end

---@param msg string|string[]
---@param schedule? boolean Schedule the echo call.
function M.info(msg, schedule)
  if type(msg) ~= "table" then
    msg = vim.split(msg, "\n")
  end
  if not msg[1] or msg[1] == "" then
    return
  end
  msg[1] = "[Diffview.nvim] " .. msg[1]
  M.echo_multiln(msg, "Directory", schedule)
end

---@param msg string|string[]
---@param schedule? boolean Schedule the echo call.
function M.warn(msg, schedule)
  if type(msg) ~= "table" then
    msg = vim.split(msg, "\n")
  end
  if not msg[1] or msg[1] == "" then
    return
  end
  msg[1] = "[Diffview.nvim] " .. msg[1]
  M.echo_multiln(msg, "WarningMsg", schedule)
end

---@param msg string|string[]
---@param schedule? boolean Schedule the echo call.
function M.err(msg, schedule)
  if type(msg) ~= "table" then
    msg = vim.split(msg, "\n")
  end
  if not msg[1] or msg[1] == "" then
    return
  end
  msg[1] = "[Diffview.nvim] " .. msg[1]
  M.echo_multiln(msg, "ErrorMsg", schedule)
end

---Call the function `f`, ignoring most of the window and buffer related
---events. The function is called in protected mode.
---@param f function
---@return boolean success
---@return any result Return value
function M.no_win_event_call(f)
  local last = vim.opt.eventignore._value
  vim.opt.eventignore:prepend(
    "WinEnter,WinLeave,WinNew,WinClosed,BufWinEnter,BufWinLeave,BufEnter,BufLeave"
  )
  local ok, err = pcall(f)
  vim.opt.eventignore = last
  return ok, err
end

function M.clamp(value, min, max)
  if value < min then
    return min
  end
  if value > max then
    return max
  end
  return value
end

function M.sign(n)
  return (n > 0 and 1 or 0) - (n < 0 and 1 or 0)
end

function M.shell_error()
  return vim.v.shell_error ~= 0
end

---Escape a string for use as a pattern.
---@param s string
---@return string
function M.pattern_esc(s)
  local result = string.gsub(s, "[%(|%)|%%|%[|%]|%-|%.|%?|%+|%*|%^|%$]", {
    ["%"] = "%%",
    ["-"] = "%-",
    ["("] = "%(",
    [")"] = "%)",
    ["."] = "%.",
    ["["] = "%[",
    ["]"] = "%]",
    ["?"] = "%?",
    ["+"] = "%+",
    ["*"] = "%*",
    ["^"] = "%^",
    ["$"] = "%$",
  })
  return result
end

function M.str_right_pad(s, min_size, fill)
  s = tostring(s)
  if #s >= min_size then
    return s
  end
  if not fill then
    fill = " "
  end
  return s .. string.rep(fill, math.ceil((min_size - #s) / #fill))
end

function M.str_left_pad(s, min_size, fill)
  s = tostring(s)
  if #s >= min_size then
    return s
  end
  if not fill then
    fill = " "
  end
  return string.rep(fill, math.ceil((min_size - #s) / #fill)) .. s
end

function M.str_center_pad(s, min_size, fill)
  s = tostring(s)
  if #s >= min_size then
    return s
  end
  if not fill then
    fill = " "
  end
  local left_len = math.floor((min_size - #s) / #fill / 2)
  local right_len = math.ceil((min_size - #s) / #fill / 2)
  return string.rep(fill, left_len) .. s .. string.rep(fill, right_len)
end

function M.str_shorten(s, max_length, head)
  if string.len(s) > max_length then
    if head then
      return "…" .. s:sub(string.len(s) - max_length + 1, string.len(s))
    end
    return s:sub(1, max_length - 1) .. "…"
  end
  return s
end

function M.str_split(s, sep)
  sep = sep or "%s+"
  local iter = s:gmatch("()" .. sep .. "()")
  local result = {}
  local sep_start, sep_end

  local i = 1
  while i ~= nil do
    sep_start, sep_end = iter()
    table.insert(result, s:sub(i, (sep_start or 0) - 1))
    i = sep_end
  end

  return result
end

---Simple string templating
---Example template: "${name} is ${value}"
---@param str string Template string
---@param table table Key-value pairs to replace in the string
function M.str_template(str, table)
  return (str:gsub("($%b{})", function(w)
    return table[w:sub(3, -2)] or w
  end))
end

---@param job Job
function M.handle_failed_job(job)
  if job.code == 0 then
    return
  end

  local logger = require("diffview.logger")
  local args = vim.tbl_map(function(arg)
    return ("'%s'"):format(arg:gsub("'", [['"'"']]))
  end, job.args)

  logger.s_error(("Job exited with a non-zero exit status! Code: %s"):format(job.code))
  logger.s_error(("[cmd] %s %s"):format(job.command, table.concat(args, " ")))

  local stderr = job:stderr_result()
  if #stderr > 0 then
    logger.s_error("[stderr] " .. table.concat(stderr, "\n"))
  end
end

---Get the output of a system command.
---@param cmd string[]
---@param cwd? string
---@param silent? boolean Supress log output
---@return string[] stdout
---@return integer code
---@return string[] stderr
function M.system_list(cmd, cwd, silent)
  if vim.in_fast_event() then
    async.util.scheduler()
  end
  local command = table.remove(cmd, 1)
  local stderr = {}
  local job = Job
    :new({
      command = command,
      args = cmd,
      cwd = cwd,
      on_stderr = function(_, data)
        table.insert(stderr, data)
      end,
    })
  local stdout, code = job:sync()
  if not silent then
    M.handle_failed_job(job)
  end
  return stdout, code, stderr
end

---HACK: workaround for inconsistent behavior from `vim.opt_local`.
---@see [Neovim issue](https://github.com/neovim/neovim/issues/14670)
---@param winids number[]|number Either a list of winids, or a single winid (0 for current window).
---`opt` fields:
---   @tfield method '"set"'|'"remove"'|'"append"'|'"prepend"' Assignment method. (default: "set")
---@overload fun(winids: number[]|number, option: string, value: string[]|string|boolean, opt?: any)
---@overload fun(winids: number[]|number, map: table<string, string[]|string|boolean>, opt?: table)
function M.set_local(winids, x, y, z)
  if type(winids) ~= "table" then
    winids = { winids }
  end

  local map, opt
  if y == nil or type(y) == "table" then
    map = x
    opt = y
  else
    map = { [x] = y }
    opt = z
  end

  opt = vim.tbl_extend("keep", opt or {}, { method = "set" })

  local cmd
  local ok, err = M.no_win_event_call(function()
    for _, id in ipairs(winids) do
      api.nvim_win_call(id, function()
        for option, value in pairs(map) do
          local o = opt

          if type(value) == "boolean" then
            cmd = string.format("setl %s%s", value and "" or "no", option)
          else
            if type(value) == "table" then
              ---@diagnostic disable-next-line: undefined-field
              o = vim.tbl_extend("force", opt, value.opt or {})
              value = table.concat(value, ",")
            end

            cmd = M.str_template(
              setlocal_opr_templates[o.method],
              { option = option, value = tostring(value):gsub("'", "''") }
            )
          end

          vim.cmd(cmd)
        end
      end)
    end
  end)

  if not ok then
    error(err)
  end
end

function M.tabnr_to_id(tabnr)
  for _, id in ipairs(api.nvim_list_tabpages()) do
    if api.nvim_tabpage_get_number(id) == tabnr then
      return id
    end
  end
end

---@generic T
---@param t `T`
---@return T
function M.tbl_clone(t)
  if not t then
    return
  end
  local clone = {}

  for k, v in pairs(t) do
    clone[k] = v
  end

  return clone
end

function M.tbl_deep_clone(t)
  if not t then
    return
  end
  local clone = {}

  for k, v in pairs(t) do
    if type(v) == "table" then
      clone[k] = M.tbl_deep_clone(v)
    else
      clone[k] = v
    end
  end

  return clone
end

function M.tbl_pack(...)
  return { n = select("#", ...), ... }
end

function M.tbl_unpack(t, i, j)
  return unpack(t, i or 1, j or t.n or #t)
end

function M.tbl_clear(t)
  for k, _ in pairs(t) do
    t[k] = nil
  end
end

---Create a shallow copy of a portion of a vector.
---@param t vector
---@param first? integer First index, inclusive
---@param last? integer Last index, inclusive
---@return vector
function M.vec_slice(t, first, last)
  local slice = {}
  for i = first or 1, last or #t do
    table.insert(slice, t[i])
  end

  return slice
end

---Join multiple vectors into one.
---@vararg vector
---@return vector
function M.vec_join(...)
  local result = {}
  local args = {...}
  local n = 0

  for i = 1, select("#", ...) do
    if type(args[i]) ~= "nil" then
      if type(args[i]) ~= "table" then
        result[n + 1] = args[i]
        n = n + 1
      else
        for j, v in ipairs(args[i]) do
          result[n + j] = v
        end
        n = n + #args[i]
      end
    end
  end

  return result
end

---Return the first index a given object can be found in a vector, or -1 if
---it's not present.
---@param t vector
---@param v any
---@return integer
function M.vec_indexof(t, v)
  for i, vt in ipairs(t) do
    if vt == v then
      return i
    end
  end
  return -1
end

---Append any number of objects to the end of a vector. Pushing `nil`
---effectively does nothing.
---@param t vector
---@return vector t
function M.vec_push(t, ...)
  for _, v in ipairs({...}) do
    t[#t + 1] = v
  end
  return t
end

function M.find_named_buffer(name)
  for _, v in ipairs(api.nvim_list_bufs()) do
    if vim.fn.bufname(v) == name then
      return v
    end
  end
  return nil
end

function M.wipe_named_buffer(name)
  local bn = M.find_named_buffer(name)
  if bn then
    local win_ids = vim.fn.win_findbuf(bn)
    for _, id in ipairs(win_ids) do
      if vim.fn.win_gettype(id) ~= "autocmd" then
        api.nvim_win_close(id, true)
      end
    end

    api.nvim_buf_set_name(bn, "")
    vim.schedule(function()
      pcall(api.nvim_buf_delete, bn, {})
    end)
  end
end

function M.find_file_buffer(path)
  local p = M.path:absolute(path)
  for _, id in ipairs(vim.api.nvim_list_bufs()) do
    if p == vim.api.nvim_buf_get_name(id) then
      return id
    end
  end
end

---Get a list of all windows that contain the given buffer.
---@param bufid integer
---@return integer[]
function M.win_find_buf(bufid)
  local result = {}
  local wins = api.nvim_list_wins()

  for _, id in ipairs(wins) do
    if api.nvim_win_get_buf(id) == bufid then
      table.insert(result, id)
    end
  end

  return result
end

---Get a list of all windows in the given tabpage that contains the given
---buffer.
---@param tabpage integer
---@param bufid integer
---@return integer[]
function M.tabpage_win_find_buf(tabpage, bufid)
  local result = {}
  local wins = api.nvim_tabpage_list_wins(tabpage)

  for _, id in ipairs(wins) do
    if api.nvim_win_get_buf(id) == bufid then
      table.insert(result, id)
    end
  end

  return result
end

function M.clear_prompt()
  vim.api.nvim_echo({ { "" } }, false, {})
  vim.cmd("redraw")
end

---@class InputCharSpec
---@field clear_prompt boolean (default: true)
---@field allow_non_ascii boolean (default: true)
---@field prompt_hl string (default: nil)

---@param prompt string
---@param opt InputCharSpec
---@return string Char
---@return string Raw
function M.input_char(prompt, opt)
  opt = vim.tbl_extend("keep", opt or {}, {
    clear_prompt = true,
    allow_non_ascii = false,
    prompt_hl = nil,
  })

  if prompt then
    vim.api.nvim_echo({ { prompt, opt.prompt_hl } }, false, {})
  end

  local c
  if not opt.allow_non_ascii then
    while type(c) ~= "number" do
      c = vim.fn.getchar()
    end
  else
    c = vim.fn.getchar()
  end

  if opt.clear_prompt then
    M.clear_prompt()
  end

  local s = type(c) == "number" and vim.fn.nr2char(c) or nil
  local raw = type(c) == "number" and s or c
  return s, raw
end

function M.input(prompt, default, completion)
  local v = vim.fn.input({
    prompt = prompt,
    default = default,
    completion = completion,
    cancelreturn = "__INPUT_CANCELLED__",
  })
  M.clear_prompt()
  return v
end

function M.raw_key(vim_key)
  return api.nvim_eval(string.format([["\%s"]], vim_key))
end

function M.pause(msg)
  vim.cmd("redraw")
  M.input_char(
    "-- PRESS ANY KEY TO CONTINUE -- " .. (msg or ""),
    { allow_non_ascii = true, prompt_hl = "Directory" }
  )
end

local function prepare_mapping(t)
  local default_options = { noremap = true, silent = true }
  if type(t[4]) ~= "table" then
    t[4] = {}
  end
  local opts = vim.tbl_extend("force", default_options, t.opt or t[4])
  local rhs
  if type(t[3]) == "function" then
    mapping_callbacks[#mapping_callbacks + 1] = t[3]
    rhs = string.format(
      "<Cmd>lua require('diffview.utils')._mapping_callbacks[%d]()<CR>",
      #mapping_callbacks
    )
  else
    assert(type(t[3]) == "string", "The rhs of the mapping must be either a string or a function!")
    rhs = t[3]
  end

  return { t[1], t[2], rhs, opts }
end

function M.key_map(t)
  local prepared = prepare_mapping(t)
  vim.api.nvim_set_keymap(prepared[1], prepared[2], prepared[3], prepared[4])
end

function M.buf_map(bufid, t)
  local prepared = prepare_mapping(t)
  vim.api.nvim_buf_set_keymap(bufid, prepared[1], prepared[2], prepared[3], prepared[4])
end

local function merge(t, first, mid, last, comparator)
  local n1 = mid - first + 1
  local n2 = last - mid
  local ls = M.vec_slice(t, first, mid)
  local rs = M.vec_slice(t, mid + 1, last)
  local i = 1
  local j = 1
  local k = first

  while i <= n1 and j <= n2 do
    if comparator(ls[i], rs[j]) then
      t[k] = ls[i]
      i = i + 1
    else
      t[k] = rs[j]
      j = j + 1
    end
    k = k + 1
  end

  while i <= n1 do
    t[k] = ls[i]
    i = i + 1
    k = k + 1
  end

  while j <= n2 do
    t[k] = rs[j]
    j = j + 1
    k = k + 1
  end
end

local function split_merge(t, first, last, comparator)
  if (last - first) < 1 then
    return
  end

  local mid = math.floor((first + last) / 2)

  split_merge(t, first, mid, comparator)
  split_merge(t, mid + 1, last, comparator)
  merge(t, first, mid, last, comparator)
end

---Perform a merge sort on a given list.
---@param t any[]
---@param comparator function|nil
function M.merge_sort(t, comparator)
  if not comparator then
    comparator = function(a, b)
      return a < b
    end
  end

  split_merge(t, 1, #t, comparator)
end

M._mapping_callbacks = mapping_callbacks
M.path_sep = path_sep

return M
