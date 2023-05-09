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

local M = {}

local chain_methods = {}

function chain_methods.__in(self)
  return self
end

function chain_methods.__p(self, name, ...)
  return self
end

function chain_methods.__out(self)
  return self
end

function chain_methods.__lua(self)
  return self
end

function chain_methods.__return(self)
end

local function command_chain(self, k)
  -- generate chain link/step method
  assert(type(k) == "string", "string expected to chain")
  local method = chain_methods[k]
  if not method then -- handle process methods
    method = function(self, ...) return chain_methods.__p(self, k, ...) end
  end
  return method
end

-- ignore self (the module) for the root of the chain
local function command_chain_root(command, k)
  local method = command_chain(command, k)
  return function(self, ...) return method(command, ...) end
end

local command_mt = {__index = command_chain}

local function M_index(self, k)
  -- create new command object
  local cmd = setmetatable({}, command_mt)
  -- start chaining
  return command_chain_root(cmd, k)
end

setmetatable(M, {__index = M_index})

return M
