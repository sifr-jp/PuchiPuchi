-- Puchipuchi v0.4: bubble wrap popping game (LÖVE 11.x)
-- v0.2: 行数の自動決定 / 潰れにくさの個体差 / フィルム素材感のある音と描画
-- v0.3: 手応えを重く+押し込み速度のランダム変化 / 伸びて潰れない粒 / ミチミチ・ポコッ音
-- v0.4: なぞり速度で力が変わる / 粒から粒への勢いの持ち越し / ポコッを遅らせる /
--       ビニール感(フィルムの反射・重なり) / 破裂音に重厚感(低音・サブ帯域・軽い歪み)
-- v0.5: 破裂音を6種類に(通常/鋭い/深い/二段/プシュ/こもり)。同じ音が続けて鳴らないようにした
-- v0.6: シートを長方形に切り出し、縁の空きを半割の粒で埋める(破裂しない)。カッターで切った縁の表現

local pi = math.pi
local SAMPLE_RATE = 44100
local COLS = 8
local NUM_VARIANTS = 24        -- 破裂音のバリエーション数(6種類の音を混ぜる)
local PRESS_TIME = 0.30      -- 押し込みから破裂までの目安(秒)。大きいほど重い
local RELEASE_TIME = 0.25    -- 離したときに元に戻るまでの時間(秒)
local HARD_RATIO = 0.25      -- 「伸びて潰れにくい粒」の割合
local SOUND_WEIGHT = 1.6     -- 破裂音の低音の重み。大きいほど重厚、小さいほど軽い
local SWIPE_FAST = 12        -- 「速いなぞり」の基準(粒/秒)。大きいほど速くても深く入る
local SPRING_DELAY_MIN = 0.09  -- 「ポコッ」を指を離してから鳴らすまでの遅れ(秒)
local SPRING_DELAY_MAX = 0.17
local CARRY_MAX_GAP = 0.30   -- この時間(秒)以内に次の粒へ移ると、勢いが持ち越される
local TOP, MARGIN = 60, 16
local MAX_CELL = 64          -- 粒1つ分の最大サイズ(px)

local rows = 13
local bubbles, variants = {}, {}
local stretchSrc, springSrc = {}, {}
local sheet = { x = 0, y = 0, w = 0, h = 0, sheen = {}, creases = {}, wob = {} }
local popped, total = 0, 0
local cell = 40
local creak, creakAt, springAt = nil, -1, -1
local lastTarget = nil
local lastPopIdx = nil                       -- 直前に鳴らした破裂音(連続を避ける)
local pending = {}                           -- 遅らせて鳴らす音のキュー
local mx0, my0, mspeed = nil, nil, 0         -- マウス移動速度(px/秒, 平滑化)
local leftAt, leftP, leftDwell = -1, 0, 0    -- 直前に離れた粒の記録(勢いの持ち越し用)

