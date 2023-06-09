-- MIT License
-- 
-- Copyright (c) 2023 ImagicTheCat
-- 
-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the "Software"), to deal
-- in the Software without restriction, including without limitation the rights
-- to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
-- copies of the Software, and to permit persons to whom the Software is
-- furnished to do so, subject to the following conditions:
-- 
-- The above copyright notice and this permission notice shall be included in all
-- copies or substantial portions of the Software.
-- 
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
-- SOFTWARE.

local unistd = require "posix.unistd"
local stdio = require "posix.stdio"
local syswait = require "posix.sys.wait"

local M = {}

-- command key to access data
local CKEY = {}

-- This module implements a Shell API.
--
-- A command object is created and then chain methods are applied to it.
-- Methods will directly spawn sub-processes as they are called, there is no
-- command build phase.

local chain_methods = {}

-- Chain a Lua function (new process).
-- fproc: Lua function
-- ...: function arguments
function chain_methods.__lua(self, fproc, ...)
  assert(self[CKEY].pipe_end, "end of pipe/command")
  -- new pipe end
  local pipe_end = self[CKEY].pipe_end
  local r, w = assert(unistd.pipe())
  self[CKEY].pipe_end = r
  -- FORK --
  local cid = assert(unistd.fork())
  if cid == 0 then
    -- child
    assert(unistd.close(r))
    -- setup in/out
    assert(unistd.dup2(pipe_end, unistd.STDIN_FILENO))
    assert(unistd.dup2(w, unistd.STDOUT_FILENO))
    -- setup err
    if self[CKEY].stderr then
      assert(unistd.dup2(self[CKEY].stderr, unistd.STDERR_FILENO))
    end
    -- call
    fproc(...)
    if _VERSION == "Lua 5.1" and not jit then os.exit(0)
    else os.exit(true, true) end
  else
    -- parent
    table.insert(self[CKEY].children, {pid = cid})
    assert(unistd.close(w))
    assert(unistd.close(pipe_end))
  end
  return self
end

-- Input raw string data into the chain (new process).
-- data: string
function chain_methods.__str_in(self, data)
  return chain_methods.__lua(self, function() assert(io.stdout:write(data)) end)
end

-- Input a file into the chain.
-- (file, [mode]): path and mode like io.open()
--- mode: default to "rb"
-- (file): file descriptor (number)
function chain_methods.__in(self, file, mode)
  assert(self[CKEY].pipe_end, "end of pipe/command")
  if type(file) == "string" then -- file
    mode = mode or "rb"
    local fh = assert(io.open(file, mode))
    -- close pipe end, because there is no process to link
    assert(unistd.close(self[CKEY].pipe_end))
    self[CKEY].pipe_end = assert(stdio.fileno(fh))
  else -- number: file descriptor
    local new_end = assert(unistd.dup(file))
    -- close pipe end, because there is no process to link
    assert(unistd.close(self[CKEY].pipe_end))
    self[CKEY].pipe_end = new_end
  end
  return self
end

-- Chain a shell process.
-- name: shell process name/path (see luaposix `execp`)
-- ...: process arguments
function chain_methods.__p(self, name, ...)
  local args = {...}
  chain_methods.__lua(self, function() assert(unistd.execp(name, args)) end)
  return self
end

-- Output from the chain to a file (new process).
-- (file, [mode]): path and mode like io.open()
--- mode: default to "wb"
-- (file): file descriptor (number)
function chain_methods.__out(self, file, mode)
  assert(self[CKEY].pipe_end, "end of pipe/command")
  if type(file) == "string" then
    -- file output
    mode = mode or "wb"
    chain_methods.__lua(self, function()
      local fh = assert(io.open(file, mode))
      -- read/write loop
      local data = io.stdin:read(stdio.BUFSIZ)
      while data do
        assert(fh:write(data))
        -- next
        data = io.stdin:read(stdio.BUFSIZ)
      end
      fh:close()
    end)
  else
    -- number: file descriptor
    local fd = assert(unistd.dup(file))
    chain_methods.__lua(self, function()
      -- read/write loop
      repeat
        local chunk = assert(unistd.read(unistd.STDIN_FILENO, stdio.BUFSIZ))
        assert(unistd.write(fd, chunk))
      until chunk == ""
    end)
    -- close fd from the parent
    assert(unistd.close(fd))
  end
  return self
end

