-- stages.lua: ステージ設定の表
-- ステージを増やすときは、この表に1行足す。
--   id          記録の保存名(records.dat の中で使う)
--   title       メニューに出す名前
--   sub         メニューに出す説明(半角英数字のみ。標準フォントに日本語が無いため)
--   free        true: ウィンドウの大きさに合わせて行数が変わる / false: 画面サイズ固定
--   cols        横の粒の数(偶数行の両端は半割になる)
--   rows        縦の行数(free = false のときだけ使う)
--   maxCell     粒1つ分の最大サイズ(px)。省略時は 64
--   hardRatio   伸びて潰れにくい粒の割合
--   pressTime   押し込みから破裂までの目安(秒)。大きいほど重い
--   finger      true: 親指の形のカーソルを使う(パソコンのみ)
--   fingerScale 親指の大きさの倍率。省略時は 1
--   soundPitch  音の高さの倍率。1より小さいと低く長く(大粒)、大きいと高く短く(小粒)。省略時は 1
--   scroll      true: シートが画面より大きく、スクロールして遊ぶ
--   record      { n = 残す件数, initials = true }。省略するとタイムを記録しない
--               initials = true のときは、上位に入ったらイニシャル(3文字まで)を入力する
--   level       メニューのどのレベルに出すか。省略時は 1
--   mode        省略: Lv1 と同じ(シートを全部潰す)
--               "roller": ローラー送り(Lv2-1)。シートが上から繰り出され、下で巻き取られる
--   time        mode = "roller" のときの制限時間(秒)。色ごとに { blue =, yellow =, pink = }
--               シートは一定の速さで送られ、最後の段がちょうど制限時間で下端に着く
--               Lv2 では色は制限時間などを決め、命中判定はいつも Blue と同じ広さ
--               "endless": エンドレスロール(Lv2-2)。制限時間のあいだ、だんだん速くなるシートを潰す
--   speedFrom   mode = "endless" の送り始めの速さ(px/秒)。色ごと
--   speedTo     mode = "endless" の制限時間ちょうどの速さ(px/秒)。色ごと。シートの長さは自動で決まる
--   record.score  true: タイムではなく潰した個数を記録する(多いほど上)
--   softPop     true: 粒が軽く触れるだけで潰れる
--   popFx       true: 潰れ方を4種類(輪・火花・もや・星)からばらばらにする
--   rainbow     true: シートを虹色にする
--   bg          背景色 { r, g, b }。省略時はいつもの水色
--   milestone   この個数ごとに達成表示とジングル(その2倍ごとは大きく)
--               "stack": 積もるシート(Lv2-3)。粒の入った箱(片)が落ちてきて積もる。最上段に届いたらゲームオーバー
--   clearRule   mode = "stack" で最下列の箱が消える条件。"crushed": 粒を全部潰した(銀色の)箱ですき間なく埋まる
--               "color": 同じ色の箱で埋まる / "any": どの箱でも埋まれば消える
--               "tetris": どの段でも、横一列が箱で埋まれば消える(潰したかは問わない)。色ごとの表にできる
--   rotate      mode = "stack" で true の色は、潰し切った(銀色の)箱を1タッチで90度回せる。色ごとの表
--   spawnTries  mode = "stack" で片を出す場所を何か所試すか(いちばん低く着地する所に出す)
--   time        mode = "stack" で色を省くと、その色は時間制限なし
--   cols        mode = "stack" では色ごとの表にできる(枠の横の粒の数。少ないほど大粒)
--   fallFrom    mode = "stack" の片の落ちる速さ(px/秒)。fallTo まで時間とともに上がる
--   spawnFrom   mode = "stack" の片を出す間隔(秒)。spawnTo まで時間とともに短くなる
--   soundPitch, fingerScale も色ごとの表にできる

-- 潰せる粒の数: 奇数行は cols 個、偶数行は両端が半割なので (cols - 1) 個
local function count(cols, rows)
  return math.ceil(rows / 2) * cols + math.floor(rows / 2) * (cols - 1)
end

