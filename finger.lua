-- finger.lua: 親指の形のカーソル(画像ファイルは使わず、図形とメッシュだけで描く)
-- 指先がマウスの位置。押している間は少し沈み、影が近づき、爪が白くなる(実際の親指と同じ)
-- 手の残りは描かず、根元は薄れて消える
--
-- 調整のしかた
--   FW              親指の太さ。大きいほど太い
--   FADE0, FADE1    指先から FADE0 までは不透明で、FADE1 までに透明になる。小さいほど短く見える
--   ANGLE           親指の向き。大きいほど真下に近く、小さいほど横に寝る
--   SQUASH_LEN/WIDE 押したときに潰れる量。長さ方向に縮み、幅方向に広がる(大きいほどオーバーに潰れる)
--   SINK            押したときに指が沈む距離(px)

local Finger = {}

local pi = math.pi
local FW = 50                 -- 親指の太さ(px)
local FADE0, FADE1 = 60, 155  -- 指先から FADE0 までは不透明、FADE1 までに透明になる
local STEP = 4                -- メッシュの分割の細かさ(px)
local ANGLE = math.rad(52)    -- 親指の向き(指先から右下へ伸びる)
local SQUASH_LEN, SQUASH_WIDE = 0.30, 0.48   -- 押したときの潰れ量(長さ方向/幅方向)
local SINK = 9                -- 押したときに沈む距離(px)

local parts = nil             -- 最初に描くときに作るメッシュ

-- 指先からの距離 x での不透明度(1〜0)
local function fade(x)
  if x <= FADE0 then return 1 end
  if x >= FADE1 then return 0 end
  return 1 - (x - FADE0) / (FADE1 - FADE0)
end

-- 指の軸に沿った帯(y が ya〜yb)。根元へ向かって透明になる
-- x0: 帯の始まり / fadeIn: true なら始まりも透明から滑らかに立ち上げる
local function strip(ya, yb, r, g, b, a, x0, fadeIn)
  local v = {}
  local x = x0
  while true do
    local al = a * fade(x)
    if fadeIn then al = al * math.min(1, (x - x0) / 14) end
    v[#v + 1] = { x, ya, 0, 0, r, g, b, al }
    v[#v + 1] = { x, yb, 0, 0, r, g, b, al }
    if x >= FADE1 then break end
    x = math.min(x + STEP, FADE1)
  end
  return love.graphics.newMesh(v, "strip", "static")
end

local function build()
  local c = FW / 2          -- 指先の丸みの中心(指先から c の位置)
  parts = {
    shadow  = strip(-FW / 2, FW / 2, 0, 0.08, 0.16, 0.20, c, false),
    body    = strip(-FW / 2, FW / 2, 0.96, 0.80, 0.68, 1, c, false),
    shade   = strip(FW * 0.10, FW * 0.42, 0.85, 0.62, 0.50, 0.55, FW * 0.35, true),
    light   = strip(-FW * 0.44, -FW * 0.34, 1, 0.95, 0.90, 0.45, FW * 0.35, true),
    edgeTop = strip(-FW / 2, -FW / 2 + 1.5, 0.55, 0.36, 0.28, 0.85, c, false),
    edgeBot = strip(FW / 2 - 1.5, FW / 2, 0.55, 0.36, 0.28, 0.85, c, false),
  }
end

-- x, y: 指先の位置 / press: 0(離している)〜1(押している) / scale: 大きさの倍率(省略時は 1)
function Finger.draw(x, y, press, scale)
  local k = scale or 1
  if not parts then build() end
  local c = FW / 2
  local p = math.max(0, math.min(1.3, press))      -- 離した直後の弾みで一瞬 1 を超えることがある
  local sqLen = 1 - SQUASH_LEN * p                  -- 指の長さ方向: 潰れて縮む
  local sqWide = 1 + SQUASH_WIDE * p                -- 指の幅方向: 潰れて広がる
  local dy = SINK * p * k

  -- 影(押すほど指に近づいて濃くなり、指の潰れに合わせて広がる)
  local so = 18 - 11 * p
  love.graphics.push()
  love.graphics.translate(x + so * 0.6 * k, y + so * k)
  love.graphics.rotate(ANGLE)
  love.graphics.scale(sqLen * k, sqWide * k)
  love.graphics.setColor(0, 0.08, 0.16, 0.10 + 0.12 * p)
  love.graphics.circle("fill", c, 0, c)
  love.graphics.setColor(1, 1, 1, 0.5 + 0.5 * p)
  love.graphics.draw(parts.shadow)
  love.graphics.pop()

  -- 親指
  love.graphics.push()
  love.graphics.translate(x, y + dy)
  love.graphics.rotate(ANGLE)
  love.graphics.scale(sqLen * k, sqWide * k)

  love.graphics.setColor(0.96, 0.80, 0.68)                        -- 肌の色(指先の丸み)
  love.graphics.circle("fill", c, 0, c)
  love.graphics.setColor(1, 1, 1, 1)                              -- 肌の色(指の胴)と陰・ハイライト
  love.graphics.draw(parts.body)
  love.graphics.draw(parts.shade)
  love.graphics.draw(parts.light)
  love.graphics.draw(parts.edgeTop)
  love.graphics.draw(parts.edgeBot)
  love.graphics.setColor(1, 0.95, 0.90, 0.35)                     -- 指先のつや
  love.graphics.ellipse("fill", FW * 0.32, -FW * 0.30, FW * 0.16, FW * 0.07)
  love.graphics.setColor(0.55, 0.36, 0.28, 0.85)                  -- 指先の輪郭(左半円)
  love.graphics.setLineWidth(1.5)
  love.graphics.arc("line", "open", c, 0, c, pi / 2, 3 * pi / 2)

  -- 爪(押すと血の気が引いて白くなる)。親指なので幅広で四角に近い
  love.graphics.setColor(1, 0.86 + 0.12 * p, 0.84 + 0.14 * p)
  love.graphics.rectangle("fill", FW * 0.26, -FW * 0.33, FW * 0.92, FW * 0.66, FW * 0.24, FW * 0.24)
  love.graphics.setColor(0.80, 0.60, 0.55, 0.70)
  love.graphics.setLineWidth(1)
  love.graphics.rectangle("line", FW * 0.26, -FW * 0.33, FW * 0.92, FW * 0.66, FW * 0.24, FW * 0.24)
  love.graphics.setColor(1, 1, 1, 0.75)                           -- 爪のつや
  love.graphics.ellipse("fill", FW * 0.60, -FW * 0.16, FW * 0.22, FW * 0.06)

  -- 関節のしわ(根元に向かって薄れる)。ローカル変数名がスケールの k と被らないよう jk にしている
  for _, jk in ipairs({ 1.75, 1.95 }) do
    love.graphics.setColor(0.70, 0.50, 0.42, 0.35 * fade(FW * jk))
    love.graphics.line(FW * jk, -FW * 0.30, FW * jk + 3, 0, FW * jk, FW * 0.30)
  end

  love.graphics.pop()
end

return Finger