-- Setup stderr for subsequent processes of the chain.
-- (file, [mode]): path and mode like io.open()
--- mode: default to "wb"
-- (file): file descriptor (number)
function chain_methods.__err(self, file, mode)
  assert(self[CKEY].pipe_end, "end of pipe/command")
  if type(file) == "string" then -- file
    mode = mode or "wb"
    local fh = assert(io.open(file, mode))
    if self[CKEY].stderr then assert(unistd.close(self[CKEY].stderr)) end
    self[CKEY].stderr = assert(stdio.fileno(fh))
  else -- number: file descriptor
    local new_stderr = assert(unistd.dup(file))
    if self[CKEY].stderr then assert(unistd.close(self[CKEY].stderr)) end
    self[CKEY].stderr = new_stderr
  end
  return self
end

-- Wait/end the command (wait on the command processes).
-- Return command internal state.
-- state: {}
--- .output: unprocessed final output (stdout), string
--- .children: list of {}
---- .pid: pid
---- .kind: "exited", "killed" or "stopped"
---- .status: exit status, or signal number responsible for "killed" or "stopped"
function chain_methods.__wait(self)
  assert(self[CKEY].pipe_end, "end of pipe/command")
  -- read all from the pipe end
  local chunks = {}
  repeat
    local chunk = assert(unistd.read(self[CKEY].pipe_end, stdio.BUFSIZ))
    table.insert(chunks, chunk)
  until chunk == ""
  assert(unistd.close(self[CKEY].pipe_end))
  self[CKEY].pipe_end = nil
  self[CKEY].output = table.concat(chunks)
  -- close stderr
  if self[CKEY].stderr then
    assert(unistd.close(self[CKEY].stderr))
    self[CKEY].stderr = nil
  end
  -- wait on all children processes
  for _, child in ipairs(self[CKEY].children) do
    _, child.kind, child.status = assert(syswait.wait(child.pid))
  end
  return self[CKEY]
end

-- Return/end the command.
--
-- It waits on the command processes, propagates exit errors or returns the
-- final output (stdout) as a string. By default, trailing new lines are
-- removed, but this can be disabled using the mode parameter.
--
-- Calling on the command object, string conversion and concatenation are aliases to `__return()`.
--
-- mode: (optional) "binary" to prevent processing of the output
function chain_methods.__return(self, mode)
  if mode ~= nil and mode ~= "binary" then error('invalid mode "'..mode..'"') end
  local state = chain_methods.__wait(self)
  -- propagate error
  for _, child in ipairs(self[CKEY].children) do
    if child.status ~= 0 then
      local part = child.kind == "exited" and " with status " or " by signal "
      error("sub-process "..child.kind..part..child.status)
    end
  end
  -- post-process output
  if mode ~= "binary" then
    -- remove trailing new lines
    return (state.output:gsub("[\r\n]*$", ""))
  else
    return state.output
  end
end

-- Chain custom method.
-- f: function method
-- ...: method arguments
function chain_methods.__(self, f, ...) return f(self, ...) end

-- Get the next method from the command object.
local function command_chain(self, k)
  assert(type(k) == "string", "string expected to chain")
  local method = chain_methods[k]
  if not method then
    if k:sub(1,2) == "__" then error("unknown chain special method \""..k.."\"") end
    -- generate process method
    method = function(self, ...) return chain_methods.__p(self, k, ...) end
  end
  return method
end

-- Get the first method from the command object.
-- It ignores `self` (the module) for the root of the chain.
local function command_chain_root(command, k)
  local method = command_chain(command, k)
  -- init command
  command[CKEY].pipe_end = assert(unistd.dup(unistd.STDIN_FILENO))
  command[CKEY].children = {}
  return function(self, ...)
    assert(self == M, "first chain method not called on the module")
    return method(command, ...)
  end
end

local command_mt = {
  __index = command_chain,
  __tostring = chain_methods.__return,
  __call = chain_methods.__return
}

function command_mt.__concat(lhs, rhs)
  if getmetatable(lhs) == command_mt then lhs = tostring(lhs) end
  if getmetatable(rhs) == command_mt then rhs = tostring(rhs) end
  return lhs..rhs
end

-- Module

local M_mt = {}

function M_mt.__index(self, k)
  -- create new command object
  local cmd = setmetatable({[CKEY] = {}}, command_mt)
  -- start chaining
  return command_chain_root(cmd, k)
end

return setmetatable(M, M_mt)
