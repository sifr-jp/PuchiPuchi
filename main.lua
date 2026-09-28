-- Puchipuchi v1.0: bubble wrap popping game (LÖVE 11.x)
-- Lv1-1 Training : ウィンドウの大きさに合わせて行数が変わる(これまでのステージ)
-- Lv1-2 Big Sheet: 画面サイズ固定 / 約300粒 / スクロール / 指のカーソル / 自己ベストを記録
--
-- ファイル構成
--   main.lua     ゲーム本体(このファイル)
--   sound.lua    音の合成
--   records.lua  記録の保存
--   finger.lua   指のカーソル
--   stages.lua   ステージ設定の表
--
-- 履歴
--   v0.2〜v0.10: 素材感・音・手応え・半割の粒・時間表示など(ステージ1)
--   v1.0: ステージ選択 / スクロール / 指のカーソル / 記録 / ファイル分割

local Sound = require("sound")
local Records = require("records")
local Finger = require("finger")
local STAGES = require("stages")

local pi = math.pi

---------------------------------------------------------------
-- 調整用の定数
---------------------------------------------------------------
local RELEASE_TIME = 0.25       -- 離したときに元に戻るまでの時間(秒)
local SWIPE_FAST = 12           -- 「速いなぞり」の基準(粒/秒)。大きいほど速くても深く入る
local SPRING_DELAY_MIN = 0.09   -- 「ポコッ」を指を離してから鳴らすまでの遅れ(秒)
local SPRING_DELAY_MAX = 0.17
local CARRY_MAX_GAP = 0.30      -- この時間(秒)以内に次の粒へ移ると、勢いが持ち越される
local TOP, MARGIN = 60, 16      -- シート上端の位置 / 画面端の余白
local HUD_H = 50                -- 上部の表示エリアの高さ(スクロール時、ここより上は隠れる)
local HUD_SIZE = 20             -- 上部の表示文字の大きさ(px)
local MSG_SIZE = 24             -- メッセージの文字の大きさ(px)
local TITLE_SIZE = 44           -- タイトルの文字の大きさ(px)
local FIXED_W, FIXED_H = 480, 800   -- 固定ステージの画面サイズ(ウィンドウが違っても縮尺で合わせる)
local SCROLL_WHEEL = 80         -- マウスホイール1目盛りのスクロール量(px)
local SCROLL_KEY = 700          -- 矢印キー・W/Sのスクロール速度(px/秒)
local EDGE_ZONE = 45            -- 押したまま上下の端へ動かすと自動スクロールする範囲(px)
local EDGE_SPEED = 380          -- そのときのスクロール速度(px/秒)
local FINISH_LOCK = 0.8         -- 全部潰した直後、この時間(秒)はクリックしてもリセットしない

---------------------------------------------------------------
-- 状態
---------------------------------------------------------------
local scene = "menu"                          -- "menu" か "play"
local stage = nil                             -- 遊んでいるステージの設定(stages.lua)
local view = { w = FIXED_W, h = FIXED_H, scale = 1, ox = 0, oy = 0 }
local rows = 13
local bubbles = {}
local sheet = { x = 0, y = 0, w = 0, h = 0, sheen = {}, creases = {}, wob = {} }
local popped, total = 0, 0
local cell = 40
local scrollY, maxScroll = 0, 0
local lastTarget = nil
local pending = {}                            -- 遅らせて鳴らす音のキュー
local mx0, my0, mspeed = nil, nil, 0          -- マウス移動速度(px/秒, 平滑化)
local sy0, edgeDir = nil, 0                   -- 端への自動スクロール用
local leftAt, leftP, leftDwell = -1, 0, 0     -- 直前に離れた粒の記録(勢いの持ち越し用)
local elapsed, timing = 0, false              -- 経過時間(秒)と計測中かどうか
local finished, finishAt, finishInfo = false, 0, nil
local fingerPress = 0                         -- 指カーソルの押し込み量(0〜1)
local hudFont, msgFont, titleFont

