-- Puchipuchi v0.3: bubble wrap popping game (LÖVE 11.x)
-- v0.2: 行数の自動決定 / 潰れにくさの個体差 / フィルム素材感のある音と描画
-- v0.3: 手応えを重く+押し込み速度のランダム変化 / 音に重みを追加 /
--       「空気は潰れたが素材が伸びて破れない」挙動(変形・きしみ音・戻りの音)

local pi = math.pi
local SAMPLE_RATE = 44100
local COLS = 8
local NUM_VARIANTS = 16
local PRESS_TIME = 0.30      -- 押し込みから破裂までの目安(秒)。大きいほど重い
local RELEASE_TIME = 0.25    -- 離したときに元に戻るまでの時間(秒)
local HARD_RATIO = 0.25      -- 「伸びて潰れにくい粒」の割合
local SOUND_WEIGHT = 1.0     -- 破裂音の低音の重み。大きいほど重く、小さいほど軽い
local TOP, MARGIN = 60, 16
local MAX_CELL = 64          -- 粒1つ分の最大サイズ(px)

local rows = 13
local bubbles, variants = {}, {}
local stretchSrc, springSrc = {}, {}
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
-- 破裂音: 鋭いクリック + 空気の胴鳴り + 低い胴鳴り(重み) + フィルムの張り + しわしわ
-- size: 0(小粒・高い音) 〜 1(大粒・低い音)
---------------------------------------------------------------
local function makePop(size)
  local n = math.floor(SAMPLE_RATE * 0.22)
  local body = bandpass(rand(750, 1200) - size * 400, 1.6)   -- 空気が抜ける胴鳴り
  local deep = bandpass(rand(320, 480) - size * 100, 1.3)    -- 低い胴鳴り(重み)
  local skin = bandpass(rand(2800, 4200) - size * 1000, 1.2) -- フィルムの張り
  local ripple = bandpass(rand(2500, 6000), 2.0)             -- しわのカサカサ
  local tauBody = 0.014 + size * 0.010
  local tauDeep = 0.028 + size * 0.015
  local tauSkin = 0.007 + size * 0.005
  local lowF = 175 - 70 * size
  local crkTau = 0.030 + size * 0.020
  local crkRate = rand(900, 1500)      -- しわクリックの発生頻度(1/秒)。時間とともに減る
  local lp = 0
  local buf = {}

  for i = 0, n - 1 do
    local t = i / SAMPLE_RATE
    local noise = love.math.random() * 2 - 1
    lp = lp + 0.5 * (noise - lp)
    local crack = (noise - lp) * math.exp(-t / 0.0004) * 1.5
    local air = body(noise) * math.exp(-t / tauBody) * 3.0
    local thick = deep(noise) * math.exp(-t / tauDeep) * 5.0 * SOUND_WEIGHT
    local film = skin(noise) * math.exp(-t / tauSkin) * 1.4
    local thump = math.sin(2 * pi * lowF * t) * math.exp(-t / 0.010) * 0.6 * SOUND_WEIGHT

    local imp = 0                                                       -- まばらな小さな衝撃
    if love.math.random() < crkRate * math.exp(-t / crkTau) / SAMPLE_RATE then
      imp = (love.math.random() * 2 - 1) * rand(0.4, 1.0)
    end
    local crinkle = ripple(imp) * 4

    local fade = math.min(1, (n - 1 - i) / 200)                         -- 末尾のプチノイズ防止
    buf[i] = (crack * 0.8 + air * 0.9 + thick * 0.9 + film * 0.6 + thump + crinkle * 3) * fade
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

-- 素材が伸びるときの「ミチミチ…」という音(引っ掛かりと滑りの繰り返し)
local function makeStretch()
  local n = math.floor(SAMPLE_RATE * 0.16)
  local bp = bandpass(rand(700, 1100), 3.0)
  local bp2 = bandpass(rand(1800, 2600), 2.5)
  local pulse = rand(55, 85)          -- 引っ掛かり→滑りの周期(Hz)
  local buf = {}
  for i = 0, n - 1 do
    local t = i / SAMPLE_RATE
    local noise = love.math.random() * 2 - 1
    local saw = (t * pulse) % 1
    local amp = 0.35 + 0.65 * saw
    local env = math.min(1, t / 0.02) * math.exp(-t / 0.07)
    local fade = math.min(1, (n - 1 - i) / 200)
    buf[i] = (bp(noise) * 1.6 + bp2(noise) * 0.6) * amp * env * fade
  end
  return toSource(buf, n, 0.6)
end

-- 押さえていた指を離したとき、伸びた素材が戻って空気が戻る「ポコッ」という音
local function makeSpring()
  local n = math.floor(SAMPLE_RATE * 0.10)
  local bp = bandpass(rand(300, 500), 1.5)
  local f = rand(150, 210)
  local phase = 0
  local buf = {}
  for i = 0, n - 1 do
    local t = i / SAMPLE_RATE
    local fr = f * (1 + 0.8 * math.exp(-t / 0.012))   -- ピッチが下がる
    phase = phase + 2 * pi * fr / SAMPLE_RATE
    local noise = love.math.random() * 2 - 1
    local fade = math.min(1, (n - 1 - i) / 100)
    buf[i] = (math.sin(phase) * math.exp(-t / 0.025)
             + bp(noise) * 0.5 * math.exp(-t / 0.012)) * fade
  end
  return toSource(buf, n, 0.7)
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

