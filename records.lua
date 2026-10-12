-- records.lua: ステージごとの記録(最短時間)の保存と読み込み
-- 保存先: love.filesystem のセーブフォルダ内の records.dat
--   (Linux なら ~/.local/share/love/puchipuchi/records.dat)
-- 1件 = { time = 秒(1/100秒単位), initials = "ABC", date = "2026-09-28", color = "blue" }
--   color: どの命中判定の広さで出した記録か("blue"|"yellow"|"pink")。無くても動く
-- ステージ2は上位1件、ステージ3は上位3件+イニシャル、という使い方を想定している

local Records = {}

local FILE = "records.dat"
local data = {}     -- data[ステージid] = 記録のリスト(速い順)

local function serialize(t)
  local parts = { "return {\n" }
  local ids = {}
  for id in pairs(t) do ids[#ids + 1] = id end
  table.sort(ids)
  for _, id in ipairs(ids) do
    parts[#parts + 1] = string.format("  [%q] = {\n", id)
    for _, r in ipairs(t[id]) do
      parts[#parts + 1] = string.format("    { time = %.2f, initials = %q, date = %q, color = %q },\n",
                                        r.time, r.initials or "", r.date or "", r.color or "")
    end
    parts[#parts + 1] = "  },\n"
  end
  parts[#parts + 1] = "}\n"
  return table.concat(parts)
end

local function save()
  love.filesystem.write(FILE, serialize(data))
end

local function round2(x) return math.floor(x * 100 + 0.5) / 100 end

function Records.load()
  data = {}
  if love.filesystem.getInfo(FILE) then
    local chunk = love.filesystem.load(FILE)
    if chunk then
      local ok, t = pcall(chunk)
      if ok and type(t) == "table" then data = t end
    end
  end
end

-- 記録のリスト(速い順)。なければ空のリスト
function Records.top(id)
  return data[id] or {}
end

-- 最高記録(タイムなら最短、個数なら最多。並べ替え済みなので先頭)。なければ nil
function Records.best(id)
  local list = data[id]
  return list and list[1] and list[1].time or nil
end

-- 上位n位以内に入る記録なら順位(1〜n)を返す。圏外なら nil(保存はしない)
-- desc = true: 値が大きいほど上(エンドレスロールの潰した個数)。省略時は小さいほど上(タイム)
function Records.qualifies(id, time, n, desc)
  time = round2(time)
  local rank = 1
  for _, r in ipairs(data[id] or {}) do
    if (desc and r.time >= time) or (not desc and r.time <= time) then rank = rank + 1 end   -- 同じ値は先に出した人が上
  end
  if rank <= n then return rank end
  return nil
end

-- 記録を追加して保存する。上位n位以内なら順位を返す。圏外なら nil
-- desc = true: 値が大きいほど上(エンドレスロールの潰した個数)。time の欄にその値を入れる
function Records.add(id, time, n, initials, color, desc)
  time = round2(time)
  local list = data[id] or {}
  for i, r in ipairs(list) do r.seq = i end
  local rec = { time = time, initials = initials or "", date = os.date("%Y-%m-%d"),
                color = color or "", seq = #list + 1 }
  list[#list + 1] = rec
  table.sort(list, function(a, b)
    if a.time ~= b.time then
      if desc then return a.time > b.time end
      return a.time < b.time
    end
    return a.seq < b.seq                          -- 同タイムは先に出した記録が上
  end)
  local rank
  for i, r in ipairs(list) do
    if r == rec then rank = i end
  end
  while #list > n do list[#list] = nil end        -- 上位n件だけ残す
  data[id] = list
  save()
  if rank and rank <= n then return rank end
  return nil
end

-- 保存先のフォルダ(表示や案内用)
function Records.dir()
  return love.filesystem.getSaveDirectory()
end

return Records
