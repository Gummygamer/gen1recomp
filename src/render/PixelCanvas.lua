-- Render targets measured in real framebuffer pixels.
--
-- love.graphics.newCanvas defaults its `dpiscale` to
-- love.graphics.getDPIScale(), so on a highdpi surface the canvas texture is
-- NOT the size it was asked for: newCanvas(160, 144) on a device reporting a
-- DPI scale of 2.755 allocates a 441x397 texture, and the 160x144 GB scene
-- then renders into it at 2.755 texels per GB pixel.  conf.lua sets
-- t.window.highdpi on Android/iOS (required for Retina), and Android's
-- DisplayMetrics.density is routinely non-integer (1.5, 2.75, ...), so this
-- is the normal mobile case, not an edge case.
--
-- That fractional render breaks the whole premise of Renderer's integer
-- scale pipeline.  Renderer:fitScale() picks a whole number of physical
-- pixels per GB pixel (7 on 1080p) and the composite blit lands on it
-- exactly -- but if the *source* already holds 2.755 texels per GB pixel,
-- some GB pixels are 2 texels wide and some are 3, and the nearest-neighbour
-- upscale turns them into 5 / 7 / 8 physical pixels instead of a uniform 7.
-- Measured on a 1080p density-2.755 fixture, only 43 of 160 columns came out
-- the right width.  Fonts show it worst: their strokes are single pixels.
-- That is issue #208 ("some are noticeably stretched, especially fonts").
--
-- Forcing dpiscale = 1 makes canvas texels the pixels the renderer already
-- believes it is drawing.  getWidth()/getHeight() are unaffected (they always
-- reported the requested size), so no geometry anywhere changes -- only the
-- resolution of the target.  Desktop is unchanged; dpiscale is already 1
-- there because conf.lua sets highdpi on mobile only.
--
-- Exception: a canvas that is deliberately sized in LOVE *units* and blitted
-- back at unit scale 1 (Renderer's presentCanvas) must keep the screen's DPI
-- scale so its texture still covers the framebuffer; it is not built with
-- this helper.

local PixelCanvas = {}

-- One framebuffer pixel per w/h unit by default. `density` is an explicit
-- integer supersampling opt-in; `filter` is applied only when given.
function PixelCanvas.new(w, h, filter, density)
  -- Most engine surfaces intentionally use one texel per logical pixel.
  -- A caller may opt into an integer backing density for artwork that has
  -- more detail than the original Game Boy grid. LOVE keeps w/h as the
  -- logical coordinate space while allocating w*density by h*density texels,
  -- so existing layout, scissors, shaders, and input coordinates do not move.
  density = tonumber(density) or 1
  density = math.max(1, math.min(4, math.floor(density)))
  local canvas = love.graphics.newCanvas(w, h, { dpiscale = density })
  if filter and canvas and canvas.setFilter then
    canvas:setFilter(filter, filter)
  end
  return canvas
end

return PixelCanvas
