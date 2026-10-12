-- Puchipuchi v1.0: bubble wrap popping game (LÖVE 11.x)
-- Lv1-1 Training : ウィンドウの大きさに合わせて行数が変わる(これまでのステージ)
-- Lv1-2 Big Sheet: 画面サイズ固定 / 約300粒 / スクロール / 指のカーソル / 自己ベストを記録
-- Lv1-3 Large / Small: 大粒約150 / 小粒約500 / 上位3位の記録とイニシャル入力
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
--   v1.1: 指のカーソルを親指の形に
--   v1.2: Lv1-3 大粒・小粒 / 上位3位とイニシャル入力 / 記録の一覧画面(メニューで T) / ステージごとの音の高さ
--   v1.3: 命中判定の広さを3段階に(Blue=円全体/Yellow=大きめの中心/Pink=小さい中心)。
--         メニューで選び、どのステージにも適用。難易度ラベル(EASY/HARD/LUNATIC)を表示
--   v1.4: 記録を色ごとに完全に分離(Blue/Yellow/Pinkで別々のランキング)。記録一覧も色別の列で表示
--   v1.5〜v1.7: 連打対応/BESTの丸の位置修正/指カーソルの潰れ・弾み・爪の色を調整
--   v1.8: スマホ対応の第一歩。下部にMENU/RESETのタップボタン、イニシャル入力を上下矢印とOK/Skip
--         ボタンに変更(物理キーボードが無くても遊べるように)。conf.luaにhighdpiを追加
--   v2.0: Lv2-1 ローラー送り。メニューに Lv1/Lv2 の切り替えタブ(Tab キーでも切り替え)。
--         記録の一覧は選んでいるレベルの分だけ表示。Lv2 では色が送り速度を決め、命中判定は Blue と同じ
--   v2.1: Lv2-1 の開始時はシートを1段だけ見せる / TAP TO START ボタンで開始
--   v2.2: Lv2-1 を制限時間制に(Blue 60秒 / Yellow 45秒 / Pink 30秒、180粒)。送りは一定速度で滑らかに
--         (早送りは無くし、1行潰したときは音だけ)。時間切れでブザー、時間内に全部潰すとファンファーレと紙吹雪。
--         上部中央は残り時間。記録は全部潰したときのタイムだけ。終了パネルのボタンは外し、下の MENU/RESET を使う
--   v2.3: Lv2-2 エンドレスロール。制限時間(Blue 60秒 / Yellow 90秒 / Pink 120秒)のあいだ、だんだん速くなるシートを潰す。
--         続けて潰すとコンボの文字と破裂音の音程アップ。記録は潰した個数(多い順)。自己ベスト更新でファンファーレ
--   v2.4: Lv2-2 を Lv2-1 とはっきり違う手触りに。粒は軽く触れるだけで潰れ、虹色のシートと暖かい背景。
--         潰れ方は4種類(輪・火花・もや・星)で、星は「キラッ」も鳴る。50個ごとに「50 POPS!」と
--         ジングルと紙吹雪(100個ごとは金色で大きく)

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
local BAR_H = 46                -- 下部のMENU/RESETボタン帯の高さ(スマホはキーボードが無いため)
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

-- ローラー送り(Lv2-1)
local ROLL_TOP_CY = 74          -- 上のローラー(繰り出し)の中心の高さ
local ROLL_BOT_CY = 724         -- 下のローラー(巻き取り)の中心の高さ
local ROLL_R_MIN, ROLL_R_MAX = 9, 22   -- ローラーの半径。巻いてあるシートの量で太さが変わる
local ROLL_TOUCH_TOP = 98       -- ここより下から触れる(上のローラーの陰は触れない)
local ROLL_TOUCH_BOT = 700      -- ここより上まで触れる。粒の中心がここを越えたら「取りこぼし」
local CONFETTI_N = 140          -- 全部潰したときの紙吹雪の数
local COMBO_GAP = 0.9           -- エンドレスロール: この時間(秒)以内に次を潰すとコンボが続く
local COMBO_SHOW = 0.8          -- コンボの文字が浮かんで消えるまでの時間(秒)
local MILESTONE_SHOW = 1.6      -- 「50 POPS!」などの達成表示が出ている時間(秒)

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
local entering, initials, entryRank = false, "", nil   -- イニシャル入力中か / 入力した文字 / 順位
local entrySlot = 1                                     -- キーボード入力時、次に入る桁(タップ操作には影響しない)
local lastInitials = ""                                 -- 直前に入力したイニシャル(次の入力の初期値)
local INITIAL_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"  -- タップで送れる文字(上下ボタン用)
local fingerPress, fingerPressV = 0, 0        -- 指カーソルの押し込み量(0〜1)とその速度(バネで動かす)
local FINGER_STIFF, FINGER_DAMP = 420, 16     -- バネの硬さ・減衰。硬いほど速く反応し、減衰が弱いほどよく弾む
local hudFont, msgFont, titleFont, tinyFont

-- 命中判定の広さ(粒の半径に対する割合)。狭いほど、粒の中心付近に正確に触れないと反応しない
local COLOR_MODES = { "blue", "yellow", "pink" }
local COLOR_FACTOR = { blue = 1.00, yellow = 0.55, pink = 0.38 }
local COLOR_LABEL  = { blue = "BLUE", yellow = "YELLOW", pink = "PINK" }
local COLOR_DIFF   = { blue = "EASY", yellow = "HARD", pink = "LUNATIC" }   -- 難易度の目安
local COLOR_RGB    = { blue = { 0.35, 0.60, 0.95 }, yellow = { 0.85, 0.68, 0.15 }, pink = { 0.90, 0.45, 0.65 } }
-- 命中半径の下限(px)。粒の大きいステージ(Big/Large)では割合そのままだと判定円が
-- 指で狙うには小さすぎる大きさになってしまうため、最低限の大きさを保証する
local COLOR_MINPX = { pink = 12 }
local colorMode = "blue"                      -- メニューで選んだ命中判定の広さ(全ステージ共通)
local menuLevel = 1                           -- メニューで表示しているレベル(1 / 2)
local MAX_LEVEL = 2

-- ローラー送りの状態
--   start: 開始時の scrollY / speed: 送り速度(px/秒) / limit: 制限時間(秒) / missed: 取りこぼした粒の数
--   rowLeft[r]: 行 r の潰していない粒の数 / phTop, phBot: 上下のローラーの回転角
--   result: nil(遊んでいる) / "clear"(時間内に全部潰した) / "timeup"(時間切れ)
--   confetti: 全部潰したときの紙吹雪 / celebrate: お祝いの文字({ title, sub })
--   エンドレスロール(Lv2-2)だけで使うもの:
--   v0, v1: 始めと終わりの送り速度(px/秒) / combo, maxCombo, comboAt: コンボの数・最大・最後に潰した時刻
--   comboFx: 浮かぶコンボの文字 { x, y, t, n } / milestone: 達成表示 { n, t, big }
local roll = { start = 0, speed = 30, limit = 60, missed = 0, rowLeft = {}, phTop = 0, phBot = 0,
               result = nil, confetti = {}, clearAt = 0, celebrate = nil,
               v0 = 20, v1 = 40, combo = 0, maxCombo = 0, comboAt = -10, comboFx = nil, milestone = nil }

-- ローラーのあるステージ(Lv2-1 ローラー送り / Lv2-2 エンドレスロール)
local function isRoller()
  return stage ~= nil and (stage.mode == "roller" or stage.mode == "endless")
end

local function isEndless()
  return stage ~= nil and stage.mode == "endless"
end

-- 送り始めてから t 秒で送った量(px)。エンドレスロールは速さが v0 から v1 へ一定の割合で上がる
local function rollDistance(t)
  if isEndless() then
    return roll.v0 * t + (roll.v1 - roll.v0) * t * t / (2 * roll.limit)
  end
  return roll.speed * t
end

-- 記録する値: エンドレスロールは潰した個数(多いほど上)、それ以外はタイム(短いほど上)
local function isScoreStage(s)
  return s and s.record and s.record.score
end

local function recordValue()
  if isScoreStage(stage) then return popped end
  return elapsed
end

-- 色が命中判定の広さを決めるのは Lv1 だけ。Lv2 では色は速度などを決め、判定は Blue と同じ
local function hitFactor()
  if stage and stage.mode then return 1 end
  return COLOR_FACTOR[colorMode] or 1
end

-- 命中判定の半径(px)。上の割合に加えて、PINKでは下限を適用する
local function hitRadiusOf(b)
  local f = hitFactor()
  local r = b.rad * f
  local minPx = f < 1 and COLOR_MINPX[colorMode]
  if minPx and r < minPx then r = minPx end
  return r
