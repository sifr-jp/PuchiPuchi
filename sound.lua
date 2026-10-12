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

-- 潰れなかったときに、たまに鳴るコミカルな「ボヨーン」(震えながら間延びして戻る)
local function makeBoyoon()
  local n = math.floor(SAMPLE_RATE * 0.38)
  local bp = bandpass(rand(480, 680), 1.3)
  local f0 = rand(230, 290)
  local vibHz = rand(13, 17)        -- 震える速さ
  local vibDepth = rand(0.32, 0.48) -- 震えの深さ(大きいほどコミカル)
  local phase = 0
  local buf = {}
  for i = 0, n - 1 do
    local t = i / SAMPLE_RATE
    local env = math.exp(-t / 0.15)
    local vib = 1 + vibDepth * math.exp(-t / 0.11) * math.sin(2 * pi * vibHz * t)
    local fr = f0 * vib
    phase = phase + 2 * pi * fr / SAMPLE_RATE
    local noise = love.math.random() * 2 - 1
    local fade = math.min(1, (n - 1 - i) / 300)
    buf[i] = (math.sin(phase) * env + bp(noise) * 0.22 * math.exp(-t / 0.03)) * fade
  end
  return toSource(buf, n, 0.95)
end

local variants, stretchSrc, springSrc, boyoonSrc = {}, {}, {}, {}
local creak = nil
local creakAt, springAt, lastPopIdx = -1, -1, nil
local pitchScale = 1     -- 音の高さの倍率(ステージごとに変える。大粒は低く、小粒は高く)

function Sound.setPitchScale(k)
  pitchScale = k or 1
end

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
    boyoonSrc[i] = makeBoyoon()
  end
end

function Sound.playCreak(vol)
  local now = love.timer.getTime()
  if now - creakAt < 0.05 then return end     -- 鳴らしすぎ防止
  creakAt = now
  local s = creak:clone()
  s:setPitch(rand(0.85, 1.25) * pitchScale)
  s:setVolume(rand(0.25, 0.45) * (vol or 1))
  s:play()
end