local function rand(a, b) return a + (b - a) * love.math.random() end
local function later(delay, fn) pending[#pending + 1] = { t = delay, fn = fn } end
local function clamp(v, a, b) return math.max(a, math.min(b, v)) end

local function useFinger()
  local os_ = love.system.getOS()
  return stage ~= nil and stage.finger and os_ ~= "Android" and os_ ~= "iOS"
end

-- 経過時間を「分:秒.1/100秒」にする
local function fmtTime(sec)
  local cs = math.floor(sec * 100)                 -- 1/100秒単位の整数
  return string.format("%d:%02d.%02d", math.floor(cs / 6000), math.floor(cs / 100) % 60, cs % 100)
end

---------------------------------------------------------------
-- 画面(view): 固定ステージは 480x800 の仮想画面をウィンドウに合わせて拡大縮小する
---------------------------------------------------------------
local function updateView()
  local W, H = love.graphics.getDimensions()
  if scene == "play" and stage and stage.free then
    view.w, view.h, view.scale, view.ox, view.oy = W, H, 1, 0, 0
  else
    view.w, view.h = FIXED_W, FIXED_H
    view.scale = math.min(W / FIXED_W, H / FIXED_H)
    view.ox = (W - FIXED_W * view.scale) / 2
    view.oy = (H - FIXED_H * view.scale) / 2
  end
end

-- マウス位置(仮想画面の座標)
local function mousePos()
  local x, y = love.mouse.getPosition()
  return (x - view.ox) / view.scale, (y - view.oy) / view.scale
end

-- 仮想画面の座標でシザー(描画範囲の制限)を設定する
local function setScissor(x, y, w, h)
  local s = view.scale
  love.graphics.setScissor(math.floor(view.ox + x * s), math.floor(view.oy + y * s),
                           math.ceil(w * s), math.ceil(h * s))
end

local function scrollBy(d)
  scrollY = clamp(scrollY + d, 0, maxScroll)
end

---------------------------------------------------------------
-- シートの生成とレイアウト
---------------------------------------------------------------
local function calcRows()
  cell = math.min((view.w - 2 * MARGIN) / stage.cols, stage.maxCell or 64)
  if stage.free then
    -- 下端に少しでも見える行まで作る。下端にかかる行は半割になる
    local y1 = view.h - MARGIN
    rows = math.max(1, math.ceil((y1 - TOP - 0.19 * cell) / (cell * 0.87)))
  else
    rows = stage.rows
  end
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
  local cols = stage.cols
  local ox = (view.w - cols * cell) / 2
  for _, b in ipairs(bubbles) do
    local off = (b.r % 2 == 0) and 0.5 or 0        -- 千鳥配置
    b.x = ox + (b.c - 1 + 0.5 + off) * cell
    b.y = TOP + cell * 0.5 + (b.r - 1) * cell * 0.87
    b.rad = cell * 0.46 * b.sz
  end
  sheet.x = math.floor(ox + 0.5)
  sheet.y = math.floor(TOP - 0.10 * cell + 0.5)
  sheet.w = math.floor(cols * cell + 0.5)
  local y1
  if stage.free then
    y1 = math.floor(view.h - MARGIN + 0.5)                       -- 画面の下端で切る
  else
    y1 = math.floor(TOP + 0.5 * cell + (rows - 1) * 0.87 * cell + 0.6 * cell + 0.5)
  end
  sheet.h = y1 - sheet.y
  maxScroll = stage.free and 0 or math.max(0, y1 + MARGIN - view.h)
  scrollY = clamp(scrollY, 0, maxScroll)
  local x0, y0 = sheet.x, sheet.y
  local x1 = x0 + sheet.w
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
    local c0 = (r % 2 == 0) and 0 or 1              -- 偶数行は両端(c=0, c=cols)に半割の粒が入る
    for c = c0, stage.cols do
      local hard = love.math.random() < stage.hardRatio
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
        snd = love.math.random(Sound.NUM_VARIANTS),
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
  local k = stage.free and 1 or 3                  -- シートが長いほど筋やしわを増やす
  sheet.sheen = {}                                 -- フィルム面のうっすらした筋
  for i = 1, 10 * k do
    sheet.sheen[i] = { rand(0, 1), rand(0, 1), rand(0, 1), rand(0, 1) }
  end
  sheet.creases = {}                               -- 長くて柔らかいしわ(ビニールの折れ)
  for i = 1, 5 * k do
    local y1 = rand(0, 1)
    sheet.creases[i] = { 0, y1, 1, y1 + rand(-0.25, 0.25) / k, rand(0.05, 0.11) }
  end
  lastTarget = nil
  leftAt = -1
  elapsed, timing = 0, false
  finished, finishInfo = false, nil
  scrollY, edgeDir, sy0 = 0, 0, nil
  layout()
  popped, total = 0, 0                             -- 半割の粒は数えない
  for _, b in ipairs(bubbles) do
    if not b.cut then total = total + 1 end
  end
end

-- (mx, wy): シート上の座標(スクロール分を足したもの)
local function hit(mx, wy)
  if mx < sheet.x or mx > sheet.x + sheet.w or wy < sheet.y or wy > sheet.y + sheet.h then
    return nil                                     -- 切り落とされた部分は触れない
  end
  for _, b in ipairs(bubbles) do
    local dx, dy = mx - b.x, wy - b.y
    if dx * dx + dy * dy <= b.rad * b.rad then return b end
  end
end

local function pop(b)
  b.popped, b.t = true, 0
  popped = popped + 1
  Sound.playPop(b.snd)
end

---------------------------------------------------------------
-- メニューとステージの出入り
---------------------------------------------------------------
local function menuCard(i)
  return 40, 190 + (i - 1) * 128, view.w - 80, 108
end

local function menuHit(mx, my)
  for i = 1, #STAGES do
    local x, y, w, h = menuCard(i)
    if mx >= x and mx <= x + w and my >= y and my <= y + h then return i end
  end
end

local function enterStage(i)
  stage = STAGES[i]
  scene = "play"
  updateView()
  fingerPress = 0
  newSheet()
  love.mouse.setVisible(not useFinger())          -- 指のカーソルを使うステージでは本物のカーソルを隠す
end

local function exitToMenu()
  scene = "menu"
  love.mouse.setVisible(true)
  pending = {}
  updateView()
end

---------------------------------------------------------------
-- LÖVE コールバック
---------------------------------------------------------------
function love.load()
  love.keyboard.setTextInput(false)     -- 日本語入力(IME)がキーを横取りしないようにする
  love.graphics.setBackgroundColor(0.86, 0.92, 0.96)
  hudFont = love.graphics.newFont(HUD_SIZE)
  msgFont = love.graphics.newFont(MSG_SIZE)
  titleFont = love.graphics.newFont(TITLE_SIZE)
  love.math.setRandomSeed(os.time())
  Sound.init()
  Records.load()
  updateView()
end

function love.resize()
  updateView()
  if scene == "play" and stage.free then newSheet() end   -- 可変ステージは行数が変わるので作り直す
end

function love.mousepressed(x, y, button)
  local mx, sy = (x - view.ox) / view.scale, (y - view.oy) / view.scale
  if scene == "menu" then
    if button == 1 then
      local i = menuHit(mx, sy)
      if i then enterStage(i) end
    end
    return
  end
  if button ~= 1 then return end
  if finished then
    if love.timer.getTime() - finishAt > FINISH_LOCK then newSheet() end   -- 全部潰したらクリックで再挑戦
    return
  end
  if sy < HUD_H then return end
  local b = hit(mx, sy + scrollY)
  if b and not b.popped then
    b.press = math.max(b.press, rand(0.25, 0.5))      -- 素早いタップ対応
    b.dwell = 0
    lastTarget = b
    Sound.playCreak(b.cut and 0.3 or 1)
  end
end

-- 右ボタン(または中ボタン)を押したままドラッグでスクロール
function love.mousemoved(x, y, dx, dy)
  if scene == "play" and stage.scroll and (love.mouse.isDown(2) or love.mouse.isDown(3)) then
    scrollBy(-dy / view.scale)
  end
end

function love.wheelmoved(x, y)
  if scene == "play" and stage.scroll then scrollBy(-y * SCROLL_WHEEL) end
end

function love.keypressed(key, scancode)
  if scene == "menu" then
    if key == "escape" then love.event.quit() end
    local i = tonumber(key)
    if i and STAGES[i] then enterStage(i) end
    return
  end
  if key == "r" or scancode == "r" then newSheet() end   -- キー配列に関係なく物理的なRキーでも反応
  if key == "escape" then exitToMenu() end
  if stage.scroll then
    if key == "home" then scrollY = 0 end
    if key == "end" then scrollY = maxScroll end
    if key == "pageup" then scrollBy(-view.h * 0.8) end
    if key == "pagedown" then scrollBy(view.h * 0.8) end
  end
end

function love.update(dt)
  if scene ~= "play" then return end
  local now = love.timer.getTime()
  local mx, sy = mousePos()
  local down = love.mouse.isDown(1)

  -- スクロール: 矢印キー / W・S / 押したまま上下の端へ動かしている間
  if stage.scroll then
    if love.keyboard.isDown("up", "w") then scrollBy(-SCROLL_KEY * dt) end
    if love.keyboard.isDown("down", "s") then scrollBy(SCROLL_KEY * dt) end
    if down and not finished then
      local dyv = sy - (sy0 or sy)
      local inTop = sy < HUD_H + EDGE_ZONE
      local inBot = sy > view.h - EDGE_ZONE
      -- 端に向かって動かしたときだけ始まる(端の粒をゆっくり潰すときに勝手に動かないように)
      if inTop and (dyv < -1 or edgeDir == -1) then edgeDir = -1
      elseif inBot and (dyv > 1 or edgeDir == 1) then edgeDir = 1
      else edgeDir = 0 end
      if edgeDir ~= 0 then scrollBy(edgeDir * EDGE_SPEED * dt) end
    else
      edgeDir = 0
    end
  end
  sy0 = sy
  local wy = sy + scrollY                          -- シート上の座標

  -- マウス移動速度(平滑化)。なぞりの速さで粒に入る力を変えるために使う
  if down and mx0 then
    local dx, dy = mx - mx0, wy - my0
    local inst = math.sqrt(dx * dx + dy * dy) / math.max(dt, 1e-4)
    mspeed = mspeed + (inst - mspeed) * math.min(1, dt * 10)
  else
    mspeed = 0
  end
  mx0, my0 = mx, wy

  fingerPress = fingerPress + ((down and 1 or 0) - fingerPress) * math.min(1, dt * 18)

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
  if down and sy >= HUD_H and not finished then target = hit(mx, wy) end
  if target then timing = true end                            -- 最初に粒に触れたら計測開始
  if timing and not finished then elapsed = elapsed + dt end  -- 全部潰したら止まる

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
      Sound.playCreak(target.cut and 0.3 or (0.5 + 0.5 * slow))
    end
    lastTarget = target
  end

  for _, b in ipairs(bubbles) do
    if b.cut then                                      -- 半割の粒: 押されて凹むだけで破裂しない
      if b == target then
        b.press = math.min(0.45, b.press + dt / stage.pressTime * 0.6)
      else
        b.press = math.max(0, b.press - dt / RELEASE_TIME)
      end
    elseif not b.popped then
      if b == target then
        b.held = true
        b.dwell = b.dwell + dt
        -- 押し込み速度は粒ごとに違い、しかも時間とともに滑らかに揺らぐ
        local wave = 0.55 + 0.9 * love.math.noise(b.seed, now * 3)
        b.press = b.press + dt / stage.pressTime * b.speed * wave
        if b.press >= b.thresh then
          pop(b)
        elseif b.press / b.thresh > 0.7 and not b.stretched then
          b.stretched = true                               -- 素材が伸び切る手前
          if b.hard or love.math.random() < 0.35 then Sound.playStretch(b.hard) end
        end
      else
        if b.held then                                     -- 指を離した瞬間
          b.held = false
          local p = math.min(1, b.press / b.thresh)
          if p > 0.35 then
            -- 空気が戻る「ポコッ」は少し遅れて鳴る。揺れも同じタイミングで始める
            later(rand(SPRING_DELAY_MIN, SPRING_DELAY_MAX), function()
              if not b.popped then
                Sound.playSpring(p)
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

  -- 全部潰したら記録する(記録のあるステージだけ)
  if not finished and total > 0 and popped >= total then
    finished = true
    finishAt = now
    if stage.record then
      local prev = Records.best(stage.id)
      local rank = Records.add(stage.id, elapsed, stage.record.n)
      finishInfo = { prev = prev, rank = rank }
    end
  end
end

---------------------------------------------------------------
-- 描画: 粒
---------------------------------------------------------------
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

---------------------------------------------------------------
-- 描画: シート(スクロールする層)
---------------------------------------------------------------
-- シートの矩形と、上部の表示エリアより下の範囲が重なる部分にシザーを設定する
local function clipSheet()
  local x0 = math.max(sheet.x, 0)
  local y0 = math.max(sheet.y - scrollY, HUD_H)
  local x1 = math.min(sheet.x + sheet.w, view.w)
  local y1 = math.min(sheet.y + sheet.h - scrollY, view.h)
  if x1 <= x0 or y1 <= y0 then return false end
  setScissor(x0, y0, x1 - x0, y1 - y0)
  return true
end

local function drawSheet()
  love.graphics.setColor(0, 0.1, 0.2, 0.10)                      -- シートの影(厚みの表現)
  love.graphics.rectangle("fill", sheet.x + 2, sheet.y + 3, sheet.w, sheet.h)
  love.graphics.setColor(1, 1, 1, 0.38)                          -- 平らなフィルム面
  love.graphics.rectangle("fill", sheet.x, sheet.y, sheet.w, sheet.h)
end

-- 粒の上に重ねるフィルムの反射。マウスの位置で光の帯が動く(見えている範囲に合わせて動く)
local function drawFilm()
  if not clipSheet() then return end

  local mx = mousePos()
  local mxr = clamp(mx / view.w, 0, 1)
  local yv0 = math.max(sheet.y, scrollY)
  local yv1 = math.min(sheet.y + sheet.h, scrollY + view.h)
  local skew = (yv1 - yv0) * 0.35
  local bw = sheet.w * 0.16
  local gx = sheet.x + sheet.w * (0.1 + 0.9 * mxr)
  love.graphics.setColor(1, 1, 1, 0.10)                          -- 太い光の帯
  love.graphics.polygon("fill", gx, yv0, gx + bw, yv0, gx + bw - skew, yv1, gx - skew, yv1)
  local gx2 = gx + bw * 1.6
  love.graphics.setColor(1, 1, 1, 0.06)                          -- 細い光の帯
  love.graphics.polygon("fill", gx2, yv0, gx2 + bw * 0.3, yv0,
                        gx2 + bw * 0.3 - skew, yv1, gx2 - skew, yv1)

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

---------------------------------------------------------------
-- 描画: 画面全体
---------------------------------------------------------------
-- 右端のスクロールバー。潰していない粒の位置が青い印で見える(最後の1粒探しに便利)
local function drawScrollbar()
  if maxScroll <= 0 then return end
  local x = view.w - 10
  local y0, h = HUD_H + 4, view.h - HUD_H - 8
  local worldH = maxScroll + view.h
  love.graphics.setColor(0.2, 0.3, 0.4, 0.12)
  love.graphics.rectangle("fill", x, y0, 6, h, 3, 3)
  love.graphics.setColor(0.25, 0.55, 0.9, 0.6)
  for _, b in ipairs(bubbles) do
    if not b.popped and not b.cut then
      love.graphics.rectangle("fill", x, y0 + h * b.y / worldH, 6, 1.5)
    end
  end
  local th = math.max(14, h * view.h / worldH)
  local ty = y0 + h * scrollY / worldH
  love.graphics.setColor(0.2, 0.3, 0.4, 0.40)
  love.graphics.setLineWidth(1.5)
  love.graphics.rectangle("line", x - 1.5, ty, 9, th, 4, 4)
end

local function drawFinishPanel()
  love.graphics.setFont(msgFont)
  local lines = { "All popped!  " .. fmtTime(elapsed) }
  if stage.record then
    local best = Records.best(stage.id)
    if finishInfo and finishInfo.rank == 1 then
      lines[#lines + 1] = finishInfo.prev and ("NEW RECORD!  (prev " .. fmtTime(finishInfo.prev) .. ")")
                          or "NEW RECORD!"
    else
      lines[#lines + 1] = "BEST  " .. (best and fmtTime(best) or "--")
    end
  end
  lines[#lines + 1] = "Click: retry   Esc: menu"
  local lw = 0
  for _, l in ipairs(lines) do lw = math.max(lw, msgFont:getWidth(l)) end
  local lh = msgFont:getHeight()
  local bw, bh = lw + 48, lh * #lines + 32
  local vy0 = HUD_H
  local py = vy0 + (view.h - vy0 - bh) / 2
  love.graphics.setColor(1, 1, 1, 0.85)
  love.graphics.rectangle("fill", (view.w - bw) / 2, py, bw, bh, 14, 14)
  love.graphics.setColor(0.5, 0.75, 0.95, 0.9)
  love.graphics.setLineWidth(1.5)
  love.graphics.rectangle("line", (view.w - bw) / 2, py, bw, bh, 14, 14)
  love.graphics.setColor(0.2, 0.3, 0.4)
  love.graphics.printf(table.concat(lines, "\n"), 0, py + 16, view.w, "center")
end

local function drawPlay()
  -- シート(スクロールする層)
  setScissor(0, HUD_H, view.w, view.h - HUD_H)
  love.graphics.push()
  love.graphics.translate(0, -scrollY)
  drawSheet()
  if clipSheet() then
    for _, b in ipairs(bubbles) do
      if b.y + b.rad > scrollY and b.y - b.rad < scrollY + view.h then   -- 見えている粒だけ描く
        if b.popped then drawPopped(b) else drawIntact(b) end
      end
    end
  end
  drawFilm()
  setScissor(0, HUD_H, view.w, view.h - HUD_H)
  drawCutEdges()
  love.graphics.pop()
  love.graphics.setScissor()

  if scrollY > 1 then                                            -- 上部の表示エリアの下に薄い影
    for i = 0, 7 do
      love.graphics.setColor(0.1, 0.2, 0.3, 0.10 * (1 - i / 8))
      love.graphics.rectangle("fill", 0, HUD_H + i, view.w, 1)
    end
  end

  -- 上部の表示: 左=潰した数 / 中央=経過時間 / 右=リセットの案内(記録のあるステージは最高記録)
  love.graphics.setFont(hudFont)
  love.graphics.setColor(0.2, 0.3, 0.4)
  love.graphics.print(string.format("%d / %d", popped, total), 16, 18)
  love.graphics.printf(fmtTime(elapsed), 0, 18, view.w, "center")
  if stage.record then
    local best = Records.best(stage.id)
    love.graphics.printf("BEST " .. (best and fmtTime(best) or "--"), 0, 18, view.w - 16, "right")
  else
    love.graphics.printf("[R] reset", 0, 18, view.w - 16, "right")
  end

  drawScrollbar()
  if finished then drawFinishPanel() end

  if useFinger() then                                            -- 指のカーソル(いちばん手前)
    local mx, sy = mousePos()
    Finger.draw(mx, sy, fingerPress)
  end
end

local function drawMenu()
  love.graphics.setColor(0.2, 0.3, 0.4)
  love.graphics.setFont(titleFont)
  love.graphics.printf("PUCHIPUCHI", 0, 60, view.w, "center")
  love.graphics.setFont(hudFont)
  love.graphics.setColor(0.35, 0.45, 0.55)
  love.graphics.printf("Level 1", 0, 130, view.w, "center")

  local mx, my = mousePos()
  for i, s in ipairs(STAGES) do
    local x, y, w, h = menuCard(i)
    local over = mx >= x and mx <= x + w and my >= y and my <= y + h
    love.graphics.setColor(1, 1, 1, over and 0.80 or 0.50)
    love.graphics.rectangle("fill", x, y, w, h, 14, 14)
    love.graphics.setColor(0.5, 0.75, 0.95, 0.9)
    love.graphics.setLineWidth(1.5)
    love.graphics.rectangle("line", x, y, w, h, 14, 14)
    love.graphics.setColor(0.2, 0.3, 0.4)
    love.graphics.setFont(msgFont)
    love.graphics.print(i .. "   " .. s.title, x + 20, y + 16)
    love.graphics.setFont(hudFont)
    love.graphics.setColor(0.35, 0.45, 0.55)
    love.graphics.print(s.sub, x + 20, y + 62)
    if s.record then
      local best = Records.best(s.id)
      love.graphics.printf("BEST " .. (best and fmtTime(best) or "--"), x, y + 16, w - 20, "right")
    end
  end

  love.graphics.setFont(hudFont)
  love.graphics.setColor(0.45, 0.55, 0.65)
  love.graphics.printf("Lv1-3 and more: coming soon", 0, view.h - 110, view.w, "center")
  love.graphics.printf("Click or press 1-" .. #STAGES .. "     Esc: quit", 0, view.h - 70, view.w, "center")
end

function love.draw()
  love.graphics.push()
  love.graphics.translate(view.ox, view.oy)
  love.graphics.scale(view.scale)
  if scene == "menu" then drawMenu() else drawPlay() end
  love.graphics.pop()
end