end

local function rand(a, b) return a + (b - a) * love.math.random() end
local function later(delay, fn) pending[#pending + 1] = { t = delay, fn = fn } end
local function clamp(v, a, b) return math.max(a, math.min(b, v)) end

-- 色相 h(0〜1)・彩度 sat・明るさ v から RGB を作る(エンドレスロールの虹色のシート用)
local function hsv(h, sat, v)
  local i = math.floor(h * 6) % 6
  local f = h * 6 - math.floor(h * 6)
  local p, q, t = v * (1 - sat), v * (1 - f * sat), v * (1 - (1 - f) * sat)
  if i == 0 then return { v, t, p } elseif i == 1 then return { q, v, p }
  elseif i == 2 then return { p, v, t } elseif i == 3 then return { p, q, v }
  elseif i == 4 then return { t, p, v } end
  return { v, p, q }
end

local function useFinger()
  local os_ = love.system.getOS()
  return stage ~= nil and stage.finger and os_ ~= "Android" and os_ ~= "iOS"
end

-- 経過時間を「分:秒.1/100秒」にする
local function fmtTime(sec)
  local cs = math.floor(sec * 100)                 -- 1/100秒単位の整数
  return string.format("%d:%02d.%02d", math.floor(cs / 6000), math.floor(cs / 100) % 60, cs % 100)
end

-- 記録の表示。個数のステージは整数、それ以外は時間
local function fmtRecord(s, v)
  if not v then return "--" end
  if isScoreStage(s) then return tostring(math.floor(v + 0.5)) end
  return fmtTime(v)
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

-- プレイ画面のうち、下部のMENU/RESET帯を除いた実際に遊べる範囲の下端
local function playBottom()
  return view.h - BAR_H
end

-- シートが見える範囲(上端・下端)。ローラー送りでは上下のローラーの中心で切る
local function clipTop() return isRoller() and ROLL_TOP_CY or HUD_H end
local function clipBottom() return isRoller() and ROLL_BOT_CY or playBottom() end
-- 粒に触れられる範囲(上端・下端)
local function touchTop() return isRoller() and ROLL_TOUCH_TOP or HUD_H end
local function touchBottom() return isRoller() and ROLL_TOUCH_BOT or playBottom() end

---------------------------------------------------------------
-- シートの生成とレイアウト
---------------------------------------------------------------
local function calcRows()
  cell = math.min((view.w - 2 * MARGIN) / stage.cols, stage.maxCell or 64)
  if stage.free then
    -- 下端に少しでも見える行まで作る。下端にかかる行は半割になる
    local y1 = playBottom() - MARGIN
    rows = math.max(1, math.ceil((y1 - TOP - 0.19 * cell) / (cell * 0.87)))
  elseif stage.mode == "endless" then
    -- エンドレスロール: 制限時間のあいだに送る量より長いシートを作っておく(画面1枚分の余裕を足す)
    local t = stage.time[colorMode]
    local dist = (stage.speedFrom[colorMode] + stage.speedTo[colorMode]) / 2 * t
    rows = math.ceil((dist + view.h) / (cell * 0.87)) + 2
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
    y1 = math.floor(playBottom() - MARGIN + 0.5)                 -- MENU/RESET帯の上で切る
  else
    y1 = math.floor(TOP + 0.5 * cell + (rows - 1) * 0.87 * cell + 0.6 * cell + 0.5)
  end
  sheet.h = y1 - sheet.y
  maxScroll = stage.free and 0 or math.max(0, y1 + MARGIN - playBottom())
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
        -- 粒ごとの「潰れにくさ」。伸びる粒は素早いなぞりでは潰れない。softPop のステージは軽く触れるだけで潰れる
        thresh = hard and rand(1.2, 1.8) or (stage.softPop and rand(0.30, 0.50) or rand(0.6, 1.1)),
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
        -- 潰れ方の種類(popFx のステージだけ): 1=輪 2=火花 3=空気のもや 4=星
        fx = stage.popFx and love.math.random(4) or 1,
        -- 虹色のシート(rainbow のステージだけ): 行ごとに色相を少しずつずらす
        col = stage.rainbow and hsv((r * 0.045 + c * 0.012) % 1, 0.42, 1) or nil,
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
  entering, initials, entryRank = false, "", nil
  scrollY, edgeDir, sy0 = 0, 0, nil
  layout()
  popped, total = 0, 0                             -- 半割の粒は数えない
  for _, b in ipairs(bubbles) do
    if not b.cut then total = total + 1 end
  end
  if isRoller() then
    -- ローラー送り: シートの先頭の1段だけが出たところで止まって待つ。
    -- 「TAP TO START」か粒に触れたら送りが始まり、時間も計り始める
    -- (先頭の段の中心を、触れられる範囲の上端から 0.35 粒下に置く。2段目は上のローラーに隠れる。
    --  シートの下端は先頭の段の中心の 0.6 粒下)
    maxScroll = 0
    roll.start = sheet.y + sheet.h - (ROLL_TOUCH_TOP + 0.95 * cell)
    scrollY = roll.start
    -- ローラー送り: 送りは一定の速さ。最後の段(いちばん上の行)の中心が、ちょうど制限時間で下端の線に着く速さ
    -- エンドレスロール: 速さは stages.lua の speedFrom から speedTo へ、時間とともに上がる
    roll.limit = stage.time and stage.time[colorMode] or 60
    local lastY = TOP + cell * 0.5 - roll.start             -- 最後の段の、開始時の画面上の高さ
    roll.speed = (ROLL_TOUCH_BOT - lastY) / roll.limit
    if stage.mode == "endless" then
      roll.v0, roll.v1 = stage.speedFrom[colorMode], stage.speedTo[colorMode]
    end
    roll.combo, roll.maxCombo, roll.comboAt, roll.comboFx, roll.milestone = 0, 0, -10, nil, nil
    roll.missed, roll.result, roll.confetti, roll.celebrate = 0, nil, {}, nil
    roll.phTop, roll.phBot = 0, 0
    roll.rowLeft = {}
    for _, b in ipairs(bubbles) do
      if not b.cut then roll.rowLeft[b.r] = (roll.rowLeft[b.r] or 0) + 1 end
    end
  end
end

-- (mx, wy): シート上の座標(スクロール分を足したもの)
-- 下部のMENU/RESET帯のどちらを押したか("menu" / "reset" / nil)。スマホに物理キーがないため常設する
local function barHit(mx, my)
  if my < playBottom() or my > view.h then return nil end
  if mx < view.w / 2 then return "menu" end
  return "reset"
end

local function hit(mx, wy)
  if mx < sheet.x or mx > sheet.x + sheet.w or wy < sheet.y or wy > sheet.y + sheet.h then
    return nil                                     -- 切り落とされた部分は触れない
  end
  for _, b in ipairs(bubbles) do
    if not b.missed then                           -- 取りこぼした粒(ローラー送り)はもう触れない
      local dx, dy = mx - b.x, wy - b.y
      local hr = hitRadiusOf(b)
      if dx * dx + dy * dy <= hr * hr then return b end
    end
  end
end

-- ローラー送り: 粒が片付いた(潰した or 取りこぼした)ときの行の数え直し
local function rollerSettle(b, wasPopped)
  roll.rowLeft[b.r] = roll.rowLeft[b.r] - 1
  if wasPopped and roll.rowLeft[b.r] == 0 then        -- 1行まるごと潰した: 「ジャッ」と鳴らす(送りの速さは変えない)
    if Sound.playZip then Sound.playZip() end
  end
end

-- エンドレスロール: 続けて潰すとコンボが増え、破裂音が半音ずつ高くなる(1オクターブまで)
local function addCombo(b)
  local now = love.timer.getTime()
  if now - roll.comboAt <= COMBO_GAP then roll.combo = roll.combo + 1 else roll.combo = 1 end
  roll.comboAt = now
  if roll.combo > roll.maxCombo then roll.maxCombo = roll.combo end
  if roll.combo >= 2 then roll.comboFx = { x = b.x, y = b.y, t = now, n = roll.combo } end
  return 0.9 * 2 ^ (math.min(roll.combo - 1, 12) / 12)
end

-- 全部潰したときの紙吹雪(spawnConfetti)は下で定義する。達成表示からも使うので先に名前だけ用意する
local spawnConfetti

-- エンドレスロール: 潰した粒の音のおまけと、50個ごとの達成表示(100個ごとは大きく)
local function endlessPop(b, pitch)
  if b.fx == 4 and Sound.playChime then Sound.playChime(pitch) end   -- 星の潰れ方は「キラッ」も鳴る(4粒に1粒くらい)
  local every = stage.milestone
  if every and popped % every == 0 then
    local big = popped % (every * 2) == 0
    roll.milestone = { n = popped, t = love.timer.getTime(), big = big }
    spawnConfetti(big and 90 or 45)
    if Sound.playMilestone then Sound.playMilestone(big) end
  end
end

local function pop(b)
  b.popped, b.t = true, 0
  popped = popped + 1
  local pitch = isEndless() and addCombo(b) or nil
  Sound.playPop(b.snd, pitch)
  if isEndless() then endlessPop(b, pitch) end
  if isRoller() then rollerSettle(b, true) end
end

---------------------------------------------------------------
-- メニューとステージの出入り
---------------------------------------------------------------
local function menuCard(i)
  return 40, 258 + (i - 1) * 110, view.w - 80, 92
end

-- メニュー下部の「記録」「終了」ボタン(スマホには T キーも Esc キーも無いため、タップでも操作できるようにする)
local function recordsButtonRect()
  return view.w / 2 - 164, 706, 150, 36
end

local function quitButtonRect()
  return view.w / 2 + 14, 706, 150, 36
end

-- メニュー上部の色スウォッチ(命中判定の広さの選択)。3つを横に並べる
local function colorSwatch(i)
  local r = 18
  local gap = 84
  local cx = view.w / 2 + (i - 2) * gap
  return cx, 204, r
end

local function colorSwatchHit(mx, my)
  for i, name in ipairs(COLOR_MODES) do
    local cx, cy, r = colorSwatch(i)
    local dx, dy = mx - cx, my - cy
    if dx * dx + dy * dy <= r * r then return name end
  end
end

-- メニュー上部の Lv1 / Lv2 の切り替えタブ
local function levelTab(i)
  return view.w / 2 - MAX_LEVEL * 55 + (i - 1) * 110 + 5, 106, 100, 32
end

local function levelTabHit(mx, my)
  for i = 1, MAX_LEVEL do
    local x, y, w, h = levelTab(i)
    if mx >= x and mx <= x + w and my >= y and my <= y + h then return i end
  end
end

-- 表示中のレベルのステージ(STAGES の番号の一覧)
local function levelStages()
  local t = {}
  for i, s in ipairs(STAGES) do
    if (s.level or 1) == menuLevel then t[#t + 1] = i end
  end
  return t
end

local function menuHit(mx, my)
  for k, idx in ipairs(levelStages()) do
    local x, y, w, h = menuCard(k)
    if mx >= x and mx <= x + w and my >= y and my <= y + h then return idx end
  end
end

local function enterStage(i)
  stage = STAGES[i]
  scene = "play"
  updateView()
  fingerPress, fingerPressV = 0, 0
  Sound.setPitchScale(stage.soundPitch or 1)     -- 大粒は低く長く、小粒は高く短く
  if stage.mode and Sound.prepareJingles then Sound.prepareJingles() end   -- ブザーとファンファーレ
  newSheet()
  love.mouse.setVisible(not useFinger())          -- 指のカーソルを使うステージでは本物のカーソルを隠す
end

-- 記録は色ごとに完全に分ける(Blue/Yellow/Pinkは別のランキング)
local function recId(color)
  return stage.id .. "-" .. (color or colorMode)
end
local function recIdFor(s, color)
  return s.id .. "-" .. color
end

local function exitToMenu()
  scene = "menu"
  love.mouse.setVisible(true)
  pending = {}
  updateView()
end

-- 3桁に満たない分は A で埋める(タップの上下ボタンで必ず文字が見えるようにするため)
local function padInitials(s)
  while #s < 3 do s = s .. "A" end
  return s:sub(1, 3)
end

-- 桁 i の文字を dir(+1/-1)分だけ送る。タップの上下ボタンと、キーボードの上下キーの両方が使う
local function cycleSlot(i, dir)
  initials = padInitials(initials)
  local ch = initials:sub(i, i)
  local idx = INITIAL_CHARS:find(ch, 1, true) or 1
  idx = ((idx - 1 + dir) % #INITIAL_CHARS) + 1
  initials = initials:sub(1, i - 1) .. INITIAL_CHARS:sub(idx, idx) .. initials:sub(i + 1)
end

-- イニシャルを確定して記録する
local function confirmEntry()
  local rank = Records.add(recId(), recordValue(), stage.record.n, initials, colorMode, stage.record.score)
  lastInitials = initials
  entering = false
  finishInfo = { rank = rank }
end

-- 入力せず、記録も残さずに進める
local function skipEntry()
  entering = false
  finishInfo = { rank = nil }
end

---------------------------------------------------------------
-- LÖVE コールバック
---------------------------------------------------------------
-- イニシャル入力パネルの寸法。描画とタップ判定の両方がここから座標を取る
local function entryLayout()
  local lh = msgFont:getHeight()
  local th = titleFont:getHeight()
  local slotW = 60
  local arrowH = 30
  local btnH = 38
  local bw = 380
  local bh = lh * 2 + arrowH + th + arrowH + btnH + 56
  local px = (view.w - bw) / 2
  local py = HUD_H + (playBottom() - HUD_H - bh) / 2
  local x0 = px + (bw - slotW * 3) / 2
  local upY = py + 16 + lh * 2 + 8
  local letterY = upY + arrowH + 4
  local downY = letterY + th + 4
  local slots = {}
  for i = 1, 3 do
    local sx = x0 + (i - 1) * slotW
    slots[i] = {
      x = sx, w = slotW,
      up = { x = sx + 6, y = upY, w = slotW - 12, h = arrowH },
      letterY = letterY,
      down = { x = sx + 6, y = downY, w = slotW - 12, h = arrowH },
    }
  end
  local byy = downY + arrowH + 14
  local okRect = { x = px + bw / 2 - 128, y = byy, w = 116, h = btnH }
  local skipRect = { x = px + bw / 2 + 12, y = byy, w = 116, h = btnH }
  return { px = px, py = py, bw = bw, bh = bh, lh = lh, th = th,
           slots = slots, okRect = okRect, skipRect = skipRect }
end

local function pointIn(r, mx, my)
  return mx >= r.x and mx <= r.x + r.w and my >= r.y and my <= r.y + r.h
end

-- ローラー送りの開始ボタン(指でも押しやすい大きさ)
local START_LABEL = "TAP TO START"
local function startButtonRect()
  local w = msgFont:getWidth(START_LABEL) + 80
  local h = msgFont:getHeight() + 32
  return { x = (view.w - w) / 2, y = 400, w = w, h = h }
end


function love.load()
  love.keyboard.setTextInput(false)     -- 日本語入力(IME)がキーを横取りしないようにする
  love.graphics.setBackgroundColor(0.86, 0.92, 0.96)
  hudFont = love.graphics.newFont(HUD_SIZE)
  msgFont = love.graphics.newFont(MSG_SIZE)
  titleFont = love.graphics.newFont(TITLE_SIZE)
  tinyFont = love.graphics.newFont(13)
  love.math.setRandomSeed(os.time())
  love.audio.setVolume(1.6)             -- 全体的に音が小さいとの要望でマスター音量を底上げ
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
  if scene == "records" then                         -- 記録の画面はクリックで戻る
    scene = "menu"
    return
  end
  if scene == "menu" then
    if button == 1 then
      local c = colorSwatchHit(mx, sy)
      if c then colorMode = c return end
      local lv = levelTabHit(mx, sy)
      if lv then menuLevel = lv return end
      local rx, ry, rw, rh = recordsButtonRect()
      if mx >= rx and mx <= rx + rw and sy >= ry and sy <= ry + rh then scene = "records" return end
      local qx, qy, qw, qh = quitButtonRect()
      if mx >= qx and mx <= qx + qw and sy >= qy and sy <= qy + qh then love.event.quit() return end
      local i = menuHit(mx, sy)
      if i then enterStage(i) end
    end
    return
  end
  if button ~= 1 then return end
  if entering then                                      -- イニシャル入力中はタップで操作する
    local L = entryLayout()
    for i, s in ipairs(L.slots) do
      if pointIn(s.up, mx, sy) then cycleSlot(i, 1) return end
      if pointIn(s.down, mx, sy) then cycleSlot(i, -1) return end
    end
    if pointIn(L.okRect, mx, sy) then confirmEntry() return end
    if pointIn(L.skipRect, mx, sy) then skipEntry() return end
    return
  end
  local barTap = barHit(mx, sy)                         -- 下部のMENU/RESET帯(物理キーが無くても操作できる)
  if barTap == "menu" then exitToMenu() return end
  if barTap == "reset" then newSheet() return end
  if finished then
    if love.timer.getTime() - finishAt > FINISH_LOCK then newSheet() end   -- 終わったらクリックで再挑戦
    return
  end
  if isRoller() and not timing and pointIn(startButtonRect(), mx, sy) then
    timing = true                                       -- 開始ボタン: 送りと時間の計測を始める
    return
  end
  if sy < touchTop() or sy > touchBottom() then return end
  local b = hit(mx, sy + scrollY)
  if b and not b.popped then
    b.press = b.press + rand(0.45, 0.75)              -- 素早いタップでも力が積み重なる(実機のタップに合わせて強めに)
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
  if scene == "records" then
    if key == "escape" or key == "t" or key == "return" then scene = "menu" end
    return
  end
  if scene == "menu" then
    if key == "escape" then love.event.quit() end
    if key == "t" then scene = "records" end
    if key == "b" then colorMode = "blue" end
    if key == "y" then colorMode = "yellow" end
    if key == "p" then colorMode = "pink" end
    if key == "tab" or key == "right" then menuLevel = menuLevel % MAX_LEVEL + 1 end
    if key == "left" then menuLevel = (menuLevel - 2) % MAX_LEVEL + 1 end
    local i = tonumber(key)
    local list = levelStages()
    if i and list[i] then enterStage(list[i]) end
    return
  end
  if entering then                                        -- イニシャル入力中
    -- 画面のタップ(上下ボタン・OK・Skip)がメインだが、キーボードがあれば以下でも操作できる
    if key == "return" or key == "kpenter" then
      confirmEntry()
    elseif key == "escape" then
      skipEntry()
    elseif key == "left" or key == "backspace" then
      entrySlot = math.max(1, entrySlot - 1)
    elseif key == "right" then
      entrySlot = math.min(3, entrySlot + 1)
    elseif key == "up" then
      cycleSlot(entrySlot, 1)
    elseif key == "down" then
      cycleSlot(entrySlot, -1)
    elseif #key == 1 and key:match("^%w$") then
      initials = padInitials(initials)
      initials = initials:sub(1, entrySlot - 1) .. key:upper() .. initials:sub(entrySlot + 1)
      entrySlot = math.min(3, entrySlot + 1)
    end
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

-- ローラーの太さ。巻いてあるシートの長さで変わる(面積は長さに比例するので半径は平方根で)
local function rollerRadii()
  local top = clamp(clipTop() - (sheet.y - scrollY), 0, sheet.h) / sheet.h
  local bot = clamp((sheet.y + sheet.h - scrollY) - clipBottom(), 0, sheet.h) / sheet.h
  local rTop = ROLL_R_MIN + (ROLL_R_MAX - ROLL_R_MIN) * math.sqrt(top)
  local rBot = ROLL_R_MIN + (ROLL_R_MAX * 0.65 - ROLL_R_MIN) * math.sqrt(bot)   -- 潰れた分だけ細い
  return rTop, rBot
end

-- 全部潰したときの紙吹雪(n: 枚数。省略時は CONFETTI_N)。前の紙吹雪が残っていればそこに足す
spawnConfetti = function(n)
  local list = {}
  for _, c in ipairs(roll.confetti) do
    if c.y < view.h + 20 then list[#list + 1] = c end
  end
  roll.confetti = list
  local cols = { { 0.35, 0.60, 0.95 }, { 0.95, 0.80, 0.25 }, { 0.92, 0.45, 0.65 }, { 0.45, 0.85, 0.55 }, { 1, 1, 1 } }
  for i = 1, n or CONFETTI_N do
    roll.confetti[#roll.confetti + 1] = {
      x = rand(0, view.w), y = rand(-view.h * 0.6, -10),
      vx = rand(-40, 40), vy = rand(120, 260),
      a = rand(0, 2 * pi), va = rand(-8, 8), w = rand(5, 10), h = rand(3, 6),
      col = cols[love.math.random(#cols)], sway = rand(0, 2 * pi),
    }
  end
end

-- ローラー送り: シートを下へ送る(scrollY が減るほどシートは下へ動く)。
-- 位置は経過時間から直接決めるので、1コマの長さがばらついても進み方は滑らか
local function updateRoller(dt)
  for _, c in ipairs(roll.confetti) do              -- 紙吹雪(終わったあとも動かす)
    c.sway = c.sway + dt * 3
    c.x = c.x + (c.vx + math.sin(c.sway) * 30) * dt
    c.y = c.y + c.vy * dt
    c.a = c.a + c.va * dt
  end
  if not timing or finished then return end
  local prev = scrollY
  -- elapsed はこのあと love.update の中で dt だけ進むので、進んだあとの時刻で位置を決める
  scrollY = roll.start - rollDistance(math.min(elapsed + dt, roll.limit))
  local d = prev - scrollY                          -- このコマで送った量(px)
  local rTop, rBot = rollerRadii()                  -- ローラーの回転角は、送った量 ÷ 半径 を足していく
  roll.phTop = roll.phTop + d / rTop
  roll.phBot = roll.phBot + d / rBot
  for _, b in ipairs(bubbles) do                     -- 下端を越えた粒は「取りこぼし」(失敗にはしない)
    if not b.cut and not b.popped and not b.missed and b.y - scrollY > ROLL_TOUCH_BOT then
      b.missed = true
      roll.missed = roll.missed + 1
      rollerSettle(b, false)
    end
  end
end

-- ステージの終わり。2つ目の戻り値が true のときは記録しない。
-- ローラー送りは、時間内に全部潰したら「クリア」(ファンファーレ・記録あり)、
-- 制限時間になったら「時間切れ」(ブザー・記録なし)。それ以外のステージは全部潰したら終わり
local function stageDone()
  if not isRoller() then return total > 0 and popped >= total, false end
  if roll.result then return true, roll.result == "timeup" end
  if isEndless() then
    -- エンドレスロール: 制限時間で終わり、潰した個数を記録する。自己ベストを超えたらお祝い
    if elapsed < roll.limit then return false, false end
    elapsed = roll.limit
    roll.result = "end"
    local best = Records.best(recId())
    if popped > 0 and (not best or popped > best) then
      roll.clearAt = love.timer.getTime()
      roll.celebrate = { title = "NEW RECORD!", sub = popped .. " pops!" }
      spawnConfetti()
      if Sound.playFanfare then Sound.playFanfare() end
    elseif Sound.playBuzzer then
      Sound.playBuzzer()
    end
    return true, false
  end
  if total > 0 and popped >= total then
    roll.result = "clear"
    roll.clearAt = love.timer.getTime()
    roll.celebrate = { title = "PERFECT!", sub = "Congratulations!" }
    spawnConfetti()
    if Sound.playFanfare then Sound.playFanfare() end
    return true, false
  end
  if elapsed >= roll.limit then
    roll.result = "timeup"
    elapsed = roll.limit
    if Sound.playBuzzer then Sound.playBuzzer() end
    return true, true
  end
  return false, false
end

-- 粒に触れられる高さか
local function inTouch(sy)
  return sy >= touchTop() and sy <= touchBottom()
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

  if isRoller() then updateRoller(dt) end

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

  -- 指の押し込みはバネで動かす。離した瞬間、勢いで少し戻りすぎて弾む(オーバーな動き)
  do
    local target = down and 1 or 0
    local accel = (target - fingerPress) * FINGER_STIFF - fingerPressV * FINGER_DAMP
    fingerPressV = fingerPressV + accel * dt
    fingerPress = fingerPress + fingerPressV * dt
  end

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
  if down and inTouch(sy) and not finished then target = hit(mx, wy) end
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
      if target.cut then                                -- 半割の粒は絶対に潰れないので、触れた瞬間に必ずボヨーンを鳴らす
        Sound.playBoyoon(0.7)
        target.wobA, target.wobT = 0.7, 0
      else
        local slow = 1 - math.min(1, mspeed / (cell * SWIPE_FAST))
        local force = (0.08 + 0.55 * slow) * rand(0.6, 1.3)
        local gap = now - leftAt
        if gap < CARRY_MAX_GAP then
          local carry = leftP * 0.3 + math.min(leftDwell, 0.6) * 0.3
          force = force + carry * (1 - gap / CARRY_MAX_GAP) * rand(0.7, 1.2)
        end
        target.press = target.press + force
        target.dwell = 0
        Sound.playCreak(0.5 + 0.5 * slow)
      end
    end
    lastTarget = target
  end

  for _, b in ipairs(bubbles) do
    if b.cut then                                      -- 半割の粒: 押されて凹むだけで破裂しない(ボヨーンは触れた瞬間に鳴る)
      if b == target then
        b.press = math.min(0.45, b.press + dt / stage.pressTime * 0.6)
      else
        b.press = math.max(0, b.press - dt / RELEASE_TIME)
      end
      b.wobT = b.wobT + dt
    elseif not b.popped then
      if b == target then
        b.held = true
        b.dwell = b.dwell + dt
        -- 押し込み速度は粒ごとに違い、しかも時間とともに滑らかに揺らぐ
        local wave = 0.80 + 0.7 * love.math.noise(b.seed, now * 3)  -- 下限を上げて反応の鈍さを減らす
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
          if p > 0.15 then                                 -- 軽く触れただけでも弾みの反応を出す(ボヨーンの機会を増やす)
            -- 空気が戻る「ポコッ」は少し遅れて鳴る。揺れも同じタイミングで始める
            later(rand(SPRING_DELAY_MIN, SPRING_DELAY_MAX), function()
              if not b.popped then
                if love.math.random() < 0.35 then
                  Sound.playBoyoon(p)             -- たまにコミカルな「ボヨーン」を鳴らす
                else
                  Sound.playSpring(p)
                end
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

  -- 終わったら記録する(記録のあるステージだけ。ローラー送りの時間切れは記録しない)
  local done, noRecord = stageDone()
  if not finished and done then
    finished = true
    finishAt = now
    local rec = stage.record
    if rec and not noRecord then
      if rec.initials then
        -- 上位に入ったら、イニシャルを入力してから記録する
        entryRank = Records.qualifies(recId(), recordValue(), rec.n, rec.score)
        if entryRank then
          entering, initials, entrySlot = true, padInitials(lastInitials), 1
        else
          finishInfo = { rank = nil }
        end
      else
        local prev = Records.best(recId())
        local rank = Records.add(recId(), recordValue(), rec.n, nil, colorMode, rec.score)
        finishInfo = { prev = prev, rank = rank }
      end
    end
  end
end

---------------------------------------------------------------
-- 描画: 粒
---------------------------------------------------------------
local function drawIntact(b)
  local p = math.min(1, b.press / b.thresh)       -- 破裂までの張り具合 0〜1
  local hk = b.hard and 1.6 or 1.0                -- 伸びる粒ほど大きく変形する
  local r = b.rad
  -- Largeステージの「プルプルした余韻」の感じを他ステージにも揃える。
  -- 見た目の変形量が粒の半径で薄まらないよう、見かけのピクセル量がほぼ一定になるように調整する
  -- (半径が小さい粒ほど比率を大きくする。16px/10pxはLargeの平均半径でだいたい元の係数と一致する基準値)
  local sqFrac = math.max(0.25, math.min(0.55, 16 / r))
  local wobFrac = math.max(0.15, math.min(0.40, 10 / r))
  local s = sqFrac * hk * p                       -- 押しつぶされた量
  local wob = b.wobA * wobFrac * math.sin(b.wobT * 32) * math.exp(-b.wobT * 6.5)  -- 潰れなかった時の弾み
  local rx = 1 + 0.85 * s - wob * 0.7              -- 空気が横へ逃げて横に広がり
  local ry = 1 - s + wob                          -- 縦につぶれる
  local tn = b.tint

  love.graphics.push()
  love.graphics.translate(b.x, b.y)
  love.graphics.scale(rx, ry)

  love.graphics.setColor(0, 0.1, 0.2, 0.14)                     -- 影
  love.graphics.circle("fill", r * 0.12, r * 0.18, r)
  love.graphics.setColor(0.75 + tn, 0.9 + tn, 1, 0.30 + 0.10 * p)  -- 本体(張るほど濃く)
  love.graphics.circle("fill", 0, 0, r)
  if b.col then                                                 -- 虹色のシートの色
    love.graphics.setColor(b.col[1], b.col[2], b.col[3], 0.42 + 0.15 * p)
    love.graphics.circle("fill", 0, 0, r)
  end
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

  if hitFactor() < 1 then                                       -- 触れないと反応しない範囲の目印
    local rgb = COLOR_RGB[colorMode]
    love.graphics.setColor(rgb[1], rgb[2], rgb[3], 0.55)
    love.graphics.setLineWidth(1.5)
    love.graphics.circle("line", b.x, b.y, hitRadiusOf(b))
  end
end

local function drawPopped(b)
  local k = math.min(1, b.t / 0.1)
  local r = b.rad * (1 - 0.20 * k)                              -- 潰れた直後、もう少し大きく縮む
  love.graphics.setColor(0.72, 0.84, 0.92, 0.5)                 -- しぼんだ円盤
  love.graphics.circle("fill", b.x, b.y, r)
  if b.col then                                                 -- 虹色のシートは潰れても淡く色が残る
    love.graphics.setColor(b.col[1], b.col[2], b.col[3], 0.25)
    love.graphics.circle("fill", b.x, b.y, r)
  end
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
  if b.fx == 2 and b.t < 0.30 then                              -- 火花: 放射状に飛ぶ短い線
    local q = b.t / 0.30
    love.graphics.setLineWidth(2.5)
    for i = 1, 8 do
      local a = b.seed + i * pi / 4
      local d0, d1 = b.rad * (0.6 + 1.2 * q), b.rad * (0.9 + 1.6 * q)
      love.graphics.setColor(1, 0.92, 0.55, 1 - q)
      love.graphics.line(b.x + math.cos(a) * d0, b.y + math.sin(a) * d0, b.x + math.cos(a) * d1, b.y + math.sin(a) * d1)
    end
  elseif b.fx == 3 and b.t < 0.45 then                          -- 空気のもや: 小さな粒がふわっと広がる
    local q = b.t / 0.45
    for i = 1, 7 do
      local a = b.seed * 3 + i * 2 * pi / 7
      local d = b.rad * (0.3 + 1.3 * q)
      love.graphics.setColor(1, 1, 1, 0.75 * (1 - q))
      love.graphics.circle("fill", b.x + math.cos(a) * d, b.y + math.sin(a) * d - 10 * q, b.rad * (0.22 - 0.12 * q))
    end
  elseif b.fx == 4 and b.t < 0.35 then                          -- 星: 回りながら縮むキラッとした光
    local q = b.t / 0.35
    local rr = b.rad * (1.5 - 0.9 * q)
    local rot = b.seed + q * 2
    local pts = {}
    for i = 0, 9 do
      local a = rot + i * pi / 5
      local d = (i % 2 == 0) and rr or rr * 0.42
      pts[#pts + 1] = b.x + math.cos(a) * d
      pts[#pts + 1] = b.y + math.sin(a) * d
    end
    love.graphics.setColor(1, 0.95, 0.6, 0.9 * (1 - q))
    love.graphics.polygon("fill", pts)
  elseif b.t < 0.32 then                                        -- 破裂の一瞬の演出(もう少し大きく・長く)
    local q = b.t / 0.32
    love.graphics.setColor(1, 1, 1, 0.95 * (1 - q))
    love.graphics.setLineWidth(3)
    love.graphics.circle("line", b.x, b.y, b.rad * (1 + 1.0 * q))
    if b.t < 0.10 then
      love.graphics.setColor(1, 1, 1, 0.7 * (1 - b.t / 0.10))
      love.graphics.circle("fill", b.x, b.y, b.rad * 1.08)
    end
  end
end

---------------------------------------------------------------
-- 描画: シート(スクロールする層)
---------------------------------------------------------------
-- シートの矩形と、上部の表示エリアより下の範囲が重なる部分にシザーを設定する
local function clipSheet()
  local x0 = math.max(sheet.x, 0)
  local y0 = math.max(sheet.y - scrollY, clipTop())
  local x1 = math.min(sheet.x + sheet.w, view.w)
  local y1 = math.min(sheet.y + sheet.h - scrollY, clipBottom())
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
  local y0, h = HUD_H + 4, playBottom() - HUD_H - 8
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

local function drawPanelFrame(px, py, bw, bh)
  love.graphics.setColor(1, 1, 1, 0.85)
  love.graphics.rectangle("fill", px, py, bw, bh, 14, 14)
  love.graphics.setColor(0.5, 0.75, 0.95, 0.9)
  love.graphics.setLineWidth(1.5)
  love.graphics.rectangle("line", px, py, bw, bh, 14, 14)
end

local function drawFinishPanel()
  local rec = stage.record
  local lh = msgFont:getHeight()
  local items = { { text = "All popped!  " .. fmtTime(elapsed) } }
  if isEndless() then                                           -- エンドレスロール: 潰した個数と最大コンボ
    items = { { text = "TIME UP!" },
              { text = string.format("Popped %d   Max combo %d", popped, roll.maxCombo) } }
  elseif isRoller() and roll.result == "timeup" then           -- ローラー送りの時間切れ: 潰した数と割合
    local rate = total > 0 and math.floor(popped / total * 100 + 0.5) or 0
    items = { { text = "TIME UP!" },
              { text = string.format("Popped %d / %d  (%d%%)", popped, total, rate) } }
  end
  if rec and rec.n == 1 then                                    -- 最高記録だけ残すステージ
    local best = Records.best(recId())
    local text
    if finishInfo and finishInfo.rank == 1 then
      text = finishInfo.prev and ("NEW RECORD!  (prev " .. fmtRecord(stage, finishInfo.prev) .. ")") or "NEW RECORD!"
    else
      text = "BEST  " .. fmtRecord(stage, best)
    end
    items[#items + 1] = { text = text }
  elseif rec then                                               -- 上位を残すステージ: 順位表
    local top = Records.top(recId())
    for i = 1, rec.n do
      local r = top[i]
      items[#items + 1] = {
        row = true, i = i,
        ini = (r and r.initials ~= "") and r.initials or "---",
        time = r and fmtRecord(stage, r.time) or "--",
        col = r and r.color ~= "" and r.color or nil,
        hl = finishInfo ~= nil and finishInfo.rank == i,        -- 今回の記録を目立たせる
      }
    end
  end
  items[#items + 1] = { text = "Tap: retry" }                  -- メニューへは下の MENU ボタンで戻る

  love.graphics.setFont(msgFont)
  local lw = 340
  for _, it in ipairs(items) do
    if it.text then lw = math.max(lw, msgFont:getWidth(it.text)) end
  end
  local bw, bh = lw + 48, lh * #items + 32
  local px = (view.w - bw) / 2
  local py = HUD_H + (playBottom() - HUD_H - bh) / 2
  drawPanelFrame(px, py, bw, bh)
  local y = py + 16
  for _, it in ipairs(items) do
    if it.row then
      if it.hl then
        love.graphics.setColor(0.5, 0.75, 0.95, 0.35)
        love.graphics.rectangle("fill", px + 16, y, bw - 32, lh, 6, 6)
      end
      love.graphics.setColor(0.2, 0.3, 0.4)
      love.graphics.print(it.i .. ".", px + 28, y)
      love.graphics.print(it.ini, px + 84, y)
      if it.col then
        local rgb = COLOR_RGB[it.col]
        love.graphics.setColor(rgb[1], rgb[2], rgb[3], 1)
        love.graphics.circle("fill", px + 152, y + lh * 0.5, 6)
      end
      love.graphics.setColor(0.2, 0.3, 0.4)
      love.graphics.printf(it.time, px, y, bw - 28, "right")
    else
      love.graphics.setColor(0.2, 0.3, 0.4)
      love.graphics.printf(it.text, px, y, bw, "center")
    end
    y = y + lh
  end
end

-- イニシャル入力のパネル(上位に入ったとき)
local function drawEntryButton(r, label, accent)
  love.graphics.setColor(accent and 0.35 or 1, accent and 0.65 or 1, accent and 0.95 or 1, accent and 1 or 0.9)
  love.graphics.rectangle("fill", r.x, r.y, r.w, r.h, 8, 8)
  love.graphics.setColor(0.35, 0.5, 0.7, 0.7)
  love.graphics.setLineWidth(1)
  love.graphics.rectangle("line", r.x, r.y, r.w, r.h, 8, 8)
  love.graphics.setColor(accent and 1 or 0.2, accent and 1 or 0.3, accent and 1 or 0.4)
  love.graphics.printf(label, r.x, r.y + (r.h - hudFont:getHeight()) / 2, r.w, "center")
end

local function drawEntryPanel()
  local L = entryLayout()
  drawPanelFrame(L.px, L.py, L.bw, L.bh)

  love.graphics.setFont(msgFont)
  love.graphics.setColor(0.2, 0.3, 0.4)
  love.graphics.printf("NEW RANK #" .. tostring(entryRank) .. "!", L.px, L.py + 16, L.bw, "center")
  local v = recordValue()
  love.graphics.printf(isScoreStage(stage) and (v .. " pops") or fmtTime(v), L.px, L.py + 16 + L.lh, L.bw, "center")

  love.graphics.setFont(hudFont)
  for i, s in ipairs(L.slots) do                                  -- 桁ごとの上下ボタンと文字
    drawEntryButton(s.up, "▲", i == entrySlot)
    drawEntryButton(s.down, "▼", i == entrySlot)
    love.graphics.setFont(titleFont)
    love.graphics.setColor(0.2, 0.3, 0.4)
    love.graphics.printf(initials:sub(i, i), s.x, s.letterY, s.w, "center")
    love.graphics.setFont(hudFont)
  end

  drawEntryButton(L.okRect, "OK", true)
  drawEntryButton(L.skipRect, "Skip", false)
end

-- 下部のMENU/RESET帯。物理キーボードが無いスマホでも、メニューに戻る・やり直すができるように常設する
local function drawBar()
  local by = playBottom()
  love.graphics.setColor(1, 1, 1, 0.55)
  love.graphics.rectangle("fill", 0, by, view.w, BAR_H)
  love.graphics.setColor(0.5, 0.75, 0.95, 0.6)
  love.graphics.setLineWidth(1)
  love.graphics.line(0, by, view.w, by)
  love.graphics.line(view.w / 2, by, view.w / 2, view.h)
  love.graphics.setFont(hudFont)
  love.graphics.setColor(0.2, 0.3, 0.4)
  love.graphics.printf("MENU", 0, by + (BAR_H - hudFont:getHeight()) / 2, view.w / 2, "center")
  love.graphics.printf("RESET", view.w / 2, by + (BAR_H - hudFont:getHeight()) / 2, view.w / 2, "center")
end

---------------------------------------------------------------
-- 描画: ローラー送りの上下のローラー
---------------------------------------------------------------
-- 横向きの円筒を正面から見た形で描く。phase は回転角(シートの送り量 / 半径)。
-- fresh = true: 上のローラー(まだ潰していない粒が巻いてある) / false: 下のローラー(潰れたシート)
local function drawRoller(cy, r, phase, fresh)
  local x0, w = sheet.x - 4, sheet.w + 8
  -- 軸と、両端の支え
  love.graphics.setColor(0.45, 0.52, 0.60, 0.9)
  love.graphics.rectangle("fill", x0 - 14, cy - 3, w + 28, 6, 3, 3)
  love.graphics.setColor(0.55, 0.62, 0.70, 1)
  love.graphics.rectangle("fill", x0 - 18, cy - 9, 8, 18, 3, 3)
  love.graphics.rectangle("fill", x0 + w + 10, cy - 9, 8, 18, 3, 3)
  -- 本体: 帯を重ねて丸みの陰影を付ける(上が明るく、下が暗い)
  local n = 12
  for i = 0, n - 1 do
    local a0 = -pi / 2 + pi * i / n
    local a1 = -pi / 2 + pi * (i + 1) / n
    local ya, yb = cy + r * math.sin(a0), cy + r * math.sin(a1)
    local lit = 0.55 + 0.45 * math.cos((a0 + a1) / 2 + 0.5)
    if fresh then
      love.graphics.setColor(0.70 * lit + 0.25, 0.86 * lit + 0.12, 0.98, 0.85)
    else
      love.graphics.setColor(0.62 * lit + 0.25, 0.76 * lit + 0.15, 0.88, 0.85)
    end
    love.graphics.rectangle("fill", x0, ya, w, yb - ya + 0.5)
  end
  -- 表面の模様。回転に合わせて正面を上から下へ流れていく
  local k = 10
  for j = 0, k - 1 do
    local a = (phase + j * 2 * pi / k) % (2 * pi) - pi          -- -pi〜pi(0 が正面)
    local depth = math.cos(a)
    if depth > 0.1 then
      local y = cy + r * math.sin(a)
      if fresh then                                              -- 巻いてある粒(つぶつぶ)
        love.graphics.setColor(1, 1, 1, 0.55 * depth)
        for c = 0, stage.cols - 1 do
          local x = sheet.x + (c + 0.5 + (j % 2) * 0.5) * cell
          if x < sheet.x + sheet.w then
            love.graphics.ellipse("fill", x, y, cell * 0.30, cell * 0.30 * depth * (r / ROLL_R_MAX))
          end
        end
      else                                                       -- 潰れたシートのしわ
        love.graphics.setColor(0.35, 0.5, 0.7, 0.35 * depth)
        love.graphics.setLineWidth(1.5)
        love.graphics.line(x0 + 6, y, x0 + w - 6, y + (j % 3 - 1) * 1.5)
      end
    end
  end
  -- 縁取りと光沢
  love.graphics.setColor(0.5, 0.75, 0.95, 0.9)
  love.graphics.setLineWidth(1.5)
  love.graphics.rectangle("line", x0, cy - r, w, 2 * r, 4, 4)
  love.graphics.setColor(1, 1, 1, 0.45)
  love.graphics.rectangle("fill", x0 + 4, cy - r * 0.62, w - 8, math.max(2, r * 0.18), 2, 2)
end

-- 紙吹雪
local function drawConfetti()
  for _, c in ipairs(roll.confetti) do
    if c.y < view.h + 20 then
      love.graphics.push()
      love.graphics.translate(c.x, c.y)
      love.graphics.rotate(c.a)
      love.graphics.setColor(c.col[1], c.col[2], c.col[3], 0.95)
      love.graphics.rectangle("fill", -c.w / 2, -c.h / 2, c.w, c.h * math.abs(math.cos(c.a * 1.7)) + 1)
      love.graphics.pop()
    end
  end
end

-- 全部潰したときのお祝い: 紙吹雪と「PERFECT!」の文字
local function drawCelebration()
  drawConfetti()
  local t = love.timer.getTime() - roll.clearAt
  local k = 1 + 0.08 * math.sin(t * 6) + 0.6 * math.max(0, 1 - t / 0.35)   -- 最初にポンと大きく出て、あとは脈打つ
  love.graphics.setFont(titleFont)
  local text = roll.celebrate.title
  local tw, th = titleFont:getWidth(text), titleFont:getHeight()
  love.graphics.push()
  love.graphics.translate(view.w / 2, HUD_H + 70)
  love.graphics.scale(k)
  love.graphics.setColor(0.2, 0.3, 0.45, 0.35)                                   -- 影
  love.graphics.print(text, -tw / 2 + 3, -th / 2 + 3)
  local hue = t * 2
  love.graphics.setColor(0.95, 0.55 + 0.25 * math.sin(hue), 0.35 + 0.3 * math.sin(hue + 2), 1)
  love.graphics.print(text, -tw / 2, -th / 2)
  love.graphics.pop()
  love.graphics.setFont(msgFont)
  love.graphics.setColor(0.2, 0.3, 0.4)
  love.graphics.printf(roll.celebrate.sub, 0, HUD_H + 70 + th * 0.6, view.w, "center")
end

-- エンドレスロール: 「50 POPS!」の達成表示。ポンと大きく出て、少し上へ動きながら消える
local function drawMilestone()
  local m = roll.milestone
  if not m then return end
  local t = love.timer.getTime() - m.t
  if t > MILESTONE_SHOW then return end
  local fade = math.min(1, (MILESTONE_SHOW - t) / 0.4)
  local k = (m.big and 1.25 or 1.0) * (1 + 0.7 * math.max(0, 1 - t / 0.2)) * (1 + 0.04 * math.sin(t * 10))
  local text = m.n .. " POPS!"
  love.graphics.setFont(titleFont)
  local tw, th = titleFont:getWidth(text), titleFont:getHeight()
  love.graphics.push()
  love.graphics.translate(view.w / 2, 330 - 30 * (t / MILESTONE_SHOW))
  love.graphics.scale(math.min(k, (view.w - 24) / tw))
  love.graphics.setColor(0.2, 0.3, 0.45, 0.4 * fade)
  love.graphics.print(text, -tw / 2 + 3, -th / 2 + 3)
  if m.big then
    love.graphics.setColor(1, 0.72 + 0.15 * math.sin(t * 8), 0.15, fade)              -- 100個ごとは金色
  else
    love.graphics.setColor(0.95, 0.45, 0.65, fade)
  end
  love.graphics.print(text, -tw / 2, -th / 2)
  love.graphics.pop()
  if m.big then
    love.graphics.setFont(msgFont)
    love.graphics.setColor(0.2, 0.3, 0.4, fade)
    love.graphics.printf("Great!", 0, 330 + th * 0.55, view.w, "center")
  end
end

-- エンドレスロール: 潰した粒の上に「5 COMBO」の文字が浮かんで消える
local function drawComboFx()
  local fx = roll.comboFx
  if not fx then return end
  local t = love.timer.getTime() - fx.t
  if t > COMBO_SHOW then return end
  local q = t / COMBO_SHOW
  local y = clamp(fx.y - scrollY - 30 - 40 * q, ROLL_TOUCH_TOP, ROLL_TOUCH_BOT)
  local k = 1 + 0.4 * math.max(0, 1 - t / 0.12)                  -- 出た瞬間だけ少し大きい
  love.graphics.setFont(msgFont)
  local text = fx.n .. " COMBO"
  local tw = msgFont:getWidth(text)
  local x = clamp(fx.x, tw / 2 + 8, view.w - tw / 2 - 8)
  love.graphics.push()
  love.graphics.translate(x, y)
  love.graphics.scale(k)
  love.graphics.setColor(0.2, 0.3, 0.45, 0.5 * (1 - q))
  love.graphics.print(text, -tw / 2 + 2, -msgFont:getHeight() / 2 + 2)
  local hot = math.min(1, fx.n / 12)                              -- コンボが続くほど赤っぽく
  love.graphics.setColor(0.95, 0.75 - 0.4 * hot, 0.25, 1 - q)
  love.graphics.print(text, -tw / 2, -msgFont:getHeight() / 2)
  love.graphics.pop()
end

local function drawRollers()
  local rTop, rBot = rollerRadii()
  -- 上のローラーの下に落ちる薄い影
  for i = 0, 7 do
    love.graphics.setColor(0.1, 0.2, 0.3, 0.10 * (1 - i / 8))
    love.graphics.rectangle("fill", sheet.x, ROLL_TOP_CY + rTop + i, sheet.w, 1)
  end
  drawRoller(ROLL_TOP_CY, rTop, roll.phTop, true)
  drawRoller(ROLL_BOT_CY, rBot, roll.phBot, false)
end

local function drawPlay()
  -- シート(スクロールする層)
  setScissor(0, clipTop(), view.w, clipBottom() - clipTop())
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
  setScissor(0, clipTop(), view.w, clipBottom() - clipTop())
  drawCutEdges()
  love.graphics.pop()
  love.graphics.setScissor()
  if isRoller() then drawRollers() end

  if scrollY > 1 and not isRoller() then                         -- 上部の表示エリアの下に薄い影
    for i = 0, 7 do
      love.graphics.setColor(0.1, 0.2, 0.3, 0.10 * (1 - i / 8))
      love.graphics.rectangle("fill", 0, HUD_H + i, view.w, 1)
    end
  end

  -- 上部の表示: 左=色ドット+潰した数 / 中央=経過時間 / 右=リセットの案内(記録のあるステージは最高記録)
  love.graphics.setFont(hudFont)
  local crgb = COLOR_RGB[colorMode]
  love.graphics.setColor(crgb[1], crgb[2], crgb[3], 1)
  love.graphics.circle("fill", 22, 27, 6)
  love.graphics.setColor(0.2, 0.3, 0.4)
  if isEndless() then                                              -- エンドレスロールは潰した個数だけ
    love.graphics.print(popped .. " pops", 36, 18)
  else
    love.graphics.print(string.format("%d / %d", popped, total), 36, 18)
  end
  local shown = isRoller() and math.max(0, roll.limit - elapsed) or elapsed   -- ローラー送りは残り時間
  love.graphics.printf(fmtTime(shown), 0, 18, view.w, "center")
  if stage.record then
    local best = Records.best(recId())
    love.graphics.printf("BEST " .. fmtRecord(stage, best), 0, 18, view.w - 16, "right")
  else
    love.graphics.printf("[R] reset", 0, 18, view.w - 16, "right")
  end

  drawScrollbar()
  if isRoller() and not timing and not finished then            -- 開始ボタンか粒に触れるまでシートは止まって待つ
    love.graphics.setFont(msgFont)
    local r = startButtonRect()
    love.graphics.setColor(0.35, 0.65, 0.95, 1)
    love.graphics.rectangle("fill", r.x, r.y, r.w, r.h, 14, 14)
    love.graphics.setColor(0.25, 0.45, 0.7, 0.8)
    love.graphics.setLineWidth(1.5)
    love.graphics.rectangle("line", r.x, r.y, r.w, r.h, 14, 14)
    love.graphics.setColor(1, 1, 1)
    love.graphics.printf(START_LABEL, r.x, r.y + (r.h - msgFont:getHeight()) / 2, r.w, "center")
  end
  if not entering then drawBar() end                              -- 入力中はうっかり押さないよう隠す
  if isEndless() then drawComboFx() drawMilestone() end
  if isRoller() and roll.celebrate then drawCelebration() elseif isEndless() then drawConfetti() end
  if entering then drawEntryPanel() elseif finished then drawFinishPanel() end

  if useFinger() then                                            -- 指のカーソル(いちばん手前)
    local mx, sy = mousePos()
    Finger.draw(mx, sy, fingerPress, stage.fingerScale)
  end
end

local function drawMenu()
  love.graphics.setColor(0.2, 0.3, 0.4)
  love.graphics.setFont(titleFont)
  love.graphics.printf("PUCHIPUCHI", 0, 60, view.w, "center")
  love.graphics.setFont(hudFont)
  love.graphics.setColor(0.35, 0.45, 0.55)
  for i = 1, MAX_LEVEL do                                         -- Lv1 / Lv2 の切り替えタブ
    local x, y, w, h = levelTab(i)
    local on = i == menuLevel
    love.graphics.setColor(1, 1, 1, on and 0.95 or 0.45)
    love.graphics.rectangle("fill", x, y, w, h, 10, 10)
    love.graphics.setColor(0.5, 0.75, 0.95, on and 1 or 0.5)
    love.graphics.setLineWidth(on and 2.5 or 1.5)
    love.graphics.rectangle("line", x, y, w, h, 10, 10)
    love.graphics.setColor(0.2, 0.3, 0.4, on and 1 or 0.5)
    love.graphics.printf("Level " .. i, x, y + (h - hudFont:getHeight()) / 2, w, "center")
  end
  love.graphics.setColor(0.35, 0.45, 0.55)
  -- Lv1 では色は命中判定の広さ、Lv2 ではステージごとの難しさ(速度など)
  local what = menuLevel == 1 and "Hit area: " or "Difficulty: "
  love.graphics.printf(what .. COLOR_LABEL[colorMode] .. "  (" .. COLOR_DIFF[colorMode] .. ")",
                       0, 146, view.w, "center")

  for i, name in ipairs(COLOR_MODES) do                          -- 命中判定の広さの選択
    local cx, cy, r = colorSwatch(i)
    local rgb = COLOR_RGB[name]
    love.graphics.setColor(rgb[1], rgb[2], rgb[3], 1)
    love.graphics.circle("fill", cx, cy, r)
    love.graphics.setColor(0.2, 0.3, 0.4, name == colorMode and 0.9 or 0.25)
    love.graphics.setLineWidth(name == colorMode and 3 or 1.5)
    love.graphics.circle("line", cx, cy, r + 4)
    love.graphics.setFont(tinyFont)                              -- 丸の下に難易度の目安を表示
    love.graphics.setColor(0.35, 0.45, 0.55, name == colorMode and 1 or 0.55)
    love.graphics.printf(COLOR_DIFF[name], cx - 42, cy + r + 6, 84, "center")
  end
  love.graphics.setFont(hudFont)

  local mx, my = mousePos()
  local list = levelStages()
  for i, idx in ipairs(list) do
    local s = STAGES[idx]
    local x, y, w, h = menuCard(i)
    local over = mx >= x and mx <= x + w and my >= y and my <= y + h
    love.graphics.setColor(1, 1, 1, over and 0.80 or 0.50)
    love.graphics.rectangle("fill", x, y, w, h, 14, 14)
    love.graphics.setColor(0.5, 0.75, 0.95, 0.9)
    love.graphics.setLineWidth(1.5)
    love.graphics.rectangle("line", x, y, w, h, 14, 14)
    love.graphics.setColor(0.2, 0.3, 0.4)
    love.graphics.setFont(msgFont)
    love.graphics.print(i .. "   " .. s.title, x + 16, y + 10)
    love.graphics.setFont(hudFont)
    love.graphics.setColor(0.35, 0.45, 0.55)
    love.graphics.print(s.sub, x + 20, y + 50)
    if s.record then
      local best = Records.best(recIdFor(s, colorMode))
      local rgb = COLOR_RGB[colorMode]
      love.graphics.setColor(rgb[1], rgb[2], rgb[3], 1)
      love.graphics.circle("fill", x + 18, y + 82, 4)
      love.graphics.setColor(0.30, 0.55, 0.80)
      love.graphics.print("BEST " .. fmtRecord(s, best), x + 30, y + 70)
    end
  end

  love.graphics.setFont(hudFont)
  love.graphics.setColor(0.45, 0.55, 0.65)
  love.graphics.printf("More levels: coming soon", 0, 684, view.w, "center")

  local rx, ry, rw, rh = recordsButtonRect()
  love.graphics.setColor(1, 1, 1, 0.85)
  love.graphics.rectangle("fill", rx, ry, rw, rh, 10, 10)
  love.graphics.setColor(0.5, 0.75, 0.95, 0.9)
  love.graphics.setLineWidth(1.5)
  love.graphics.rectangle("line", rx, ry, rw, rh, 10, 10)
  love.graphics.setColor(0.2, 0.3, 0.4)
  love.graphics.printf("RECORDS", rx, ry + (rh - hudFont:getHeight()) / 2, rw, "center")

  local qx, qy, qw, qh = quitButtonRect()           -- Escキーが無い端末でも終了できる実体のあるボタン
  love.graphics.setColor(1, 1, 1, 0.85)
  love.graphics.rectangle("fill", qx, qy, qw, qh, 10, 10)
  love.graphics.setColor(0.95, 0.55, 0.55, 0.9)
  love.graphics.setLineWidth(1.5)
  love.graphics.rectangle("line", qx, qy, qw, qh, 10, 10)
  love.graphics.setColor(0.45, 0.25, 0.25)
  love.graphics.printf("QUIT", qx, qy + (qh - hudFont:getHeight()) / 2, qw, "center")

  love.graphics.setColor(0.45, 0.55, 0.65)
  love.graphics.printf("Press 1-" .. #list .. " or tap a stage   Tab: level", 0, 758, view.w, "center")
end

-- 記録は色ごとに分かれているので、Blue/Yellow/Pinkを3列に並べて表示する
local function drawRecords()
  love.graphics.setColor(0.2, 0.3, 0.4)
  love.graphics.setFont(titleFont)
  love.graphics.printf("RECORDS  Lv" .. menuLevel, 0, 40, view.w, "center")

  local left = 40
  local colW = (view.w - 2 * left) / 3
  local rowH = tinyFont:getHeight() + 6
  local y = 108

  for _, s in ipairs(STAGES) do
    if s.record and (s.level or 1) == menuLevel then             -- メニューで選んでいるレベルの分だけ
      love.graphics.setFont(msgFont)
      love.graphics.setColor(0.2, 0.3, 0.4)
      love.graphics.print(s.title, left, y)
      y = y + msgFont:getHeight() + 4

      love.graphics.setFont(tinyFont)                             -- 列の見出し(色の丸+難易度)
      for c, name in ipairs(COLOR_MODES) do
        local cx = left + colW * (c - 1)
        local rgb = COLOR_RGB[name]
        love.graphics.setColor(rgb[1], rgb[2], rgb[3], 1)
        love.graphics.circle("fill", cx + 7, y + 7, 5)
        love.graphics.setColor(0.35, 0.45, 0.55)
        love.graphics.print(COLOR_DIFF[name], cx + 18, y)
      end
      y = y + rowH + 2

      for i = 1, s.record.n do                                    -- 色ごとに縦に順位を並べる
        for c, name in ipairs(COLOR_MODES) do
          local cx = left + colW * (c - 1)
          local top = Records.top(recIdFor(s, name))
          local r = top[i]
          local line = i .. ". "
          if s.record.initials then
            line = line .. ((r and r.initials ~= "") and r.initials or "---") .. "  "
          end
          line = line .. (r and fmtRecord(s, r.time) or "--")
          love.graphics.setColor(0.35, 0.45, 0.55)
          love.graphics.print(line, cx, y)
        end
        y = y + rowH
      end
      y = y + 18
    end
  end

  love.graphics.setFont(hudFont)
  love.graphics.setColor(0.45, 0.55, 0.65)
  love.graphics.printf("Click or Esc: back", 0, view.h - 70, view.w, "center")
end

function love.draw()
  if scene == "play" and stage and stage.bg then love.graphics.clear(stage.bg) end   -- ステージごとの背景色
  love.graphics.push()
  love.graphics.translate(view.ox, view.oy)
  love.graphics.scale(view.scale)
  if scene == "menu" then drawMenu()
  elseif scene == "records" then drawRecords()
  else drawPlay() end
  love.graphics.pop()
end
