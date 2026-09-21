-- Puchipuchi: bubble wrap popping game (LÖVE 11.x)

local pi = math.pi
local SAMPLE_RATE = 44100
local COLS, ROWS = 8, 13        -- シートの粒数
local NUM_VARIANTS = 12         -- 音のバリエーション数
local PRESS_TIME = 0.10         -- 押し込みから破裂までの目安(秒)。小さいほど軽い
local TOP, MARGIN = 60, 16

local bubbles, variants = {}, {}
local popped, total = 0, 0
local cell = 40

local function rand(a, b) return a + (b - a) * love.math.random() end

---------------------------------------------------------------
-- 音の合成: クリック + 共鳴 + 低い響き
-- size: 0(小粒・高い音) 〜 1(大粒・低い音)
---------------------------------------------------------------
local function makePop(size)
  local dur = 0.15
  local n = math.floor(SAMPLE_RATE * dur)
  local f0 = rand(2600, 3400) - size * 1400   -- 共鳴周波数
  local f1 = f0 * rand(1.45, 1.7)             -- 倍音っぽい第2共鳴
  local tauRes = 0.010 + size * 0.008         -- 共鳴の減衰時間
  local low = 180 - 60 * size                 -- 低い響き
  local phase = rand(0, 2 * pi)
  local lp = 0
  local buf, peak = {}, 0

  for i = 0, n - 1 do
    local t = i / SAMPLE_RATE
    local noise = love.math.random() * 2 - 1
    lp = lp + 0.35 * (noise - lp)                             -- 簡易ローパス
    local crack = noise * math.exp(-t / 0.0006)               -- 鋭いクリック
    local body = lp * math.exp(-t / 0.004) * 0.8              -- 空気の噴出感
    local res = (math.sin(2 * pi * f0 * t + phase)
              + 0.5 * math.sin(2 * pi * f1 * t))
              * math.exp(-t / tauRes) * 0.5                   -- 膜の共鳴
    local thump = math.sin(2 * pi * low * t) * math.exp(-t / 0.006) * 0.4
    local s = crack + body + res + thump
    buf[i] = s
    if math.abs(s) > peak then peak = math.abs(s) end
  end

  local sd = love.sound.newSoundData(n, SAMPLE_RATE, 16, 1)
  local gain = 0.85 / peak
  for i = 0, n - 1 do sd:setSample(i, buf[i] * gain) end
  return love.audio.newSource(sd, "static")
end

local function playPop(b)
  local v = variants[b.snd]
  local src = v.src:clone()          -- 重ねて鳴らせるようにクローン
  src:setPitch(rand(0.94, 1.06))
  src:setVolume(rand(0.8, 1.0))
  src:play()
  if love.system.vibrate then        -- 非対応環境では何もしない
    love.system.vibrate(0.012 + 0.015 * v.size)
  end
end

---------------------------------------------------------------
-- シートの生成とレイアウト
---------------------------------------------------------------
local function layout()
  local W, H = love.graphics.getDimensions()
  local cellW = (W - 2 * MARGIN) / (COLS + 0.5)
  local cellH = (H - TOP - MARGIN) / ((ROWS - 1) * 0.87 + 1)
  cell = math.min(cellW, cellH)
  local ox = (W - (COLS + 0.5) * cell) / 2
  for _, b in ipairs(bubbles) do
    local off = (b.r % 2 == 0) and 0.5 or 0        -- 千鳥配置
    b.x = ox + (b.c - 1 + 0.5 + off) * cell
    b.y = TOP + cell * 0.5 + (b.r - 1) * cell * 0.87
    b.rad = cell * 0.46
  end
end

