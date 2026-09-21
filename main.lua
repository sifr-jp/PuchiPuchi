-- Puchipuchi v0.2: bubble wrap popping game (LÖVE 11.x)
-- v0.2: 行数の自動決定 / 潰れにくさの個体差 / フィルム素材感のある音 / 素材感のある描画

local pi = math.pi
local SAMPLE_RATE = 44100
local COLS = 8
local NUM_VARIANTS = 16
local PRESS_TIME = 0.22      -- 押し込みから破裂までの目安(秒)。大きいほど重い
local RELEASE_TIME = 0.25    -- 離したときに元に戻るまでの時間(秒)
local HARD_RATIO = 0.25      -- 「硬い粒」の割合
local TOP, MARGIN = 60, 16
local MAX_CELL = 64          -- 粒1つ分の最大サイズ(px)

local rows = 13
local bubbles, variants = {}, {}
local sheet = { x = 0, y = 0, w = 0, h = 0, sheen = {} }
local popped, total = 0, 0
local cell = 40
local creak, creakAt, lastTarget = nil, -1, nil

local function rand(a, b) return a + (b - a) * love.math.random() end

---------------------------------------------------------------
-- 音の合成ユーティリティ
---------------------------------------------------------------
-- バンドパスフィルタ(双2次)。ノイズに「帯域の色」を付けるのに使う
local function bandpass(f, q)
  local w0 = 2 * pi * f / SAMPLE_RATE
  local alpha = math.sin(w0) / (2 * q)
  local a0 = 1 + alpha
  local b0 = alpha / a0
  local b2 = -alpha / a0
  local a1 = -2 * math.cos(w0) / a0
  local a2 = (1 - alpha) / a0
  local x1, x2, y1, y2 = 0, 0, 0, 0
  return function(x)
    local y = b0 * x + b2 * x2 - a1 * y1 - a2 * y2
    x2, x1 = x1, x
    y2, y1 = y1, y
    return y
  end
end

local function toSource(buf, n, level)
  local peak = 1e-9
  for i = 0, n - 1 do
    local a = math.abs(buf[i])
    if a > peak then peak = a end
  end
  local sd = love.sound.newSoundData(n, SAMPLE_RATE, 16, 1)
  local g = level / peak
  for i = 0, n - 1 do sd:setSample(i, buf[i] * g) end
  return love.audio.newSource(sd, "static")
end

---------------------------------------------------------------
-- 破裂音: 鋭いクリック + 空気の胴鳴り + フィルムの張り + しわしわ
-- size: 0(小粒・高い音) 〜 1(大粒・低い音)
-- ※純音(サイン波)の共鳴を減らし、帯域ノイズ中心にして「硬い電子音」感を避ける
---------------------------------------------------------------
local function makePop(size)
  local n = math.floor(SAMPLE_RATE * 0.20)
  local body = bandpass(rand(1100, 1700) - size * 600, 1.6)   -- 空気が抜ける胴鳴り
  local skin = bandpass(rand(3200, 4800) - size * 1200, 1.2)  -- フィルムの張り
  local ripple = bandpass(rand(2500, 6000), 2.0)              -- しわのカサカサ
  local tauBody = 0.012 + size * 0.010
  local tauSkin = 0.007 + size * 0.005
  local lowF = 230 - 90 * size
  local crkTau = 0.030 + size * 0.020
  local crkRate = rand(900, 1500)      -- しわクリックの発生頻度(1/秒)。時間とともに減る
  local lp = 0
  local buf = {}

  for i = 0, n - 1 do
    local t = i / SAMPLE_RATE
    local noise = love.math.random() * 2 - 1
    lp = lp + 0.5 * (noise - lp)
    local crack = (noise - lp) * math.exp(-t / 0.0004) * 1.5            -- 鋭いクリック
    local air = body(noise) * math.exp(-t / tauBody) * 2.2              -- 胴鳴り
    local film = skin(noise) * math.exp(-t / tauSkin) * 1.6             -- フィルムの張り
    local thump = math.sin(2 * pi * lowF * t) * math.exp(-t / 0.007) * 0.35

    local imp = 0                                                       -- まばらな小さな衝撃
    if love.math.random() < crkRate * math.exp(-t / crkTau) / SAMPLE_RATE then
      imp = (love.math.random() * 2 - 1) * rand(0.4, 1.0)
    end
    local crinkle = ripple(imp) * 4

    local fade = math.min(1, (n - 1 - i) / 200)                         -- 末尾のプチノイズ防止
    buf[i] = (crack * 0.9 + air * 0.9 + film * 0.7 + thump + crinkle * 3) * fade
  end
  return toSource(buf, n, 0.85)
end

