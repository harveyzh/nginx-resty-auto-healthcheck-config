local _M = {
  _VERSION = "1.0.0"
}

local cjson = require "cjson"
local lock = require "resty.lock"
  
local STAT = ngx.shared.stat
local CONFIG = ngx.shared.config
local DICT = "stat"

local function is_cumulative(k)
  return k == "count" or k == "latency"
end

local function sett(t, ...)
  local n = select("#",...)
  for i=1,n
  do
    local k = select(i,...)
    if i == n - 1 then
      local v = select(n,...)
      if is_cumulative(k) then
        t[k] = (t[k] or 0) + v
      else
        t[k] = v
      end
      return
    end
    if not t[k] then
      t[k] = {}
    end
    t = t[k]
  end
  return t
end

local function pull_statistic()
  local t = {}
  local keys = STAT:get_keys()
  local start_time, end_time

  for _, key in pairs(keys)
  do
    local typ, u, status, arg = key:match("^(.+):(.+)|(.+)|(.+)$")

    if not arg then
      goto continue
    end

    local v = STAT:get(key)
    STAT:delete(key)

    sett(t, u, arg, status, typ, v)

    if typ == "first_request_time" then
      start_time = math.min(v, start_time or v)
    end

    if typ == "last_request_time" then
      end_time = math.max(v, end_time or v)
    end
::continue::
  end

  local reqs = t["none"] or {}
  t["none"] = nil

  -- request statistic
  for uri, data in pairs(reqs)
  do
    for status, stat in pairs(data)
    do
      stat.latency = (stat.latency or 0) / stat.count
    end
  end

  -- upstream statistic
  for uri, peers in pairs(t)
  do
    for _, data in pairs(peers)
    do
      for status, stat in pairs(data)
      do
        stat.latency = (stat.latency or 0) / stat.count
      end
    end
  end

  return start_time, end_time, { reqs = reqs, ups = t }
end

local collect_time_min = CONFIG:get("http.stat.collect_time_min") or 1
local collect_time_max = CONFIG:get("http.stat.collect_time_max") or 600

local function do_collect()
  local start_time, end_time, s = pull_statistic()
  if not start_time or not end_time then
    return
  end
  local json = cjson.encode( { start_time = start_time,
                               end_time = end_time,
                               stat = s } )
  local j = STAT:incr("collector:j", 1, 0)
  local ok, err, forcible = STAT:set("collector[" .. j .. "]", json, collect_time_max)
  if not ok then
    ngx.log(ngx.ERR, "Collector: failed to add statistic into shared memory. Increase [lua_shared_dict stat] or decrease [http.stat.collect_time_max], err:" .. err)
  end
--ngx.log(ngx.DEBUG, "collector: j=" .. j .. ", size=" .. #json .. ", json:" .. json)
end

local collector
collector = function(premature, ctx)
  if (premature) then
    return
  end

  local elapsed, err = ctx.mutex:lock("collector:mutex")

  if elapsed then
    local now = ngx.now()
    if STAT:get("collector:next") <= now then
      STAT:set("collector:next", now + collect_time_min)
      pcall(do_collect)
      STAT:flush_expired()
    end
    ctx.mutex:unlock()
  else
    ngx.log(ngx.INFO, "Collector: can't aquire mutex, err: " .. (err or "?"))
  end

  local ok, err = ngx.timer.at(collect_time_min, collector, ctx)
  if not ok then
    ngx.log(ngx.ERR, "Collector: failed to continue statistic collector job: ", err)
  end
end

function _M.spawn_collector()
  local ctx = { 
    mutex = lock:new(DICT)
  }
  STAT:safe_set("collector:next", 0)
  local ok, err = ngx.timer.at(0, collector, ctx)
  if not ok then
    ngx.log(ngx.ERR, "Collector: failed to create statistic collector job: ", err)
  end
end

local function merge(l, r)
  if not r then
    return
  end
  for k, v in pairs(r)
  do
    if type(v) == "table" then
      if not l[k] then
        l[k] = {}
      end
      merge(l[k], v)
    else
      if k == "latency" or k == "count" then
        l[k] = (l[k] or 0) + v
      elseif k == "first_request_time" then
        l[k] = math.min(l[k] or v, v)
      elseif k == "last_request_time" then
        l[k] = math.max(l[k] or v, v)
      end
      if l.count and l.first_request_time and l.last_request_time then
        if l.last_request_time >= ngx.now() - 1 then
          l.current_rps = l.count / (l.last_request_time - l.first_request_time)
        end
      end
    end
  end
end

function _M.get_statistic(period, backward)
  local t = { reqs = {}, ups = {} }
  local count_reqs = 0
  local count_ups = 0
  local current_rps = 0
  
  if not period then
    period = 60
  end

  if not backward then
    backward = 0
  end

  ngx.update_time()
  
  local now = ngx.now() - backward - period

  for j = (STAT:get("collector:j") or 0), 0, -1
  do
    local json = STAT:get("collector[" .. j .. "]")
    if not json then
      break
    end

    local stat_j = cjson.decode(json) or { stat = nil }
    
    if not stat_j.stat then
      goto continue
    end

    if stat_j.start_time > now + period then
      goto continue
    end
    
    if stat_j.end_time < now then
      break
    end

    if stat_j.stat.reqs then
      merge(t.reqs, stat_j.stat.reqs)
      count_reqs = count_reqs + 1
    end

    if stat_j.stat.ups then
      merge(t.ups, stat_j.stat.ups)
      count_ups = count_ups + 1
    end
:: continue::
  end
  
  local http_x = {}

  -- request statistic
  for uri, data in pairs(t.reqs)
  do
    for status, stat in pairs(data)
    do
      stat.latency = (stat.latency or 0) / count_reqs
      if not http_x[status] then
        http_x[status] = {}
      end
      table.insert(http_x[status], { uri = uri or "?", stat = stat })
    end
  end

  -- upstream statistic
  for u, peers in pairs(t.ups)
  do
    for peer, data in pairs(peers)
    do
      for status, stat in pairs(data)
      do
        stat.latency = (stat.latency or 0) / count_ups
      end
    end
  end
  
  -- sort by latency desc
  for status, reqs in pairs(http_x)
  do
    table.sort(reqs, function(l, r) return l.stat.latency > r.stat.latency end)
  end

  return t.reqs, t.ups, http_x, now, now + period
end

return _M