local function newSheet()
  bubbles = {}
  for r = 1, ROWS do
    for c = 1, COLS do
      local b = {
        c = c, r = r,
        press = 0,
        thresh = rand(0.75, 1.0),      -- 粒ごとの「潰れやすさ」の個体差
        popped = false, t = 0,
        snd = love.math.random(NUM_VARIANTS),
        wr = {},                       -- 破裂後のしわ
      }
      for i = 1, 5 do
        local a, d = rand(0, 2 * pi), rand(0.1, 0.7)
        local x1, y1 = math.cos(a) * d, math.sin(a) * d
        b.wr[i] = { x1, y1, x1 + rand(-0.4, 0.4), y1 + rand(-0.4, 0.4) }
      end
      bubbles[#bubbles + 1] = b
    end
  end
  popped, total = 0, ROWS * COLS
  layout()
end

local function hit(mx, my)
  for _, b in ipairs(bubbles) do
    local dx, dy = mx - b.x, my - b.y
    if dx * dx + dy * dy <= b.rad * b.rad then return b end
  end
end

local function pop(b)
  b.popped, b.t = true, 0
  popped = popped + 1
  playPop(b)
end

---------------------------------------------------------------
-- LÖVE コールバック
---------------------------------------------------------------
function love.load()
  love.graphics.setBackgroundColor(0.86, 0.92, 0.96)
  love.math.setRandomSeed(os.time())
  for i = 1, NUM_VARIANTS do
    local size = (i - 1) / (NUM_VARIANTS - 1) * 0.5   -- ステージ1は小粒中心
    variants[i] = { src = makePop(size), size = size }
  end
  newSheet()
end

function love.resize() layout() end

function love.mousepressed(x, y, button)
  if popped == total then newSheet() return end       -- 全部潰したらリセット
  local b = hit(x, y)
  if b and not b.popped then b.press = math.max(b.press, 0.5) end  -- 素早いタップ対応
end

function love.keypressed(key)
  if key == "r" then newSheet() end
  if key == "escape" then love.event.quit() end
end

function love.update(dt)
  local target
  if love.mouse.isDown(1) then target = hit(love.mouse.getPosition()) end
  for _, b in ipairs(bubbles) do
    if not b.popped then
      if b == target then
        b.press = b.press + dt / PRESS_TIME       -- 押している間、膜が張っていく
        if b.press >= b.thresh then pop(b) end
      else
        b.press = math.max(0, b.press - dt / 0.15) -- 離すと戻る
      end
    else
      b.t = b.t + dt
    end
  end
end

---------------------------------------------------------------
-- 描画
---------------------------------------------------------------
local function drawIntact(b)
  local p = b.press
  local r = b.rad * (1 - 0.10 * p)
  love.graphics.setColor(0, 0.1, 0.2, 0.12)                     -- 影
  love.graphics.circle("fill", b.x + r * 0.12, b.y + r * 0.18, r)
  love.graphics.setColor(0.75, 0.9, 1, 0.35)                    -- 本体
  love.graphics.circle("fill", b.x, b.y, r)
  love.graphics.setColor(0.5, 0.75, 0.95, 0.8)                  -- 縁
  love.graphics.setLineWidth(1.5)
  love.graphics.circle("line", b.x, b.y, r)
  love.graphics.setColor(1, 1, 1, 0.85 - 0.5 * p)               -- ハイライト
  love.graphics.ellipse("fill", b.x - r * 0.3, b.y - r * 0.35, r * 0.28, r * 0.16)
  love.graphics.setColor(1, 1, 1, 0.25)                         -- 反射光
  love.graphics.arc("fill", b.x, b.y, r * 0.8, 0.2, 1.0)
end

local function drawPopped(b)
  local k = math.min(1, b.t / 0.1)
  local r = b.rad * (1 - 0.1 * k)
  love.graphics.setColor(0.72, 0.84, 0.92, 0.5)                 -- しぼんだ円盤
  love.graphics.circle("fill", b.x, b.y, r)
  love.graphics.setColor(0.5, 0.65, 0.8, 0.5)
  love.graphics.setLineWidth(1)
  love.graphics.circle("line", b.x, b.y, r)
  for _, w in ipairs(b.wr) do                                   -- しわ
    love.graphics.setColor(1, 1, 1, 0.55)
    love.graphics.line(b.x + w[1] * r, b.y + w[2] * r, b.x + w[3] * r, b.y + w[4] * r)
    love.graphics.setColor(0.4, 0.6, 0.8, 0.35)
    love.graphics.line(b.x + w[1] * r + 1, b.y + w[2] * r + 1,
                       b.x + w[3] * r + 1, b.y + w[4] * r + 1)
  end
  if b.t < 0.25 then                                            -- 破裂の一瞬の演出
    local q = b.t / 0.25
    love.graphics.setColor(1, 1, 1, 0.9 * (1 - q))
    love.graphics.setLineWidth(2)
    love.graphics.circle("line", b.x, b.y, b.rad * (1 + 0.6 * q))
    if b.t < 0.08 then
      love.graphics.setColor(1, 1, 1, 0.6 * (1 - b.t / 0.08))
      love.graphics.circle("fill", b.x, b.y, b.rad)
    end
  end
end

function love.draw()
  for _, b in ipairs(bubbles) do
    if b.popped then drawPopped(b) else drawIntact(b) end
  end
  love.graphics.setColor(0.2, 0.3, 0.4)
  love.graphics.print(string.format("%d / %d   [R] reset", popped, total), 16, 20)
  if popped == total then
    love.graphics.printf("All popped! Tap to start again", 0, 24,
                         love.graphics.getWidth(), "center")
  end
end