local function playStretch(hard)
  local s = stretchSrc[love.math.random(#stretchSrc)]:clone()
  s:setPitch(rand(0.85, 1.15))
  s:setVolume(hard and rand(0.5, 0.8) or rand(0.3, 0.5))
  s:play()
end

local function playSpring(amount)
  local s = springSrc[love.math.random(#springSrc)]:clone()
  s:setPitch(rand(0.9, 1.1))
  s:setVolume(math.min(1, 0.3 + 0.6 * amount))
  s:play()
end

local function playPop(b)
  local v = variants[b.snd]
  local src = v.src:clone()          -- 重ねて鳴らせるようにクローン
  src:setPitch(rand(0.85, 1.05))
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
        -- 粒ごとの「潰れにくさ」。伸びる粒は素早いなぞりでは潰れない
        thresh = hard and rand(1.2, 1.8) or rand(0.6, 1.1),
        hard = hard,
        speed = rand(0.7, 1.3),                    -- 粒ごとの押し込み速度の個体差
        seed = rand(0, 100),                       -- 押し込み速度の時間変化用
        held = false, stretched = false,
        wobA = 0, wobT = 10,                       -- 離したときの揺れ
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
    local size = 0.1 + (i - 1) / (NUM_VARIANTS - 1) * 0.5   -- ステージ1は小〜中粒
    variants[i] = { src = makePop(size), size = size }
  end
  creak = makeCreak()
  for i = 1, 3 do
    stretchSrc[i] = makeStretch()
    springSrc[i] = makeSpring()
  end
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
  -- → 潰れる粒と潰れない粒ができる
  if target ~= lastTarget then
    if target and not target.popped then
      target.press = target.press + rand(0.2, 0.7)
      playCreak()
    end
    lastTarget = target
  end

  local now = love.timer.getTime()
  for _, b in ipairs(bubbles) do
    if not b.popped then
      if b == target then
        b.held = true
        -- 押し込み速度は粒ごとに違い、しかも時間とともに滑らかに揺らぐ
        local wave = 0.55 + 0.9 * love.math.noise(b.seed, now * 3)
        b.press = b.press + dt / PRESS_TIME * b.speed * wave
        if b.press >= b.thresh then
          pop(b)
        elseif b.press / b.thresh > 0.7 and not b.stretched then
          b.stretched = true                               -- 素材が伸び切る手前
          if b.hard or love.math.random() < 0.35 then playStretch(b.hard) end
        end
      else
        if b.held then                                     -- 指を離した瞬間
          b.held = false
          local p = math.min(1, b.press / b.thresh)
          if p > 0.35 then
            playSpring(p)                                  -- 空気が戻る「ポコッ」
            b.wobA, b.wobT = p, 0                          -- 揺れ
          end
        end
        b.press = math.max(0, b.press - dt / RELEASE_TIME) -- 離すと戻る
        if b.press / b.thresh < 0.4 then b.stretched = false end
      end
      b.wobT = b.wobT + dt
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
  local hk = b.hard and 1.6 or 1.0                -- 伸びる粒ほど大きく変形する
  local s = 0.18 * hk * p                         -- 押しつぶされた量
  local wob = b.wobA * 0.10 * math.sin(b.wobT * 38) * math.exp(-b.wobT * 9)
  local rx = 1 + 0.6 * s - wob * 0.6              -- 空気が横へ逃げて横に広がり
  local ry = 1 - s + wob                          -- 縦につぶれる
  local tn = b.tint
  local r = b.rad

  love.graphics.push()
  love.graphics.translate(b.x, b.y)
  love.graphics.scale(rx, ry)

  love.graphics.setColor(0, 0.1, 0.2, 0.14)                     -- 影
  love.graphics.circle("fill", r * 0.12, r * 0.18, r)
  love.graphics.setColor(0.75 + tn, 0.9 + tn, 1, 0.34 + 0.10 * p)  -- 本体(張るほど濃く)
  love.graphics.circle("fill", 0, 0, r)
  love.graphics.setColor(0.35, 0.6, 0.85, 0.28)                 -- 右下の厚みのある陰
  love.graphics.setLineWidth(r * 0.14)
  love.graphics.arc("line", "open", 0, 0, r * 0.86, -0.1, 1.6)
  love.graphics.setColor(0.5, 0.75, 0.95, 0.8)                  -- 縁
  love.graphics.setLineWidth(1.5)
  love.graphics.circle("line", 0, 0, r)
  love.graphics.setColor(1, 1, 1, 0.9 - 0.55 * p)               -- ハイライト
  love.graphics.ellipse("fill", -r * 0.3, -r * 0.35, r * 0.28, r * 0.16)
  love.graphics.setColor(1, 1, 1, 0.5 - 0.3 * p)                -- 小さな2つ目のハイライト
  love.graphics.circle("fill", r * 0.35, r * 0.4, r * 0.06)
  love.graphics.setColor(1, 1, 1, 0.22)                         -- 反射光
  love.graphics.arc("fill", 0, 0, r * 0.8, 0.2, 1.0)

  local sa = math.max(0, p - 0.5) * 2 * (b.hard and 0.45 or 0.25)
  if sa > 0 then                                                -- 素材が引き伸ばされた筋
    love.graphics.setColor(1, 1, 1, sa)
    love.graphics.setLineWidth(1)
    for i = 1, 6 do
      local a = b.seed + i * pi / 3
      love.graphics.line(math.cos(a) * r * 0.45, math.sin(a) * r * 0.45,
                         math.cos(a) * r * 0.88, math.sin(a) * r * 0.88)
    end
  end

  love.graphics.pop()
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
