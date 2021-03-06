local _M = {
  _VERSION = "1.0.0"
}

local pointcuts = {}
local system = require "system"

function _M.make()
  local files = system.getfiles("lua/pointcuts/init", ".+%.lua$")
  for _, file in ipairs(files)
  do
    local name = file:match("(.+)%.lua$")
    local ok, r = pcall(require, "pointcuts.init." .. name)
    if not ok  then
      ngx.log(ngx.WARN, "Loading init pointcut " .. name .. " error:" .. r)
      goto continue
    end
    table.insert(pointcuts, { name = name, m = r })
    ngx.log(ngx.INFO, "Loaded init pointcut " .. name .. " ...")
::continue::
  end
  table.sort(pointcuts, function(l, r) return l.name < r.name end)
end

function _M.process()
  for _, pointcut in ipairs(pointcuts)
  do
    local ok, err = pcall(pointcut.m.process)
    if not ok then
      ngx.log(ngx.ERR, "Init pointcut " .. pointcut.name .. " error : " .. err)
    end
  end
end

return _M