local L12_COLS, L12_ROWS = 8, 40     -- 約300粒(画面の約2.5倍の高さ)
local L13L_COLS, L13L_ROWS = 5, 34   -- 大粒: 約150粒(画面の約3.3倍の高さ)
local L13S_COLS, L13S_ROWS = 14, 38  -- 小粒: 約500粒(画面の約1.4倍の高さ)
local L21_COLS, L21_ROWS = 8, 16     -- ローラー送り: 120粒(Blue/Yellow/Pink 共通)

return {
  {
    id = "1-1", title = "Lv1-1  Training",
    sub = "Window size free  /  no record",
    free = true, cols = 8, hardRatio = 0.25, pressTime = 0.20,
    finger = false, scroll = false,
  },
  {
    id = "1-2", title = "Lv1-2  Big",
    sub = "Fixed size  /  " .. count(L12_COLS, L12_ROWS) .. " bubbles  /  scroll",
    free = false, cols = L12_COLS, rows = L12_ROWS, hardRatio = 0.25, pressTime = 0.20,
    finger = true, scroll = true, record = { n = 1 },
  },
  {
    id = "1-3L", title = "Lv1-3  Large",
    sub = count(L13L_COLS, L13L_ROWS) .. " large bubbles  /  top 3",
    free = false, cols = L13L_COLS, rows = L13L_ROWS, maxCell = 96,
    hardRatio = 0.30, pressTime = 0.32,
    finger = true, fingerScale = 1.3, soundPitch = 0.72, scroll = true,
    record = { n = 3, initials = true },
  },
  {
    id = "1-3S", title = "Lv1-3  Small",
    sub = count(L13S_COLS, L13S_ROWS) .. " small bubbles  /  top 3",
    free = false, cols = L13S_COLS, rows = L13S_ROWS, maxCell = 40,
    hardRatio = 0.20, pressTime = 0.15,
    finger = true, fingerScale = 0.7, soundPitch = 1.3, scroll = true,
    record = { n = 3, initials = true },
  },
  {
    id = "2-1", title = "Lv2-1  Roller", level = 2, mode = "roller",
    sub = count(L21_COLS, L21_ROWS) .. " bubbles  /  time limit  /  top 3",
    free = false, cols = L21_COLS, rows = L21_ROWS, hardRatio = 0.15, pressTime = 0.18,
    time = { blue = 60, yellow = 45, pink = 30 },
    finger = true, scroll = false,
    record = { n = 3, initials = true },
  },
  {
    id = "2-2", title = "Lv2-2  Endless", level = 2, mode = "endless",
    sub = "Easy pop  /  combo  /  50, 100...",
    free = false, cols = 8, hardRatio = 0, pressTime = 0.10,
    softPop = true, popFx = true, rainbow = true, bg = { 0.99, 0.93, 0.86 }, milestone = 50,
    time = { blue = 60, yellow = 90, pink = 120 },
    speedFrom = { blue = 22, yellow = 22, pink = 22 },
    speedTo = { blue = 45, yellow = 60, pink = 75 },
    finger = true, scroll = false,
    record = { n = 3, initials = true, score = true },
  },
  {
    id = "2-3", title = "Lv2-3  Stack", level = 2, mode = "stack",
    sub = "Crush & clear lines  /  50, 100...",
    free = false, cols = { blue = 5, yellow = 7, pink = 9 }, maxCell = 96,   -- 大粒 / 中粒 / 小粒
    hardRatio = 0, pressTime = 0.10, softPop = true, popFx = true, milestone = 50,
    clearRule = { blue = "crushed", yellow = "tetris", pink = "crushed" },   -- Yellow だけテトリス式
    rotate = { pink = true },                                   -- Pink だけ、潰し切った箱を1タッチで90度回せる
    time = { blue = 90, yellow = 90 },                          -- Pink は時間制限なし(ゲームオーバーまで)
    fallFrom = 70, fallTo = 130, spawnTries = 4,
    spawnFrom = { blue = 3.0, yellow = 2.4, pink = 2.2 }, spawnTo = { blue = 2.0, yellow = 1.6, pink = 1.4 },
    soundPitch = { blue = 0.75, yellow = 1.0, pink = 1.25 },
    fingerScale = { blue = 1.3, yellow = 1.0, pink = 0.8 },
    bg = { 0.92, 0.91, 0.98 },
    finger = true, scroll = false,
    record = { n = 3, initials = true, score = true },
  },
}
