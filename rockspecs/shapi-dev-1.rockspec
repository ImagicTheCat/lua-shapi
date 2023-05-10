rockspec_format = "3.0"
package = "shapi"
version = "dev-1"
source = {
  url = "git://github.com/ImagicTheCat/lua-shapi",
}

description = {
  summary = "Module which implements a shell API.",
  detailed = [[
The incentive is to work with the CLI/shell with an API instead of learning a shell language like bash, for scripting purposes, or if one uses Lua at the heart of its methodology.
  ]],
  homepage = "https://github.com/ImagicTheCat/lua-shapi",
  license = "MIT"
}

dependencies = {
  "lua >= 5.1, <= 5.4",
  "luaposix >= 36.1"
}
