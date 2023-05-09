package.path = "src/?.lua;"..package.path

local sh = require "shapi"

local cmd = sh:git()
print(cmd)
cmd = cmd:__in()
print(cmd)
print(sh:a(), sh:b(), sh:c())
