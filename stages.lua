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
}
