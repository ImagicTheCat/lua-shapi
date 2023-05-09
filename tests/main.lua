package.path = "src/?.lua;"..package.path

local sh = require "shapi"

local function replace_spaces(str)
  io.stdout:write((io.stdin:read("*a"):gsub("%s", str)))
end

print(sh:__in("src/shapi.lua", "r"):__lua(replace_spaces, "."))