function Sound.playStretch(hard)
  local s = stretchSrc[love.math.random(#stretchSrc)]:clone()
  s:setPitch(rand(0.85, 1.15) * pitchScale)
  s:setVolume(hard and rand(0.5, 0.8) or rand(0.3, 0.5))
  s:play()
end

function Sound.playSpring(amount)
  local now = love.timer.getTime()
  if now - springAt < 0.08 then return end    -- 連続で潰したときに鳴りすぎないように
  springAt = now
  local s = springSrc[love.math.random(#springSrc)]:clone()
  s:setPitch(rand(0.9, 1.1) * pitchScale)
  s:setVolume(math.min(1, 0.3 + 0.6 * amount))
  s:play()
end

local boyoonAt = -1
-- 潰れずに戻るときに、たまに鳴らすコミカルな「ボヨーン」。playSpringの代わりに呼ぶ
-- ステージごとのピッチ差(大粒=低い/小粒=高い)をそのまま使うと小粒ステージで薄く聞き取りにくくなるため、
-- 差を弱めて低めの音域を保ち、どのステージでも同じくらいはっきり聞こえるようにする
function Sound.playBoyoon(amount)
  local now = love.timer.getTime()
  if now - boyoonAt < 0.10 then return end    -- 同じ粒を押し続けている間だけ連続再生を防ぐ(触れるたびに必ず鳴らしたい)
  boyoonAt = now
  local s = boyoonSrc[love.math.random(#boyoonSrc)]:clone()
  local ps = 0.6 + 0.4 * pitchScale
  s:setPitch(rand(0.85, 1.15) * ps)
  s:setVolume(rand(0.92, 1.0))        -- amount(押し込み量)に左右されず、毎回はっきり聞こえる音量にする
  s:play()
end

-- idx: 粒に割り当てた破裂音の番号(1〜NUM_VARIANTS)。振動も一緒に鳴らす
-- pitch: 省略可。指定すると音の高さをこの倍率にそろえる(エンドレスロールのコンボで音程を上げる)
function Sound.playPop(idx, pitch)
  if idx == lastPopIdx then idx = idx % NUM_VARIANTS + 1 end   -- 同じ音が続けて鳴らないように
  lastPopIdx = idx
  local v = variants[idx]
  local src = v.src:clone()          -- 重ねて鳴らせるようにクローン
  if pitch then
    src:setPitch(pitch * rand(0.98, 1.02) * pitchScale)          -- ばらつきを小さくして音程の上がり方を聞かせる
  else
    src:setPitch(rand(0.82, 1.10) * pitchScale)
  end
  src:setVolume(rand(0.7, 1.0))
  src:play()
  if love.system.vibrate then        -- 非対応環境では何もしない
    love.system.vibrate(0.012 + 0.015 * v.size)
  end
end

---------------------------------------------------------------
-- 早送りの「ジャッ」(Lv2-1 ローラー送りで1行潰したとき)
-- シートが一気に引き出される音: 低めに絞ったノイズに、ローラーのラチェットのような細かい刻みを乗せる
---------------------------------------------------------------
local zipSources = nil

local function makeZip(seed)
  local rate = 44100
  local dur = 0.16
  local n = math.floor(rate * dur)
  local sd = love.sound.newSoundData(n, rate, 16, 1)
  local rng = love.math.newRandomGenerator(seed)
  local lp = 0
  for i = 0, n - 1 do
    local t = i / rate
    local f = 1 - t / dur                                  -- 0〜1(だんだん弱く)
    local cutoff = 0.10 + 0.35 * f                         -- 最初は明るく、だんだんこもる
    lp = lp + (rng:random() * 2 - 1 - lp) * cutoff
    local tick = 0.55 + 0.45 * math.max(0, math.sin(2 * math.pi * 95 * t)) ^ 6   -- ラチェットの刻み
    local env = math.min(1, t / 0.006) * f * f             -- 立ち上がり 6ms、すっと消える
    sd:setSample(i, lp * tick * env * 0.9)
  end
  return love.audio.newSource(sd, "static")
end

function Sound.playZip()
  if not zipSources then
    zipSources = { makeZip(11), makeZip(23), makeZip(37) }
  end
  local s = zipSources[love.math.random(#zipSources)]:clone()
  s:setPitch(0.92 + 0.16 * love.math.random())
  s:setVolume(0.8)
  s:play()
end

---------------------------------------------------------------
-- 時間切れのブザー(Lv2-1)。少しずらした2つの矩形波がうなって「ブーッ」と鳴る
---------------------------------------------------------------
local function makeBuzzer()
  local dur = 0.9
  local n = math.floor(SAMPLE_RATE * dur)
  local f1, f2 = 118, 124
  local p1, p2, lp = 0, 0, 0
  local buf = {}
  for i = 0, n - 1 do
    local t = i / SAMPLE_RATE
    p1 = (p1 + f1 / SAMPLE_RATE) % 1
    p2 = (p2 + f2 / SAMPLE_RATE) % 1
    local sq = (p1 < 0.5 and 1 or -1) + (p2 < 0.45 and 1 or -1) * 0.8
    lp = lp + 0.18 * (sq - lp)                                -- 角を少し丸めて耳に痛くない音に
    local env = math.min(1, t / 0.01) * math.min(1, (dur - t) / 0.06)
    buf[i] = lp * env
  end
  return toSource(buf, n, 0.75)
end

---------------------------------------------------------------
-- 全部潰したときのファンファーレ(Lv2-1)。金管っぽい「パパパ・パーン、パ・パーーン」
---------------------------------------------------------------
local function makeFanfare()
  -- { 周波数(Hz), 始まり(秒), 長さ(秒) }。最後は和音で伸ばす
  local notes = {
    { 392, 0.00, 0.11 }, { 392, 0.13, 0.11 }, { 392, 0.26, 0.11 }, { 523, 0.39, 0.42 },
    { 440, 0.84, 0.13 }, { 523, 0.99, 0.13 },
    { 659, 1.14, 1.05 }, { 523, 1.14, 1.05 }, { 784, 1.14, 1.05 },
  }
  local dur = 2.3
  local n = math.floor(SAMPLE_RATE * dur)
  local buf = {}
  for i = 0, n - 1 do buf[i] = 0 end
  for _, nt in ipairs(notes) do
    local f, t0, len = nt[1], nt[2], nt[3]
    local i0 = math.floor(t0 * SAMPLE_RATE)
    local m = math.floor((len + 0.12) * SAMPLE_RATE)        -- 少し余韻を残す
    local phase = 0
    for j = 0, m - 1 do
      local i = i0 + j
      if i >= n then break end
      local t = j / SAMPLE_RATE
      local vib = 1 + 0.006 * math.sin(2 * pi * 5.5 * t) * math.min(1, t / 0.25)   -- 長い音にだけ揺れが付く
      phase = phase + 2 * pi * f * vib / SAMPLE_RATE
      local tone = 0
      for h = 1, 6 do tone = tone + math.sin(phase * h) / h * (h == 1 and 1 or 0.8) end   -- 倍音で金管らしく
      local env = math.min(1, t / 0.015)
      if t > len then env = env * math.max(0, 1 - (t - len) / 0.12) end
      env = env * (0.75 + 0.25 * math.exp(-t / 0.08))      -- 吹き始めを少し強く
      buf[i] = buf[i] + tone * env
    end
  end
  for i = 0, n - 1 do local d = buf[i] * 0.35 buf[i] = d / (1 + math.abs(d)) end   -- 和音が重なっても割れないように
  return toSource(buf, n, 0.85)
end

---------------------------------------------------------------
-- 「キラッ」(Lv2-2 で星の潰れ方のとき)。ガラスのような倍音がすっと消える
---------------------------------------------------------------
local function makeChime(f)
  local dur = 0.35
  local n = math.floor(SAMPLE_RATE * dur)
  local parts = { { 1, 1.0, 0.16 }, { 2.76, 0.5, 0.08 }, { 5.40, 0.25, 0.04 } }   -- 倍率・音量・減衰(秒)
  local buf = {}
  for i = 0, n - 1 do
    local t = i / SAMPLE_RATE
    local v = 0
    for _, pt in ipairs(parts) do v = v + math.sin(2 * pi * f * pt[1] * t) * pt[2] * math.exp(-t / pt[3]) end
    buf[i] = v * math.min(1, t / 0.002) * math.min(1, (n - 1 - i) / 200)
  end
  return toSource(buf, n, 0.5)
end

---------------------------------------------------------------
-- 達成のジングル(Lv2-2 で 50個ごと)。big = true(100個ごと)は1音多く、最後を和音で伸ばす
---------------------------------------------------------------
local function makeMilestone(big)
  local notes = big
    and { { 784, 0.00, 0.09 }, { 988, 0.09, 0.09 }, { 1175, 0.18, 0.09 }, { 1568, 0.27, 0.55 }, { 1175, 0.27, 0.55 } }
    or  { { 1047, 0.00, 0.08 }, { 1319, 0.08, 0.08 }, { 1568, 0.16, 0.30 } }
  local dur = big and 1.0 or 0.6
  local n = math.floor(SAMPLE_RATE * dur)
  local buf = {}
  for i = 0, n - 1 do buf[i] = 0 end
  for _, nt in ipairs(notes) do
    local f, t0, len = nt[1], nt[2], nt[3]
    local i0 = math.floor(t0 * SAMPLE_RATE)
    local m = math.floor((len + 0.15) * SAMPLE_RATE)
    for j = 0, m - 1 do
      local i = i0 + j
      if i >= n then break end
      local t = j / SAMPLE_RATE
      local env = math.min(1, t / 0.004) * math.exp(-t / (len * 0.9 + 0.05))      -- 鉄琴のように叩いて消える
      buf[i] = buf[i] + (math.sin(2 * pi * f * t) + 0.35 * math.sin(2 * pi * f * 2 * t)
                         + 0.15 * math.sin(2 * pi * f * 3.01 * t)) * env
    end
  end
  for i = 0, n - 1 do local d = buf[i] * 0.5 buf[i] = d / (1 + math.abs(d)) end
  return toSource(buf, n, 0.8)
end

local buzzerSrc, fanfareSrc = nil, nil
local chimeSrc, milestoneSmall, milestoneBig = nil, nil, nil

-- ブザー・ファンファーレ・キラッ・達成のジングルを前もって作っておく(鳴らす瞬間に止まらないように、ステージに入るときに呼ぶ)
function Sound.prepareJingles()
  if not buzzerSrc then buzzerSrc = makeBuzzer() end
  if not fanfareSrc then fanfareSrc = makeFanfare() end
  if not chimeSrc then chimeSrc = { makeChime(1760), makeChime(2093), makeChime(2349) } end
  if not milestoneSmall then milestoneSmall, milestoneBig = makeMilestone(false), makeMilestone(true) end
end

-- pitch: 省略可。コンボで上がった音程に合わせる
function Sound.playChime(pitch)
  Sound.prepareJingles()
  local s = chimeSrc[love.math.random(#chimeSrc)]:clone()
  s:setPitch((pitch or 1) * rand(0.97, 1.03))
  s:setVolume(0.35)
  s:play()
end

function Sound.playMilestone(big)
  Sound.prepareJingles()
  local s = (big and milestoneBig or milestoneSmall):clone()
  s:setVolume(big and 1.0 or 0.85)
  s:play()
end

function Sound.playBuzzer()
  Sound.prepareJingles()
  local s = buzzerSrc:clone()
  s:setVolume(0.9)
  s:play()
end

function Sound.playFanfare()
  Sound.prepareJingles()
  local s = fanfareSrc:clone()
  s:setVolume(1.0)
  s:play()
end

return Sound
