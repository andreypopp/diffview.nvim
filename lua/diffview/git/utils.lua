local Commit = require("diffview.git.commit").Commit
local CountDownLatch = require("diffview.control").CountDownLatch
local FileDict = require("diffview.git.file_dict").FileDict
local FileEntry = require("diffview.views.file_entry").FileEntry
local Job = require("plenary.job")
local LogEntry = require("diffview.git.log_entry").LogEntry
local Rev = require("diffview.git.rev").Rev
local RevType = require("diffview.git.rev").RevType
local Semaphore = require("diffview.control").Semaphore
local async = require("plenary.async")
local logger = require("diffview.logger")
local oop = require("diffview.oop")
local utils = require("diffview.utils")

local M = {}

---@class JobStatus
---@field SUCCESS integer
---@field ERROR integer
---@field PROGRESS integer
---@field KILLED integer
local JobStatus = oop.enum({
  "SUCCESS",
  "PROGRESS",
  "ERROR",
  "KILLED",
})

---@type Job[]
local file_history_jobs = {}
---@type Job[]
local sync_jobs = {}
---@type Semaphore
local job_queue_sem = Semaphore.new(1)

---@param job Job
local resume_sync_queue = async.void(function(job)
  local permit = job_queue_sem:acquire()
  local idx = utils.vec_indexof(sync_jobs, job)
  if idx > -1 then
    table.remove(sync_jobs, idx)
  end
  permit:forget()

  if sync_jobs[1] and not sync_jobs[1].handle then
    sync_jobs[1]:start()
  end
end)

---@param job Job
local queue_sync_job = async.void(function(job)
  job:add_on_exit_callback(function()
    resume_sync_queue(job)
  end)

  local permit = job_queue_sem:acquire()
  table.insert(sync_jobs, job)
  permit:forget()

  if #sync_jobs == 1 then
    job:start()
  end
end)

---@param max_retries integer
---@vararg Job
local ensure_output = async.wrap(function(max_retries, jobs, log_context, callback)
  local num_bad_jobs
  local num_retries = 0
  local new_jobs = {}
  log_context = log_context and ("[%s] "):format(log_context) or ""

  for n = 0, max_retries - 1 do
    num_bad_jobs = 0
    for i, job in ipairs(jobs) do

      if job.code == 0 and #job:result() == 0 then
        logger.warn(
          ("%sJob silently returned nothing! Retrying %d more times(s).")
          :format(log_context, max_retries - n)
        )
        logger.log_job(job, logger.warn)
        num_retries = n + 1

        new_jobs[i] = Job:new({
          command = job.command,
          args = job.args,
          cwd = job._raw_cwd,
          env = job.env,
        })
        new_jobs[i]:start()
        if vim.in_fast_event() then
          async.util.scheduler()
        end
        Job.join(new_jobs[i])

        job._stdout_results = new_jobs[i]._stdout_results
        job._stderr_results = new_jobs[i]._stderr_results

        if new_jobs[i].code ~= 0 then
          job.code = new_jobs[i].code
          utils.handle_failed_job(new_jobs[i])
        elseif #job._stdout_results == 0 then
          num_bad_jobs = num_bad_jobs + 1
        end
      end
    end

    if num_bad_jobs == 0 then
      if num_retries > 0 then
        logger.s_info("Retry was successful!")
      end
      callback(JobStatus.SUCCESS)
      return
    end
  end

  callback(JobStatus.ERROR)
end, 4)