-- 押し始めの「ミシッ」というフィルムのきしみ音
local function makeCreak()
  local n = math.floor(SAMPLE_RATE * 0.06)
  local bp = bandpass(rand(1400, 2200), 2.5)
  local buf = {}
  for i = 0, n - 1 do
    local t = i / SAMPLE_RATE
    local imp = 0
    if love.math.random() < 500 / SAMPLE_RATE then imp = love.math.random() * 2 - 1 end
    local noise = (love.math.random() * 2 - 1) * 0.08
    buf[i] = bp(imp * 4 + noise) * math.exp(-t / 0.02)
  end
  return toSource(buf, n, 0.5)
end

local function playCreak()
  local now = love.timer.getTime()
  if now - creakAt < 0.05 then return end     -- 鳴らしすぎ防止
  creakAt = now
  local s = creak:clone()
  s:setPitch(rand(0.85, 1.25))
  s:setVolume(rand(0.25, 0.45))
  s:play()
end

local function playPop(b)
  local v = variants[b.snd]
  local src = v.src:clone()          -- 重ねて鳴らせるようにクローン
  src:setPitch(rand(0.9, 1.1))
  src:setVolume(rand(0.75, 1.0))
  src:play()
  if love.system.vibrate then        -- 非対応環境では何もしない
    love.system.vibrate(0.012 + 0.015 * v.size)
  end
end

---------------------------------------------------------------
-- シートの生成とレイアウト
---------------------------------------------------------------
-- 画面サイズから粒の大きさと行数を決める(縦の余白に合わせて行数が変わる)
local function calcRows()
  local W, H = love.graphics.getDimensions()
  cell = math.min((W - 2 * MARGIN) / (COLS + 0.5), MAX_CELL)
  local usable = H - TOP - MARGIN - cell
  rows = math.max(1, math.floor(usable / (cell * 0.87)) + 1)
end

local function layout()
  local W = love.graphics.getWidth()
  local ox = (W - (COLS + 0.5) * cell) / 2
  for _, b in ipairs(bubbles) do
    local off = (b.r % 2 == 0) and 0.5 or 0        -- 千鳥配置
    b.x = ox + (b.c - 1 + 0.5 + off) * cell
    b.y = TOP + cell * 0.5 + (b.r - 1) * cell * 0.87
    b.rad = cell * 0.46 * b.sz
  end
  sheet.x = ox - 0.15 * cell
  sheet.y = TOP - 0.15 * cell
  sheet.w = (COLS + 0.5) * cell + 0.3 * cell
  sheet.h = (rows - 1) * 0.87 * cell + cell + 0.3 * cell
end

