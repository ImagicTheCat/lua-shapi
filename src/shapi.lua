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

local chain_methods = {}

function chain_methods.__lua(self, fproc, ...)
  assert(self.pipe_end, "end of pipe/command")
  -- new pipe end
  local pipe_end = self.pipe_end
  local r, w = assert(unistd.pipe())
  self.pipe_end = r
  local cid = assert(unistd.fork())
  -- FORK --
  if cid == 0 then -- child
    assert(unistd.close(r))
    assert(unistd.dup2(pipe_end, unistd.STDIN_FILENO))
    assert(unistd.dup2(w, unistd.STDOUT_FILENO))
    fproc(...)
    if _VERSION == "Lua 5.1" and not jit then os.exit(0)
    else os.exit(true, true) end
  else -- parent
    table.insert(self.children, cid)
    assert(unistd.close(w))
    if pipe_end ~= unistd.STDIN_FILENO then assert(unistd.close(pipe_end)) end
  end
  return self
end

function chain_methods.__in(self, data, mode)
  assert(self.pipe_end, "end of pipe/command")
  if type(data) == "string" then
    if mode then -- open file
      local file = assert(io.open(data, mode))
      self.pipe_end = assert(stdio.fileno(file))
    else -- raw data
      chain_methods.__lua(self, function() io.stdout:write(data) end)
    end
  elseif type(data) == "number" then -- file descriptor
    self.pipe_end = data
  else
    error "invalid input"
  end
  return self
end

function chain_methods.__p(self, name, ...)
  local args = {...}
  chain_methods.__lua(self, function() assert(unistd.execp(name, args)) end)
  return self
end

function chain_methods.__out(self, file, mode)
  assert(self.pipe_end, "end of pipe/command")
  if type(file) == "string" then -- file output
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
  else -- number: general file descriptor
    local fd = assert(unistd.dup(file))
    chain_methods.__lua(self, function()
      -- read/write loop
      repeat
        local chunk = assert(unistd.read(unistd.STDIN_FILENO, stdio.BUFSIZ))
        assert(unistd.write(fd, chunk))
      until chunk == ""
      assert(unistd.close(fd))
    end)
    assert(unistd.close(fd))
  end
  return self
end

function chain_methods.__return(self)
  assert(self.pipe_end, "end of pipe/command")
  -- read all from stdout (pipe end)
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
  if err then
    local part = err.kind == "exited" and " with status " or " by signal "
    error("sub-process "..err.kind..part..err.status)
  end
  return table.concat(chunks)
end

local function command_chain(self, k)
  -- generate chain link/step method
  assert(type(k) == "string", "string expected to chain")
  local method = chain_methods[k]
  if not method then -- handle process methods
    if k:sub(1,2) == "__" then error("unknown chain special method \""..k.."\"") end
    method = function(self, ...) return chain_methods.__p(self, k, ...) end
  end
  return method
end

-- ignore self (the module) for the root of the chain
local function command_chain_root(command, k)
  local method = command_chain(command, k)
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

local M_mt = {}

function M_mt.__index(self, k)
  -- create new command object
  local cmd = setmetatable({pipe_end = unistd.STDIN_FILENO, children = {}}, command_mt)
  -- start chaining
  return command_chain_root(cmd, k)
end

return setmetatable(M, M_mt)