local tracked_files = async.void(function(git_root, left, right, args, kind, callback)
  ---@type FileEntry[]
  local files = {}
  ---@type CountDownLatch
  local latch = CountDownLatch(2)

  ---@param job Job
  local function on_exit(job)
    utils.handle_failed_job(job)
    latch:count_down()
  end

  local namestat_job = Job:new({
    command = "git",
    args = utils.vec_join("diff", "--name-status", args),
    cwd = git_root,
    on_exit = on_exit
  })
  local numstat_job = Job:new({
    command = "git",
    args = utils.vec_join("diff", "--numstat", args),
    cwd = git_root,
    on_exit = on_exit
  })

  namestat_job:start()
  numstat_job:start()
  latch:await()
  local out_status
  if not (#namestat_job:result() == #numstat_job:result()) then
    out_status = ensure_output(2, { namestat_job, numstat_job })
  end

  if out_status == JobStatus.ERROR or not (namestat_job.code == 0 and numstat_job.code == 0) then
    callback(utils.vec_join(namestat_job:stderr_result(), numstat_job:stderr_result()), nil)
    return
  end

  local numstat_out = numstat_job:result()
  for i, s in ipairs(namestat_job:result()) do
    local status = s:sub(1, 1):gsub("%s", " ")
    local name = s:match("[%a%s][^%s]*\t(.*)")
    local oldname

    if name:match("\t") ~= nil then
      oldname = name:match("(.*)\t")
      name = name:gsub("^.*\t", "")
    end

    local stats = {
      additions = tonumber(numstat_out[i]:match("^%d+")),
      deletions = tonumber(numstat_out[i]:match("^%d+%s+(%d+)")),
    }

    if not stats.additions or not stats.deletions then
      stats = nil
    end

    table.insert(
      files,
      FileEntry({
        path = name,
        oldpath = oldname,
        absolute_path = utils.path:join(git_root, name),
        status = status,
        stats = stats,
        kind = kind,
        left = left,
        right = right,
      })
    )
  end

  callback(nil, files)
end)

local untracked_files = async.void(function(git_root, left, right, callback)
  Job:new({
    command = "git",
    args = { "ls-files", "--others", "--exclude-standard" },
    cwd = git_root,
    ---@type Job
    on_exit = function(j)
      if j.code == 0 then
        local files = {}
        for _, s in ipairs(j:result()) do
          table.insert(
            files,
            FileEntry({
              path = s,
              absolute_path = utils.path:join(git_root, s),
              status = "?",
              kind = "working",
              left = left,
              right = right,
            })
          )
        end
        callback(nil, files)
      else
        utils.handle_failed_job(j)
        callback(j:stderr_result() or {}, nil)
      end
    end
  }):start()
end)

---Get a list of files modified between two revs.
---@param git_root string
---@param left Rev
---@param right Rev
---@param path_args string[]|nil
---@param opt DiffViewOptions
---@param callback function
---@return FileDict
M.diff_file_list = async.void(function(git_root, left, right, path_args, opt, callback)
  ---@type FileDict
  local files = FileDict()
  ---@type CountDownLatch
  local latch = CountDownLatch(2)
  local rev_args = M.rev_to_args(left, right)
  local errors = {}

  tracked_files(
    git_root,
    left,
    right,
    utils.vec_join(
      rev_args,
      "--",
      path_args
    ),
    "working",
    function (err, tfiles)
      if err then
        errors[#errors+1] = err
        utils.err("Failed to get git status for tracked files!", true)
        latch:count_down()
      else
        files.working = tfiles
        local show_untracked = opt.show_untracked
        if show_untracked == nil then
          show_untracked = M.show_untracked(git_root)
        end

        if show_untracked and M.has_local(left, right) then
          ---@diagnostic disable-next-line: redefined-local
          untracked_files(git_root, left, right, function(err, ufiles)
            if err then
              errors[#errors+1] = err
              utils.err("Failed to get git status for untracked files!", true)
              latch:count_down()
            else
              files.working = utils.vec_join(files.working, ufiles)

              utils.merge_sort(files.working, function(a, b)
                return a.path:lower() < b.path:lower()
              end)
              latch:count_down()
            end
          end)
        else
          latch:count_down()
        end
      end
    end
  )

  if left.type == RevType.INDEX and right.type == RevType.LOCAL then
    local left_rev = M.head_rev(git_root) or Rev.new_null_tree()
    local right_rev = Rev(RevType.INDEX)
    tracked_files(
      git_root,
      left_rev,
      right_rev,
      utils.vec_join(
        "--cached",
        left_rev.commit,
        "--",
        path_args
      ),
      "staged",
      function(err, tfiles)
        if err then
          errors[#errors+1] = err
          utils.err("Failed to get git status for staged files!", true)
          latch:count_down()
        else
          files.staged = tfiles
          latch:count_down()
        end
      end
    )
  else
    latch:count_down()
  end

  latch:await()
  if #errors > 0 then
    callback(utils.vec_join(unpack(errors)), nil)
    return
  end

  files:update_file_trees()
  callback(nil, files)
end)

---@param log_options LogOptions
---@param single_file boolean
---@return string[]
local function prepare_fh_options(log_options, single_file)
  local o = log_options
  return utils.vec_join(
    (o.follow and single_file) and { "--follow", "--first-parent" } or { "-m", "-c" },
    o.all and { "--all" } or nil,
    o.merges and { "--merges", "--first-parent" } or nil,
    o.no_merges and { "--no-merges" } or nil,
    o.reverse and { "--reverse" } or nil,
    o.max_count and { "-n" .. o.max_count } or nil,
    o.author and { "--author=" .. o.author } or nil,
    o.grep and { "--grep=" .. o.grep } or nil
  )
end

local function structure_fh_data(namestat_data, numstat_data)
  local right_hash, left_hash, merge_hash = unpack(utils.str_split(namestat_data[1]))
  local time, time_offset = unpack(utils.str_split(namestat_data[3]))

  return {
    left_hash = left_hash,
    right_hash = right_hash,
    merge_hash = merge_hash,
    author = namestat_data[2],
    time = tonumber(time),
    time_offset = time_offset,
    rel_date = namestat_data[4],
    subject = namestat_data[5],
    namestat = utils.vec_slice(namestat_data, 6),
    numstat = numstat_data,
  }
end

---@param git_root string
---@param path_args string[]
---@param single_file boolean
---@param opt LogOptions
---@param callback function
local incremental_fh_data = async.void(function(git_root, path_args, single_file, opt, callback)
  local options = prepare_fh_options(opt, single_file)
  local raw = {}
  local namestat_job, numstat_job

  local namestat_state = {
    data = {},
    key = "namestat",
    idx = 0,
  }
  local numstat_state = {
    data = {},
    key = "numstat",
    idx = 0,
  }

  local function on_stdout(_, line, j)
    local state = j == namestat_job and namestat_state or numstat_state

    if line == "\0" then
      if state.idx > 0 then
        if not raw[state.idx] then
          raw[state.idx] = {}
        end

        raw[state.idx][state.key] = state.data

        if raw[state.idx].namestat and raw[state.idx].numstat then
          callback(
            JobStatus.PROGRESS,
            structure_fh_data(raw[state.idx].namestat, raw[state.idx].numstat)
          )
        end
      end
      state.idx = state.idx + 1
      state.data = {}
    elseif line ~= "" then
      table.insert(state.data, line)
    end
  end

  ---@type CountDownLatch
  local latch = CountDownLatch(2)

  local function on_exit(j, code)
    if code == 0 then
      on_stdout(nil, "\0", j)
    end
    latch:count_down()
  end

  namestat_job = Job:new({
    command = "git",
    args = utils.vec_join(
      "log",
      "--pretty=format:%x00%n%H %P%n%an%n%ad%n%ar%n%s",
      "--date=raw",
      "--name-status",
      options,
      "--",
      path_args
    ),
    cwd = git_root,
    on_stdout = on_stdout,
    on_exit = on_exit,
  })

  numstat_job = Job:new({
    command = "git",
    args = utils.vec_join(
      "log",
      "--pretty=format:%x00",
      "--date=raw",
      "--numstat",
      options,
      "--",
      path_args
    ),
    cwd = git_root,
    on_stdout = on_stdout,
    on_exit = on_exit,
  })

  table.insert(file_history_jobs, namestat_job)
  table.insert(file_history_jobs, numstat_job)
  namestat_job:start()
  numstat_job:start()

  latch:await()
  if namestat_job.code ~= 0 or numstat_job.code ~= 0 then
    utils.handle_failed_job(namestat_job)
    utils.handle_failed_job(numstat_job)
    callback(JobStatus.ERROR)
  else
    callback(JobStatus.SUCCESS)
  end
end)

---@param thread thread
---@param git_root string
---@param path_args string[]
---@param opt LogOptions
---@param base Rev
---@param callback function
local function process_file_history(thread, git_root, path_args, opt, base, callback)
  ---@type LogEntry[]
  local entries = {}
  local lec = 0 -- Last entry count
  local data = {}
  local data_idx = 1
  local last_status
  local resume_lock = false
  local old_path

  local single_file = #path_args == 1
    and not utils.path:is_directory(path_args[1])
    and #utils.system_list(utils.vec_join("git", "ls-files", "--", path_args), git_root) < 2

  incremental_fh_data(
    git_root,
    path_args,
    single_file,
    opt,
    function(status, d)
      if status == JobStatus.PROGRESS then
        data[#data+1] = d
      end

      last_status = status
      if not resume_lock and coroutine.status(thread) == "suspended" then
        coroutine.resume(thread)
      end
    end
  )

  while true do
    if not (last_status == JobStatus.SUCCESS or last_status == JobStatus.ERROR)
        and not data[data_idx] then
      coroutine.yield()
    end

    if last_status == JobStatus.ERROR then
      callback(entries, JobStatus.ERROR)
      return
    elseif last_status == JobStatus.SUCCESS and data_idx > #data then
      break
    end

    local cur = data[data_idx]

    local commit = Commit({
      hash = cur.right_hash,
      author = cur.author,
      time = tonumber(cur.time),
      time_offset = cur.time_offset,
      rel_date = cur.rel_date,
      subject = cur.subject,
    })

    -- 'git log --name-status' doesn't work properly for merge commits. It
    -- lists only an incomplete list of files at best. We need to use 'git
    -- show' to get file statuses for merge commits. And merges do not always
    -- have changes.
    if cur.merge_hash then
      local job
      local job_spec = {
        command = "git",
        args = utils.vec_join(
          "show",
          "--format=",
          "-m",
          "--first-parent",
          "--name-status",
          cur.right_hash,
          "--",
          old_path or path_args
        ),
        cwd = git_root,
        on_exit = function(j)
          if j.code == 0 then
            cur.namestat = j:result()
          end
          coroutine.resume(thread)
        end,
      }

      local max_retries = 2
      resume_lock = true

      for i = 0, max_retries do
        -- Git sometimes fails this job silently (exit code 0). Not sure why,
        -- possibly because we are running multiple git opeartions on the same
        -- repo concurrently. Retrying the job usually solves this.
        job = Job:new(job_spec)
        table.insert(file_history_jobs, job)
        job:start()
        coroutine.yield()
        utils.handle_failed_job(job)

        if #cur.namestat == 0 then
          logger.warn("[git] 'git-show' silently returned nothing!")
          logger.log_job(job, logger.warn)
          if i < max_retries then
            logger.warn(("[git] Retrying %d more time(s)."):format(max_retries - i))
          end
        else
          if i > 0 then
            logger.info("[git] Retry successful!")
          end
          break
        end
      end

      resume_lock = false

      if job.code ~= 0 then
        callback({}, JobStatus.ERROR)
        return
      end

      if #cur.namestat == 0 then
        -- Give up: something has been renamed. We can no longer track the
        -- history.
        logger.warn("[git] Giving up.")
        utils.warn("Displayed history may be incomplete. Check ':DiffviewLog' for details.", true)
        break
      end
    end

    local files = {}
    for i = 1, #cur.numstat do
      local status = cur.namestat[i]:sub(1, 1):gsub("%s", " ")
      local name = cur.namestat[i]:match("[%a%s][^%s]*\t(.*)")
      local oldname

      if name:match("\t") ~= nil then
        oldname = name:match("(.*)\t")
        name = name:gsub("^.*\t", "")
        if single_file then
          old_path = oldname
        end
      end

      local stats = {
        additions = tonumber(cur.numstat[i]:match("^%d+")),
        deletions = tonumber(cur.numstat[i]:match("^%d+%s+(%d+)")),
      }

      if not stats.additions or not stats.deletions then
        stats = nil
      end

      table.insert(
        files,
        FileEntry({
          path = name,
          oldpath = oldname,
          absolute_path = utils.path:join(git_root, name),
          status = status,
          stats = stats,
          kind = "working",
          commit = commit,
          left = Rev(RevType.COMMIT, cur.left_hash),
          right = base or Rev(RevType.COMMIT, cur.right_hash),
        })
      )
    end

    table.insert(
      entries,
      LogEntry({
        path_args = path_args,
        commit = commit,
        files = files,
        single_file = single_file,
      })
    )

    if #entries > 0 and #entries > lec then
      lec = #entries
      callback(entries, JobStatus.PROGRESS)
    end

    data_idx = data_idx + 1
  end

  callback(entries, JobStatus.SUCCESS)
end

---@param git_root string
---@param path_args string[]
---@param opt LogOptions
---@param base Rev
---@param callback function
function M.file_history(git_root, path_args, opt, base, callback)
  local thread

  for _, job in ipairs(file_history_jobs) do
    if not job.is_shutdown then
      job:shutdown(JobStatus.KILLED)
    end
  end
  file_history_jobs = {}

  thread = coroutine.create(function()
    process_file_history(thread, git_root, path_args, opt, base, callback)
  end)

  coroutine.resume(thread)
end

---@param git_root string
---@param path_args string[]
---@param log_options LogOptions
function M.file_history_dry_run(git_root, path_args, log_options)
  local single_file = #path_args == 1
    and utils.path:is_directory(path_args[1])
    and #utils.system_list(utils.vec_join("git", "ls-files", "--", path_args), git_root) < 2

  log_options = utils.tbl_clone(log_options)
  log_options.max_count = 1
  local options = prepare_fh_options(log_options, single_file)
  local out, code = utils.system_list(
    utils.vec_join("git", "log", "--pretty=format:%H", "--name-status", options, "--", path_args),
    git_root
  )

  return code == 0 and #out > 0
end

---Convert revs to git rev args.
---@param left Rev
---@param right Rev
---@return string[]
function M.rev_to_args(left, right)
  assert(
    not (left.type == RevType.LOCAL and right.type == RevType.LOCAL),
    "Can't diff LOCAL against LOCAL!"
  )

  if left.type == RevType.COMMIT and right.type == RevType.COMMIT then
    return { left.commit .. ".." .. right.commit }
  elseif left.type == RevType.INDEX and right.type == RevType.LOCAL then
    return {}
  elseif left.type == RevType.COMMIT and right.type == RevType.INDEX then
    return { "--cached", left.commit }
  else
    return { left.commit }
  end
end

---Convert revs to string representation.
---@param left Rev
---@param right Rev
---@return string|nil
function M.rev_to_pretty_string(left, right)
  if left.head and right.type == RevType.LOCAL then
    return nil
  elseif left.commit and right.type == RevType.LOCAL then
    return left:abbrev()
  elseif left.commit and right.commit then
    return left:abbrev() .. ".." .. right:abbrev()
  end
  return nil
end

---@return Rev
function M.head_rev(git_root)
  local out, code = utils.system_list({ "git", "rev-parse", "HEAD", "--" }, git_root)
  if code ~= 0 then
    return
  end
  local rev_string = out[1] or ""

  local s = vim.trim(rev_string):gsub("^%^", "")
  return Rev(RevType.COMMIT, s, true)
end

---Parse two endpoint, commit revs from a symmetric difference notated rev arg.
---@param git_root string
---@param rev_arg string
---@return Rev left The left rev.
---@return Rev right The right rev.
function M.symmetric_diff_revs(git_root, rev_arg)
  local r1 = rev_arg:match("(.+)%.%.%.") or "HEAD"
  local r2 = rev_arg:match("%.%.%.(.+)") or "HEAD"
  local out, code, stderr

  local function err()
    utils.err(utils.vec_join(
      ("Failed to parse rev '%s'!"):format(rev_arg),
      "Git output: ",
      stderr
    ))
  end

  out, code, stderr = utils.system_list({ "git", "merge-base", r1, r2 }, git_root)
  if code ~= 0 then
    return err()
  end
  local left_hash = out[1]:gsub("^%^", "")

  out, code, stderr = utils.system_list({ "git", "rev-parse", "--revs-only", r2 }, git_root)
  if code ~= 0 then
    return err()
  end
  local right_hash = out[1]:gsub("^%^", "")

  return Rev(RevType.COMMIT, left_hash), Rev(RevType.COMMIT, right_hash)
end

---Get the git root path of a given path.
---@param path string
---@return string|nil
function M.toplevel(path)
  local out, code = utils.system_list({ "git", "rev-parse", "--show-toplevel" }, path)
  if code ~= 0 then
    return nil
  end
  return out[1] and vim.trim(out[1])
end

---Get the path to the .git directory.
---@param path string
---@return string|nil
function M.git_dir(path)
  local out, code = utils.system_list(
    { "git", "rev-parse", "--path-format=absolute", "--git-dir" },
    path
  )
  if code ~= 0 then
    return nil
  end
  return out[1] and vim.trim(out[1])
end

M.show = async.wrap(function(git_root, args, callback)
  local job = Job:new({
    command = "git",
    args = utils.vec_join(
      "show",
      args
    ),
    cwd = git_root,
    ---@type Job
    on_exit = async.void(function(j)
      if j.code ~= 0 then
        utils.handle_failed_job(j)
        callback(j:stderr_result() or {}, nil)
      else
        local out_status
        if #j:result() == 0 then
          async.util.scheduler()
          out_status = ensure_output(2, { j }, "git.utils.show()")
        end
        if out_status == JobStatus.ERROR then
          callback(j:stderr_result() or {}, nil)
          return
        end
        callback(nil, j:result())
      end
    end),
  })
  -- NOTE: Running multiple 'show' jobs simultaneously may cause them to fail
  -- silently. Solution: queue them and run them one after another.
  queue_sync_job(job)
end, 3)

---@return string, string
function M.pathspec_split(pathspec)
  local magic = pathspec:match("^:[/!^]*:?") or pathspec:match("^:%b()") or ""
  local pattern = pathspec:sub(1 + #magic, -1)
  return magic or "", pattern or ""
end

function M.pathspec_expand(git_root, cwd, pathspec)
  local magic = pathspec:match("^:[/!^]*:?") or pathspec:match("^:%b()") or ""
  local pattern = pathspec:sub(1 + #magic, -1)
  if not utils.path:is_abs(pattern) then
    pattern = utils.path:join(utils.path:relative(cwd, git_root), pattern)
  end
  return magic .. utils.path:convert(pattern)
end

function M.pathspec_modify(pathspec, mods)
  local magic = pathspec:match("^:[/!^]*:?") or pathspec:match("^:%b()") or ""
  local pattern = pathspec:sub(1 + #magic, -1)
  return magic .. utils.path:vim_fnamemodify(pattern, mods)
end

---Check if any of the given revs are LOCAL.
---@param left Rev
---@param right Rev
---@return boolean
function M.has_local(left, right)
  return left.type == RevType.LOCAL or right.type == RevType.LOCAL
end

---Strange trick to check if a file is binary using only git.
---@param git_root string
---@param path string
---@param rev Rev
---@return boolean -- True if the file was binary for the given rev, or it didn't exist.
function M.is_binary(git_root, path, rev)
  local cmd = { "git", "-c", "submodule.recurse=false", "grep", "-I", "--name-only", "-e", "." }
  if rev.type == RevType.LOCAL then
    cmd[#cmd+1] = "--untracked"
  elseif rev.type == RevType.INDEX then
    cmd[#cmd+1] = "--cached"
  else
    cmd[#cmd+1] = rev.commit
  end

  utils.vec_push(cmd, "--", path)

  local _, code = utils.system_list(cmd, git_root, true)
  return code ~= 0
end

---Check if status for untracked files is disabled for a given git repo.
---@param git_root string
---@return boolean
function M.show_untracked(git_root)
  local out = utils.system_list(
    { "git", "config", "--type=bool", "status.showUntrackedFiles" },
    git_root,
    true
  )
  return vim.trim(out[1] or "") ~= "false"
end

function M.get_file_status(git_root, path, rev_arg)
  local out, code = utils.system_list(
    { "git", "diff", "--name-status", rev_arg, "--", path },
    git_root
  )
  if code == 0 and (out[1] and #out[1] > 0) then
    return out[1]:sub(1, 1)
  end
end

function M.get_file_stats(git_root, path, rev_arg)
  local out, code = utils.system_list(
    { "git", "diff", "--numstat", rev_arg, "--", path },
    git_root
  )
  if code == 0 and (out[1] and #out[1] > 0) then
    local stats = {
      additions = tonumber(out[1]:match("^%d+")),
      deletions = tonumber(out[1]:match("^%d+%s+(%d+)")),
    }

    if not stats.additions or not stats.deletions then
      stats = nil
    end
    return stats
  end
end

---Restore a file to the state it was in, in a given commit / rev. If no commit
---is given, unstaged files are restored to the state in index, and staged files
---are restored to the state in HEAD. The file will also be written into the
---object database such that the action can be undone.
---@param git_root string
---@param path string
---@param kind "staged"|"working"
---@param commit string
function M.restore_file(git_root, path, kind, commit)
  local file_exists = utils.path:readable(utils.path:join(git_root, path))
  local out, code

  if file_exists then
    -- Wite file blob into db
    out, code = utils.system_list({ "git", "hash-object", "-w", "--", path }, git_root)
    if code ~= 0 then
      utils.err("Failed to write file blob into the object database. Aborting file restoration.")
      return
    end
  end

  local undo
  if file_exists then
    undo = (":sp %s | %%!git show %s"):format(vim.fn.fnameescape(path), out[1]:sub(1, 11))
  else
    undo = (":!git rm %s"):format(vim.fn.fnameescape(path))
  end

  -- Revert file
  out, code = utils.system_list(
    { "git", "checkout", commit or (kind == "staged" and "HEAD" or nil), "--", path },
    git_root
  )
  if code ~= 0 then
    utils.err("Failed to revert file!")
    return
  end

  local rev_name = (commit and commit:sub(1, 11)) or (kind == "staged" and "HEAD" or "index")
  utils.info(("File restored from %s. Undo with %s"):format(rev_name, undo))
end

---@class NextLogSectionSpec
---@field git_root string
---@field path_args string[]
---@field opt LogOptions
---@field single_file boolean
---@field last_commit string
---@field i integer
---@field max integer
---@field callback function

M.JobStatus = JobStatus
return M