local function rand(a, b) return a + (b - a) * love.math.random() end
local function later(delay, fn) pending[#pending + 1] = { t = delay, fn = fn } end

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
-- 破裂音の種類。粒ごとに違う「プチッ」を出すため、構造の違う音を複数用意する
--   w: 出現の重み  level: 音量  dur: 長さ(秒)
--   crack/air/thick/film/thump/sub/crinkle/tear: 各成分の量
--   bright: 高域の周波数倍率  tau: 余韻の長さ倍率
--   double: 2段階で裂ける  hiss: 空気がゆっくり漏れる  dull: こもり具合(0.1〜0.3)
--   sizeMin/sizeMax: 粒の大きさ(0=小さく高い音, 1=大きく低い音)
---------------------------------------------------------------
local POP_KINDS = {
  normal = { w = 4, level = 0.88, dur = 0.30, crack = 0.8, air = 0.9, thick = 0.9, film = 0.6,
             thump = 1.0, sub = 1.0, crinkle = 3.5, tear = 0.5, bright = 1.0, tau = 1.0,
             sizeMin = 0.10, sizeMax = 0.55 },                       -- 標準の「プチッ」
  sharp  = { w = 3, level = 0.80, dur = 0.22, crack = 1.3, air = 0.5, thick = 0.3, film = 1.2,
             thump = 0.4, sub = 0.25, crinkle = 3.0, tear = 1.1, bright = 1.25, tau = 0.6,
             sizeMin = 0.00, sizeMax = 0.25 },                       -- 薄い膜の高く鋭い「パチッ」
  deep   = { w = 2, level = 0.90, dur = 0.36, crack = 0.6, air = 1.0, thick = 1.4, film = 0.35,
             thump = 1.4, sub = 1.5, crinkle = 1.5, tear = 0.2, bright = 0.8, tau = 1.5,
             sizeMin = 0.45, sizeMax = 0.75 },                       -- 大きく重い「ボスッ」
  double = { w = 2, level = 0.88, dur = 0.32, crack = 0.8, air = 0.9, thick = 0.8, film = 0.7,
             thump = 0.9, sub = 0.8, crinkle = 3.5, tear = 0.6, bright = 1.05, tau = 0.9,
             double = true, sizeMin = 0.10, sizeMax = 0.50 },        -- 2段階で裂ける「プチッ・ピッ」
  hiss   = { w = 1, level = 0.78, dur = 0.38, crack = 0.7, air = 0.7, thick = 0.6, film = 0.5,
             thump = 0.6, sub = 0.5, crinkle = 2.0, tear = 0.4, bright = 1.0, tau = 1.0,
             hiss = 3.5, sizeMin = 0.15, sizeMax = 0.50 },           -- 空気が漏れる「プシュッ」
  dull   = { w = 2, level = 0.82, dur = 0.28, crack = 0.4, air = 1.1, thick = 1.1, film = 0.15,
             thump = 1.0, sub = 1.0, crinkle = 1.0, tear = 0.0, bright = 0.9, tau = 1.1,
             dull = 0.16, sizeMin = 0.15, sizeMax = 0.60 },          -- こもった「ポフッ」
}
local POP_ORDER = { "normal", "sharp", "deep", "double", "hiss", "dull" }

---------------------------------------------------------------
-- 破裂音: クリック + 空気の胴鳴り + 低い胴鳴り + サブ(100Hz台) + フィルムの張り
--         + しわしわ + 膜が裂ける高音(ペリッ)  ※成分の量は種類(kind)ごとに変わる
-- size: 0(小粒・高い音) 〜 1(大粒・低い音)
---------------------------------------------------------------
local function makePop(size, kind)
  local K = POP_KINDS[kind]
  local n = math.floor(SAMPLE_RATE * K.dur)
  local body = bandpass(rand(750, 1200) - size * 400, 1.6)   -- 空気が抜ける胴鳴り
  local deep = bandpass(rand(260, 400) - size * 80, 1.2)     -- 低い胴鳴り(重み)
  local skin = bandpass((rand(2800, 4200) - size * 1000) * K.bright, 1.2)  -- フィルムの張り
  local ripple = bandpass(rand(2500, 6000), 2.0)             -- しわのカサカサ
  local tear = bandpass(math.min(9000, rand(5000, 7500) * K.bright), 1.5)  -- 膜が裂ける「ペリッ」
  local body2 = bandpass(rand(900, 1400), 1.6)               -- 2段目の胴鳴り(double用)
  local skin2 = bandpass(rand(3500, 5200), 1.2)              -- 2段目の張り(double用)
  local hissBp = bandpass(rand(2500, 4500), 0.9)             -- 漏れる空気(hiss用)
  local tauBody = (0.014 + size * 0.010) * K.tau
  local tauDeep = (0.050 + size * 0.020) * K.tau             -- 低音を長く残す
  local tauSkin = (0.007 + size * 0.005) * K.tau
  local lowF = 175 - 70 * size
  local subF = 105 - 35 * size                               -- 「ドスッ」のサブ成分
  local tauSub = (0.030 + size * 0.015) * K.tau
  local crkTau = 0.030 + size * 0.020
  local crkRate = rand(900, 1500)      -- しわクリックの発生頻度(1/秒)。時間とともに減る
  local td = K.double and rand(0.014, 0.034) or 1e9          -- 2段目が裂けるまでの時間
  local lp, dl = 0, 0
  local buf = {}

  for i = 0, n - 1 do
    local t = i / SAMPLE_RATE
    local noise = love.math.random() * 2 - 1
    lp = lp + 0.5 * (noise - lp)
    local hf = noise - lp
    local crack = hf * math.exp(-t / 0.0004) * 1.5
    local air = body(noise) * math.exp(-t / tauBody) * 3.0
    local thick = deep(noise) * math.exp(-t / tauDeep) * 5.0 * SOUND_WEIGHT
    local film = skin(noise) * math.exp(-t / tauSkin) * 1.4
    local thump = math.sin(2 * pi * lowF * t) * math.exp(-t / 0.010) * 0.6 * SOUND_WEIGHT
    local sub = math.sin(2 * pi * subF * t) * math.exp(-t / tauSub) * 0.9 * SOUND_WEIGHT
    local tearS = tear(noise) * math.exp(-t / 0.006) * 1.2

    local imp = 0                                                       -- まばらな小さな衝撃
    if love.math.random() < crkRate * math.exp(-t / crkTau) / SAMPLE_RATE then
      imp = (love.math.random() * 2 - 1) * rand(0.4, 1.0)
    end
    local crinkle = ripple(imp) * 4

    local s = crack * K.crack + air * K.air + thick * K.thick + film * K.film
            + thump * K.thump + sub * K.sub + crinkle * K.crinkle + tearS * K.tear

    if t >= td then                                                     -- 2段目の小さな破裂
      local t2 = t - td
      s = s + (hf * math.exp(-t2 / 0.0005) * 1.1
             + body2(noise) * math.exp(-t2 / 0.012) * 2.0
             + skin2(noise) * math.exp(-t2 / 0.006) * 1.0) * 0.7
    end
    if K.hiss then                                                      -- 空気がゆっくり漏れる
      s = s + hissBp(noise) * math.min(1, t / 0.008) * math.exp(-t / 0.10) * K.hiss
    end
    if K.dull then                                                      -- こもらせる(ローパス)
      dl = dl + K.dull * (s - dl)
      s = dl
    end

    local d = s * 0.8                                                   -- 軽い飽和で密度を出す
    local fade = math.min(1, (n - 1 - i) / 200)                         -- 末尾のプチノイズ防止
    buf[i] = (d / (1 + math.abs(d))) * fade
  end
  return { src = toSource(buf, n, K.level), size = size, kind = kind }
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

-- 伸びた素材が戻って空気が戻る「ポコッ」。v0.3より低く、ピッチの下がり方をゆっくりに
local function makeSpring()
  local n = math.floor(SAMPLE_RATE * 0.16)
  local bp = bandpass(rand(260, 420), 1.5)
  local f = rand(120, 175)
  local phase = 0
  local buf = {}
  for i = 0, n - 1 do
    local t = i / SAMPLE_RATE
    local fr = f * (1 + 0.9 * math.exp(-t / 0.035))   -- ピッチが下がる(ゆっくり)
    phase = phase + 2 * pi * fr / SAMPLE_RATE
    local noise = love.math.random() * 2 - 1
    local fade = math.min(1, (n - 1 - i) / 100)
    buf[i] = (math.sin(phase) * math.exp(-t / 0.045)
             + bp(noise) * 0.5 * math.exp(-t / 0.018)) * fade
  end
  return toSource(buf, n, 0.7)
end

local function playCreak(vol)
  local now = love.timer.getTime()
  if now - creakAt < 0.05 then return end     -- 鳴らしすぎ防止
  creakAt = now
  local s = creak:clone()
  s:setPitch(rand(0.85, 1.25))
  s:setVolume(rand(0.25, 0.45) * (vol or 1))
  s:play()
end

local function playStretch(hard)
  local s = stretchSrc[love.math.random(#stretchSrc)]:clone()
  s:setPitch(rand(0.85, 1.15))
  s:setVolume(hard and rand(0.5, 0.8) or rand(0.3, 0.5))
  s:play()
end

local function playSpring(amount)
  local now = love.timer.getTime()
  if now - springAt < 0.08 then return end    -- 連続で潰したときに鳴りすぎないように
  springAt = now
  local s = springSrc[love.math.random(#springSrc)]:clone()
  s:setPitch(rand(0.9, 1.1))
  s:setVolume(math.min(1, 0.3 + 0.6 * amount))
  s:play()
end

local function playPop(b)
  local idx = b.snd
  if idx == lastPopIdx then idx = idx % NUM_VARIANTS + 1 end   -- 同じ音が続けて鳴らないように
  lastPopIdx = idx
  local v = variants[idx]
  local src = v.src:clone()          -- 重ねて鳴らせるようにクローン
  src:setPitch(rand(0.82, 1.10))
  src:setVolume(rand(0.7, 1.0))
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
  cell = math.min((W - 2 * MARGIN) / COLS, MAX_CELL)   -- シートの幅 = 粒COLS個分(半割の粒が縁を埋める)
  local y1 = H - MARGIN                                 -- シート下端(ここで切る)
  -- 下端に少しでも見える行まで作る。下端にかかる行は半割になる
  rows = math.max(1, math.ceil((y1 - TOP - 0.19 * cell) / (cell * 0.87)))
end

-- カッターの縁の手ぶれ。一定間隔ごとの小さなずれ(時々刃が引っ掛かる)
local function makeWob(len)
  local n = math.max(2, math.ceil(len / 12) + 1)
  local w = {}
  for i = 1, n do
    local o = rand(-0.5, 0.5)
    if love.math.random() < 0.08 then o = o + rand(-1.2, 1.2) end
    w[i] = o
  end
  return w
end

local function layout()
  local W, H = love.graphics.getDimensions()
  local ox = (W - COLS * cell) / 2
  for _, b in ipairs(bubbles) do
    local off = (b.r % 2 == 0) and 0.5 or 0        -- 千鳥配置
    b.x = ox + (b.c - 1 + 0.5 + off) * cell
    b.y = TOP + cell * 0.5 + (b.r - 1) * cell * 0.87
    b.rad = cell * 0.46 * b.sz
  end
  sheet.x = math.floor(ox + 0.5)
  sheet.y = math.floor(TOP - 0.10 * cell + 0.5)
  sheet.w = math.floor(COLS * cell + 0.5)
  sheet.h = math.floor(H - MARGIN + 0.5) - sheet.y
  local x0, y0 = sheet.x, sheet.y
  local x1, y1 = x0 + sheet.w, y0 + sheet.h
  for _, b in ipairs(bubbles) do
    -- シートの縁で切れている粒は半割。押されて凹むだけで、破裂しない
    b.cut = (b.x - b.rad < x0 - 0.5) or (b.x + b.rad > x1 + 0.5) or (b.y + b.rad > y1 + 0.5)
    if b.cut then b.hard, b.thresh = false, 1.0 end
  end
  sheet.wob = { top = makeWob(sheet.w), bottom = makeWob(sheet.w),
                left = makeWob(sheet.h), right = makeWob(sheet.h) }
end

local function newSheet()
  calcRows()
  bubbles = {}
  pending = {}
  for r = 1, rows do
    local c0 = (r % 2 == 0) and 0 or 1              -- 偶数行は両端(c=0, c=COLS)に半割の粒が入る
    for c = c0, COLS do
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
        dwell = 0,                                 -- 今回の接触で押し続けた時間
        wobA = 0, wobT = 10,                       -- 離したときの揺れ
        popped = false, t = 0,
        snd = love.math.random(NUM_VARIANTS),
        sz = rand(0.97, 1.03),                     -- 大きさの個体差
        tint = rand(-0.03, 0.03),                  -- 色味の個体差
        hx = rand(-0.35, 0.35), hy = rand(-0.35, 0.35),  -- 破裂後の穴の位置
        wr = {},                                   -- 破裂後のしわ(少なめ・太め・柔らかく)
      }
      for i = 1, 5 do
        local a, d = rand(0, 2 * pi), rand(0.1, 0.7)
        local x1, y1 = math.cos(a) * d, math.sin(a) * d
        b.wr[i] = { x1, y1, x1 + rand(-0.4, 0.4), y1 + rand(-0.4, 0.4) }
      end
      bubbles[#bubbles + 1] = b
    end
  end
  sheet.sheen = {}                                 -- フィルム面のうっすらした筋
  for i = 1, 10 do
    sheet.sheen[i] = { rand(0, 1), rand(0, 1), rand(0, 1), rand(0, 1) }
  end
  sheet.creases = {}                               -- 長くて柔らかいしわ(ビニールの折れ)
  for i = 1, 5 do
    local y1 = rand(0, 1)
    sheet.creases[i] = { 0, y1, 1, y1 + rand(-0.25, 0.25), rand(0.05, 0.11) }
  end
  lastTarget = nil
  leftAt = -1
  layout()
  popped, total = 0, 0                             -- 半割の粒は数えない
  for _, b in ipairs(bubbles) do
    if not b.cut then total = total + 1 end
  end
end

local function hit(mx, my)
  if mx < sheet.x or mx > sheet.x + sheet.w or my < sheet.y or my > sheet.y + sheet.h then
    return nil                                     -- 切り落とされた部分は触れない
  end
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
  local wsum = 0
  for _, k in ipairs(POP_ORDER) do wsum = wsum + POP_KINDS[k].w end
  local function pickKind()                                 -- 重みに応じて種類を選ぶ
    local r = love.math.random() * wsum
    for _, k in ipairs(POP_ORDER) do
      r = r - POP_KINDS[k].w
      if r <= 0 then return k end
    end
    return POP_ORDER[1]
  end
  for i = 1, NUM_VARIANTS do
    local kind = POP_ORDER[i] or pickKind()                 -- 最初の6個は全種類を必ず入れる
    local K = POP_KINDS[kind]
    variants[i] = makePop(rand(K.sizeMin, K.sizeMax), kind)
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
    b.dwell = 0
    lastTarget = b
    playCreak(b.cut and 0.3 or 1)
  end
end

function love.keypressed(key)
  if key == "r" then newSheet() end
  if key == "escape" then love.event.quit() end
end

function love.update(dt)
  local now = love.timer.getTime()
  local mx, my = love.mouse.getPosition()
  local down = love.mouse.isDown(1)

  -- マウス移動速度(平滑化)。なぞりの速さで粒に入る力を変えるために使う
  if down and mx0 then
    local dx, dy = mx - mx0, my - my0
    local inst = math.sqrt(dx * dx + dy * dy) / math.max(dt, 1e-4)
    mspeed = mspeed + (inst - mspeed) * math.min(1, dt * 10)
  else
    mspeed = 0
  end
  mx0, my0 = mx, my

  -- 遅らせて鳴らす音
  for i = #pending, 1, -1 do
    local p = pending[i]
    p.t = p.t - dt
    if p.t <= 0 then
      table.remove(pending, i)
      p.fn()
    end
  end

  local target
  if down then target = hit(mx, my) end

  -- なぞって別の粒に入ったとき
  --  ・ゆっくりなぞるほど深く入り、速いほど浅く触れるだけ
  --  ・直前の粒での張り具合と滞在時間が、勢いとして次の粒に持ち越される
  if target ~= lastTarget then
    local prev = lastTarget
    if prev then
      leftAt = now
      leftP = prev.popped and 0.5 or math.min(1, prev.press / prev.thresh)
      leftDwell = prev.dwell
    end
    if target and not target.popped then
      local slow = 1 - math.min(1, mspeed / (cell * SWIPE_FAST))
      local force = (0.08 + 0.55 * slow) * rand(0.6, 1.3)
      local gap = now - leftAt
      if gap < CARRY_MAX_GAP then
        local carry = leftP * 0.3 + math.min(leftDwell, 0.6) * 0.3
        force = force + carry * (1 - gap / CARRY_MAX_GAP) * rand(0.7, 1.2)
      end
      target.press = target.press + force
      target.dwell = 0
      playCreak(target.cut and 0.3 or (0.5 + 0.5 * slow))
    end
    lastTarget = target
  end

  for _, b in ipairs(bubbles) do
    if b.cut then                                      -- 半割の粒: 押されて凹むだけで破裂しない
      if b == target then
        b.press = math.min(0.45, b.press + dt / PRESS_TIME * 0.6)
      else
        b.press = math.max(0, b.press - dt / RELEASE_TIME)
      end
    elseif not b.popped then
      if b == target then
        b.held = true
        b.dwell = b.dwell + dt
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
            -- 空気が戻る「ポコッ」は少し遅れて鳴る。揺れも同じタイミングで始める
            later(rand(SPRING_DELAY_MIN, SPRING_DELAY_MAX), function()
              if not b.popped then
                playSpring(p)
                b.wobA, b.wobT = p, 0
              end
            end)
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
  love.graphics.setColor(0, 0.1, 0.2, 0.10)                      -- シートの影(厚みの表現)
  love.graphics.rectangle("fill", sheet.x + 2, sheet.y + 3, sheet.w, sheet.h)
  love.graphics.setColor(1, 1, 1, 0.38)                          -- 平らなフィルム面
  love.graphics.rectangle("fill", sheet.x, sheet.y, sheet.w, sheet.h)
end

-- 粒の上に重ねるフィルムの反射。マウスの位置で光の帯が動く
local function drawFilm()
  love.graphics.setScissor(sheet.x, sheet.y, sheet.w, sheet.h)

  local W = love.graphics.getWidth()
  local mxr = math.max(0, math.min(1, love.mouse.getX() / W))
  local skew = sheet.h * 0.35
  local bw = sheet.w * 0.16
  local gx = sheet.x + sheet.w * (0.1 + 0.9 * mxr)
  love.graphics.setColor(1, 1, 1, 0.10)                          -- 太い光の帯
  love.graphics.polygon("fill", gx, sheet.y, gx + bw, sheet.y,
                        gx + bw - skew, sheet.y + sheet.h, gx - skew, sheet.y + sheet.h)
  local gx2 = gx + bw * 1.6
  love.graphics.setColor(1, 1, 1, 0.06)                          -- 細い光の帯
  love.graphics.polygon("fill", gx2, sheet.y, gx2 + bw * 0.3, sheet.y,
                        gx2 + bw * 0.3 - skew, sheet.y + sheet.h, gx2 - skew, sheet.y + sheet.h)

  love.graphics.setLineWidth(1)
  love.graphics.setColor(1, 1, 1, 0.14)                          -- うっすらした光の筋
  for _, s in ipairs(sheet.sheen) do
    love.graphics.line(sheet.x + s[1] * sheet.w, sheet.y + s[2] * sheet.h,
                       sheet.x + s[3] * sheet.w, sheet.y + s[4] * sheet.h)
  end
  love.graphics.setLineWidth(3)                                  -- ビニールの折れ(長く柔らかい)
  for _, c in ipairs(sheet.creases) do
    love.graphics.setColor(1, 1, 1, c[5])
    love.graphics.line(sheet.x + c[1] * sheet.w, sheet.y + c[2] * sheet.h,
                       sheet.x + c[3] * sheet.w, sheet.y + c[4] * sheet.h)
  end

  love.graphics.setScissor()
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
  love.graphics.setColor(0.75 + tn, 0.9 + tn, 1, 0.30 + 0.10 * p)  -- 本体(張るほど濃く)
  love.graphics.circle("fill", 0, 0, r)
  if b.cut then                                                 -- 切り開かれたドームの内側
    love.graphics.setColor(0.35, 0.55, 0.8, 0.10)
    love.graphics.circle("fill", 0, 0, r * 0.92)
  end
  love.graphics.setColor(0.35, 0.6, 0.85, 0.28)                 -- 右下の厚みのある陰
  love.graphics.setLineWidth(r * 0.14)
  love.graphics.arc("line", "open", 0, 0, r * 0.86, -0.1, 1.6)
  love.graphics.setColor(0.5, 0.75, 0.95, 0.22)                 -- 内側の縁(透明な膜の厚み)
  love.graphics.setLineWidth(1)
  love.graphics.circle("line", 0, 0, r * 0.74)
  love.graphics.setColor(0.5, 0.75, 0.95, 0.8)                  -- 縁
  love.graphics.setLineWidth(1.5)
  love.graphics.circle("line", 0, 0, r)
  love.graphics.setColor(1, 1, 1, 0.10)                         -- 広く柔らかい光沢
  love.graphics.circle("fill", -r * 0.2, -r * 0.25, r * 0.55)
  love.graphics.setColor(1, 1, 1, 0.70 - 0.45 * p)              -- ハイライト(伸びるほど横に歪む)
  love.graphics.ellipse("fill", -r * 0.3, -r * 0.35, r * (0.26 + 0.16 * p * hk), r * 0.14)
  love.graphics.setColor(1, 1, 1, 0.45 - 0.25 * p)              -- 小さな2つ目のハイライト
  love.graphics.circle("fill", r * 0.35, r * 0.4, r * 0.06)
  love.graphics.setColor(1, 1, 1, 0.18)                         -- 反射光
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
  love.graphics.setLineWidth(2)
  for _, w in ipairs(b.wr) do                                   -- しわ(太めで淡く、柔らかく)
    love.graphics.setColor(1, 1, 1, 0.40)
    love.graphics.line(b.x + w[1] * r, b.y + w[2] * r, b.x + w[3] * r, b.y + w[4] * r)
    love.graphics.setColor(0.4, 0.6, 0.8, 0.22)
    love.graphics.line(b.x + w[1] * r + 1.5, b.y + w[2] * r + 1.5,
                       b.x + w[3] * r + 1.5, b.y + w[4] * r + 1.5)
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

-- 縁に沿って、手ぶれのある折れ線を引く(horizontal: 水平の縁か, off: 外側へのずらし量)
local function wobLine(x0, y0, x1, y1, wob, horizontal, off)
  local n = #wob
  local pts = {}
  for i = 1, n do
    local f = (i - 1) / (n - 1)
    local x = x0 + (x1 - x0) * f
    local y = y0 + (y1 - y0) * f
    local o = wob[i] + off
    if horizontal then y = y + o else x = x + o end
    pts[#pts + 1] = x
    pts[#pts + 1] = y
  end
  love.graphics.line(pts)
end

-- カッターで切った縁: 切り口が光を拾う明るい線、外側の薄い影、刃で押されたフィルムの筋
local function drawCutEdges()
  local x0, y0, w, h = sheet.x, sheet.y, sheet.w, sheet.h
  local x1, y1 = x0 + w, y0 + h
  local wb = sheet.wob
  love.graphics.setLineWidth(1)
  love.graphics.setColor(1, 1, 1, 0.10)                          -- 押されたフィルムの筋(内側)
  love.graphics.rectangle("line", x0 + 3.5, y0 + 3.5, w - 7, h - 7)
  love.graphics.setColor(0.35, 0.5, 0.7, 0.55)                   -- 外側の影(切り口の厚み)
  wobLine(x0, y0, x1, y0, wb.top, true, -1)
  wobLine(x0, y1, x1, y1, wb.bottom, true, 1)
  wobLine(x0, y0, x0, y1, wb.left, false, -1)
  wobLine(x1, y0, x1, y1, wb.right, false, 1)
  love.graphics.setLineWidth(1.2)
  love.graphics.setColor(1, 1, 1, 0.95)                          -- 切り口の明るい線
  wobLine(x0, y0, x1, y0, wb.top, true, 0)
  wobLine(x0, y1, x1, y1, wb.bottom, true, 0)
  wobLine(x0, y0, x0, y1, wb.left, false, 0)
  wobLine(x1, y0, x1, y1, wb.right, false, 0)
end

function love.draw()
  drawSheet()
  love.graphics.setScissor(sheet.x, sheet.y, sheet.w, sheet.h)   -- 縁の外にはみ出した粒を切り落とす
  for _, b in ipairs(bubbles) do
    if b.popped then drawPopped(b) else drawIntact(b) end
  end
  love.graphics.setScissor()
  drawFilm()
  drawCutEdges()
  love.graphics.setColor(0.2, 0.3, 0.4)
  love.graphics.print(string.format("%d / %d   [R] reset", popped, total), 16, 20)
  if popped == total then
    love.graphics.printf("All popped! Tap to start again", 0, 24,
                         love.graphics.getWidth(), "center")
  end
end
