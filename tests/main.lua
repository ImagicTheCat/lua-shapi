package.path = "src/?.lua;"..package.path

local sh = require "shapi"

local function replace_spaces(str)
  io.stdout:write((io.stdin:read("*a"):gsub("%s", str)))
end

local function md5sum(self, file)
  return self:md5sum(file):cut("-d", " ", "-f", 1)
end

print(sh:__in("src/shapi.lua"):__lua(replace_spaces, "."):__(md5sum))

do
  local cmd = sh:__err("/dev/null"):cat("foo/missing.txt")
  local ok, out = pcall(cmd)
  print("cat", ok, out)
end

local state = sh:git("rev-pase", "HEAD"):__wait()
assert(state.children[1].status == 1)

print(sh:__err("/dev/null"):git("re-parse", "HEAD"):__err(2):git("rev-pase", "HEAD"))
