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
  assert(self.pipe_end, "end of pipe/command")
  -- new pipe end
  local pipe_end = self.pipe_end
  local r, w = assert(unistd.pipe())
  self.pipe_end = r
  -- FORK --
  local cid = assert(unistd.fork())
  if cid == 0 then
    -- child
    assert(unistd.close(r))
    assert(unistd.dup2(pipe_end, unistd.STDIN_FILENO))
    assert(unistd.dup2(w, unistd.STDOUT_FILENO))
    fproc(...)
    if _VERSION == "Lua 5.1" and not jit then os.exit(0)
    else os.exit(true, true) end
  else
    -- parent
    table.insert(self.children, cid)
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
  assert(self.pipe_end, "end of pipe/command")
  if type(file) == "string" then -- file
    mode = mode or "rb"
    local fh = assert(io.open(file, mode))
    -- close pipe end, because there is no process to link
    assert(unistd.close(self.pipe_end))
    self.pipe_end = assert(stdio.fileno(fh))
  else -- number: file descriptor
    local new_end = assert(unistd.dup(data))
    -- close pipe end, because there is no process to link
    assert(unistd.close(self.pipe_end))
    self.pipe_end = new_end
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
  assert(self.pipe_end, "end of pipe/command")
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
  if mode ~= nil and mode ~= "binary" then error("invalid mode "..string.format("%q", mode)) end
  assert(self.pipe_end, "end of pipe/command")
  -- read all from the pipe end
  local chunks = {}
  repeat
    local chunk = assert(unistd.read(self.pipe_end, stdio.BUFSIZ))
    table.insert(chunks, chunk)
  until chunk == ""
  assert(unistd.close(self.pipe_end))
  self.pipe_end = nil
  -- wait on all children processes (defer error propagation)
  local err
  for _, cid in ipairs(self.children) do
    local pid, kind, status = assert(syswait.wait(cid))
    if status ~= 0 and not err then
      err = {pid = pid, kind = kind, status = status}
    end
  end
  -- propagate error
  if err then
    local part = err.kind == "exited" and " with status " or " by signal "
    error("sub-process "..err.kind..part..err.status)
  end
  -- post-process output
  if mode ~= "binary" then
    -- remove trailing new lines
    return table.concat(chunks):gsub("[\r\n]*$", "")
  else
    return table.concat(chunks)
  end
end

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
  command.pipe_end = assert(unistd.dup(unistd.STDIN_FILENO))
  command.children = {}
  return function(self, ...) return method(command, ...) end
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
  local cmd = setmetatable({}, command_mt)
  -- start chaining
  return command_chain_root(cmd, k)
end

return setmetatable(M, M_mt)
