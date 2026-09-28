-- sound.lua: ぷちぷちの音(すべてコードで合成するので音声ファイルは不要)
-- 使い方: Sound.init() を love.load で1回呼び、あとは Sound.playXxx() を呼ぶ

local pi = math.pi
local SAMPLE_RATE = 44100
local SOUND_WEIGHT = 1.6     -- 破裂音の低音の重み。大きいほど重厚、小さいほど軽い
local NUM_VARIANTS = 24      -- 破裂音のバリエーション数(6種類の音を混ぜる)

local Sound = { NUM_VARIANTS = NUM_VARIANTS }

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


local variants, stretchSrc, springSrc = {}, {}, {}
local creak = nil
local creakAt, springAt, lastPopIdx = -1, -1, nil

-- 起動時に音を合成する(love.math.setRandomSeed のあとに呼ぶ)
function Sound.init()
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
end

function Sound.playCreak(vol)
  local now = love.timer.getTime()
  if now - creakAt < 0.05 then return end     -- 鳴らしすぎ防止
  creakAt = now
  local s = creak:clone()
  s:setPitch(rand(0.85, 1.25))
  s:setVolume(rand(0.25, 0.45) * (vol or 1))
  s:play()
end

function Sound.playStretch(hard)
  local s = stretchSrc[love.math.random(#stretchSrc)]:clone()
  s:setPitch(rand(0.85, 1.15))
  s:setVolume(hard and rand(0.5, 0.8) or rand(0.3, 0.5))
  s:play()
end

function Sound.playSpring(amount)
  local now = love.timer.getTime()
  if now - springAt < 0.08 then return end    -- 連続で潰したときに鳴りすぎないように
  springAt = now
  local s = springSrc[love.math.random(#springSrc)]:clone()
  s:setPitch(rand(0.9, 1.1))
  s:setVolume(math.min(1, 0.3 + 0.6 * amount))
  s:play()
end

-- idx: 粒に割り当てた破裂音の番号(1〜NUM_VARIANTS)。振動も一緒に鳴らす
function Sound.playPop(idx)
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

return Sound