local function newSheet()
  calcRows()
  bubbles = {}
  for r = 1, rows do
    for c = 1, COLS do
      local hard = love.math.random() < HARD_RATIO
      local b = {
        c = c, r = r,
        press = 0,
        -- 粒ごとの「潰れにくさ」。硬い粒は素早いなぞりでは潰れない
        thresh = hard and rand(1.2, 1.8) or rand(0.6, 1.1),
        hard = hard,
        popped = false, t = 0,
        snd = love.math.random(NUM_VARIANTS),
        sz = rand(0.97, 1.03),                     -- 大きさの個体差
        tint = rand(-0.03, 0.03),                  -- 色味の個体差
        hx = rand(-0.35, 0.35), hy = rand(-0.35, 0.35),  -- 破裂後の穴の位置
        wr = {},                                   -- 破裂後のしわ
      }
      for i = 1, 8 do
        local a, d = rand(0, 2 * pi), rand(0.1, 0.75)
        local x1, y1 = math.cos(a) * d, math.sin(a) * d
        b.wr[i] = { x1, y1, x1 + rand(-0.45, 0.45), y1 + rand(-0.45, 0.45) }
      end
      bubbles[#bubbles + 1] = b
    end
  end
  sheet.sheen = {}                                 -- 平らなフィルム面のうっすらした筋
  for i = 1, 10 do
    sheet.sheen[i] = { rand(0, 1), rand(0, 1), rand(0, 1), rand(0, 1) }
  end
  popped, total = 0, #bubbles
  lastTarget = nil
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
  creak = makeCreak()
  newSheet()
end

function love.resize() newSheet() end   -- 画面サイズが変わると行数も変わるので作り直す

function love.mousepressed(x, y, button)
  if popped == total then newSheet() return end       -- 全部潰したらリセット
  local b = hit(x, y)
  if b and not b.popped then
    b.press = math.max(b.press, rand(0.25, 0.5))      -- 素早いタップ対応
    lastTarget = b
    playCreak()
  end
end

function love.keypressed(key)
  if key == "r" then newSheet() end
  if key == "escape" then love.event.quit() end
end

function love.update(dt)
  local target
  if love.mouse.isDown(1) then target = hit(love.mouse.getPosition()) end

  -- なぞって新しい粒に入ったとき: ランダムな力が加わる
  -- → 潰れる粒と潰れない粒ができる(硬い粒はほぼ潰れない)
  if target ~= lastTarget then
    if target and not target.popped then
      target.press = target.press + rand(0.2, 0.7)
      playCreak()
    end
    lastTarget = target
  end

  for _, b in ipairs(bubbles) do
    if not b.popped then
      if b == target then
        b.press = b.press + dt / PRESS_TIME           -- 押している間、膜が張っていく
        if b.press >= b.thresh then pop(b) end
      else
        b.press = math.max(0, b.press - dt / RELEASE_TIME)  -- 離すと戻る
      end
    else
      b.t = b.t + dt
    end
  end
end

---------------------------------------------------------------
-- 描画
---------------------------------------------------------------
local function drawSheet()
  love.graphics.setColor(1, 1, 1, 0.38)                          -- 平らなフィルム面
  love.graphics.rectangle("fill", sheet.x, sheet.y, sheet.w, sheet.h, 10, 10)
  love.graphics.setLineWidth(1)
  love.graphics.setColor(0.6, 0.78, 0.92, 0.7)
  love.graphics.rectangle("line", sheet.x, sheet.y, sheet.w, sheet.h, 10, 10)
  love.graphics.setColor(1, 1, 1, 0.16)                          -- うっすらした光の筋
  for _, s in ipairs(sheet.sheen) do
    love.graphics.line(sheet.x + s[1] * sheet.w, sheet.y + s[2] * sheet.h,
                       sheet.x + s[3] * sheet.w, sheet.y + s[4] * sheet.h)
  end
end

local function drawIntact(b)
  local p = math.min(1, b.press / b.thresh)       -- 破裂までの張り具合 0〜1
  local r = b.rad * (1 - 0.10 * p)
  local tn = b.tint
  love.graphics.setColor(0, 0.1, 0.2, 0.14)                     -- 影
  love.graphics.circle("fill", b.x + r * 0.12, b.y + r * 0.18, r)
  love.graphics.setColor(0.75 + tn, 0.9 + tn, 1, 0.34 + 0.10 * p)  -- 本体(張るほど濃く)
  love.graphics.circle("fill", b.x, b.y, r)
  love.graphics.setColor(0.35, 0.6, 0.85, 0.28)                 -- 右下の厚みのある陰
  love.graphics.setLineWidth(r * 0.14)
  love.graphics.arc("line", "open", b.x, b.y, r * 0.86, -0.1, 1.6)
  love.graphics.setColor(0.5, 0.75, 0.95, 0.8)                  -- 縁
  love.graphics.setLineWidth(1.5)
  love.graphics.circle("line", b.x, b.y, r)
  love.graphics.setColor(1, 1, 1, 0.9 - 0.55 * p)               -- ハイライト
  love.graphics.ellipse("fill", b.x - r * 0.3, b.y - r * 0.35, r * 0.28, r * 0.16)
  love.graphics.setColor(1, 1, 1, 0.5 - 0.3 * p)                -- 小さな2つ目のハイライト
  love.graphics.circle("fill", b.x + r * 0.35, b.y + r * 0.4, r * 0.06)
  love.graphics.setColor(1, 1, 1, 0.22)                         -- 反射光
  love.graphics.arc("fill", b.x, b.y, r * 0.8, 0.2, 1.0)
end

local function drawPopped(b)
  local k = math.min(1, b.t / 0.1)
  local r = b.rad * (1 - 0.12 * k)
  love.graphics.setColor(0.72, 0.84, 0.92, 0.5)                 -- しぼんだ円盤
  love.graphics.circle("fill", b.x, b.y, r)
  love.graphics.setColor(0.5, 0.65, 0.8, 0.5)
  love.graphics.setLineWidth(1)
  love.graphics.circle("line", b.x, b.y, r)
  for _, w in ipairs(b.wr) do                                   -- しわ(光る面と影の面)
    love.graphics.setColor(1, 1, 1, 0.55)
    love.graphics.line(b.x + w[1] * r, b.y + w[2] * r, b.x + w[3] * r, b.y + w[4] * r)
    love.graphics.setColor(0.4, 0.6, 0.8, 0.35)
    love.graphics.line(b.x + w[1] * r + 1, b.y + w[2] * r + 1,
                       b.x + w[3] * r + 1, b.y + w[4] * r + 1)
  end
  love.graphics.setColor(0.3, 0.45, 0.6, 0.45)                  -- 破れた小さな穴
  love.graphics.ellipse("fill", b.x + b.hx * r, b.y + b.hy * r, r * 0.07, r * 0.045)
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
  drawSheet()
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
