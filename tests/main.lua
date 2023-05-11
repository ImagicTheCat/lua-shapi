package.path = "src/?.lua;"..package.path

local sh = require "shapi"

local function replace_spaces(str)
  io.stdout:write((io.stdin:read("*a"):gsub("%s", str)))
end

local function md5sum(self, file)
  return self:md5sum(file):cut("-d", " ", "-f", 1)
end

print(sh:__in("src/shapi.lua"):__lua(replace_spaces, "."):__(md5sum))
