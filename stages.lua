-- stages.lua: ステージ設定の表
-- ステージを増やすときは、この表に1行足す。
--   id        記録の保存名(records.dat の中で使う)
--   title     メニューに出す名前
--   sub       メニューに出す説明(半角英数字のみ。標準フォントに日本語が無いため)
--   free      true: ウィンドウの大きさに合わせて行数が変わる / false: 画面サイズ固定
--   cols      横の粒の数(偶数行の両端は半割になる)
--   rows      縦の行数(free = false のときだけ使う)
--   maxCell   粒1つ分の最大サイズ(px)。省略時は 64
--   hardRatio 伸びて潰れにくい粒の割合
--   pressTime 押し込みから破裂までの目安(秒)。大きいほど重い
--   finger    true: 指の形のカーソルを使う(パソコンのみ)
--   scroll    true: シートが画面より大きく、スクロールして遊ぶ
--   record    { n = 残す件数 }。省略するとタイムを記録しない

-- Lv1-2 の粒の数: 奇数行は cols 個、偶数行は両端が半割なので (cols - 1) 個が潰せる
local L12_COLS, L12_ROWS = 8, 40
local L12_COUNT = math.ceil(L12_ROWS / 2) * L12_COLS + math.floor(L12_ROWS / 2) * (L12_COLS - 1)

return {
  {
    id = "1-1", title = "Lv1-1  Training",
    sub = "Window size free  /  no record",
    free = true, cols = 8, hardRatio = 0.25, pressTime = 0.30,
    finger = false, scroll = false,
  },
  {
    id = "1-2", title = "Lv1-2  Big Sheet",
    sub = "Fixed size  /  " .. L12_COUNT .. " bubbles  /  scroll",
    free = false, cols = L12_COLS, rows = L12_ROWS, hardRatio = 0.25, pressTime = 0.30,
    finger = true, scroll = true, record = { n = 1 },
  },
}
