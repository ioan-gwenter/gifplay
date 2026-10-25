--[[
  gifplay.lua  -  play a GIF on a CC:Tweaked monitor

  Usage:
    gifplay <url> [textScale] [monitor] [-d] [-n loops]

    url        Tenor or Klipy page link, a share link, or a direct .gif link
    textScale  0.5 (default, highest resolution) .. 5
    monitor    peripheral name or side (default: first monitor found)
    -d         ordered dithering (smoother gradients, noisier edges)
    -n loops   stop after this many loops (default: loop forever)

  Press Q on the computer (or Ctrl+T) to stop.
]]

local args = { ... }
local unpack = table.unpack or unpack
local floor, min, max = math.floor, math.min, math.max

-------------------------------------------------------------------------------
-- Arguments
-------------------------------------------------------------------------------
local url, textScale, monName, dither, maxLoops = nil, 0.5, nil, false, nil
do
  local i = 1
  while i <= #args do
    local a = args[i]
    if a == "-d" then dither = true
    elseif a == "-n" then i = i + 1; maxLoops = tonumber(args[i])
    elseif not url then url = a
    elseif tonumber(a) then textScale = tonumber(a)
    else monName = a end
    i = i + 1
  end
end
if not url then
  print("Usage: gifplay <url> [textScale] [monitor] [-d] [-n loops]")
  return
end

-------------------------------------------------------------------------------
-- Yield helper
-------------------------------------------------------------------------------
local lastYield = os.epoch("utc")
local function maybeYield()
  local now = os.epoch("utc")
  if now - lastYield > 2500 then
    os.queueEvent("gifplay_yield")
    os.pullEvent("gifplay_yield")
    lastYield = os.epoch("utc")
  end
end

-------------------------------------------------------------------------------
-- Download + link resolution
-------------------------------------------------------------------------------
local UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " ..
           "(KHTML, like Gecko) Chrome/124.0 Safari/537.36"

local function fetch(u)
  local h, err, resp = http.get({
    url = u, binary = true,
    headers = { ["User-Agent"] = UA, ["Accept"] = "image/gif,text/html,*/*" },
  })
  if not h then
    if resp then resp.close() end
    return nil, err
  end
  local body = h.readAll()
  h.close()
  return body
end

local function isGif(b) return b and b:sub(1, 4) == "GIF8" end

local function resolveGif(u)
  if not u:match("^https?://") then u = "https://" .. u end
  print("Fetching " .. u)
  local body, err = fetch(u)
  if not body then error("Download failed: " .. tostring(err), 0) end
  if isGif(body) then return body end

  
  local html = body:gsub("\\u002[Ff]", "/"):gsub("\\/", "/")
  local og = html:match('property="og:image"%s+content="([^"]+)"')
          or html:match('content="([^"]+)"%s+property="og:image"')

  local seen, cands = {}, {}
  local function add(c, score)
    c = c:gsub("&amp;", "&")
    if seen[c] then seen[c].score = max(seen[c].score, score); return end
    local e = { url = c, score = score, order = #cands }
    seen[c] = e
    cands[#cands + 1] = e
  end
  local function hostScore(c)
    local s = 0
    if c:find("tenor%.com") or c:find("klipy") then s = s + 3 end
    
    if c:find("tiny") or c:find("nano") or c:find("preview") then s = s - 2 end
    return s
  end

  if og and og:lower():match("%.gif") then add(og, 5 + hostScore(og)) end
  for c in html:gmatch("https?://[^\"'%s<>\\]+%.gif") do add(c, hostScore(c)) end

  
  if #cands == 0 then
    for c in html:gmatch("https?://[^\"'%s<>\\]+%.webp") do
      if c:find("tenor") or c:find("klipy") then add(c:gsub("%.webp$", ".gif"), -1) end
    end
    if u:find("tenor%.com/view/") then add(u:gsub("[?#].*$", "") .. ".gif", -2) end
  end

  table.sort(cands, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    return a.order < b.order
  end)

  for i = 1, min(#cands, 6) do
    print("Trying " .. cands[i].url)
    local b = fetch(cands[i].url)
    if isGif(b) then return b end
  end
  error("Couldn't find a GIF on that page. Try the direct .gif link " ..
        "(right-click the GIF > Copy image address).", 0)
end

-------------------------------------------------------------------------------
-- GIF decoding
-------------------------------------------------------------------------------

local function readColorTable(s, pos, n)
  local t = {}
  for i = 0, n - 1 do
    local r, g, b = s:byte(pos, pos + 2)
    t[i] = floor(r / 8) * 1024 + floor(g / 8) * 32 + floor(b / 8)
    pos = pos + 3
  end
  return t, pos
end

local POW2 = {}
for i = 0, 24 do POW2[i] = 2 ^ i end


local function lzwDecode(data, minCode, npix, out)
  local clear = POW2[minCode]
  local eoi = clear + 1
  for i = 0, clear - 1 do prefix[i] = -1; suffix[i] = i; first[i] = i; len[i] = 1 end

  local codeSize = minCode + 1
  local codeMask = POW2[codeSize]
  local nextCode = eoi + 1
  local prev = -1
  local buf, nbits = 0, 0
  local dpos, dlen = 1, #data
  local op = 0                     
  local sbyte = string.byte

  while op < npix do
    while nbits < codeSize do
      if dpos > dlen then return op end
      buf = buf + sbyte(data, dpos) * POW2[nbits]
      dpos = dpos + 1
      nbits = nbits + 8
    end
    local code = buf % codeMask
    buf = (buf - code) / codeMask
    nbits = nbits - codeSize

    if code == clear then
      codeSize = minCode + 1
      codeMask = POW2[codeSize]
      nextCode = eoi + 1
      prev = -1
    elseif code == eoi then
      break
    else
      if prev == -1 then
        if code >= clear then return op end       -- corrupt stream
        op = op + 1
        out[op] = code
      else
        local k
        if code < nextCode then k = first[code]
        elseif code == nextCode then k = first[prev]
        else return op end                        -- corrupt stream
        if nextCode < 4096 then
          prefix[nextCode] = prev
          suffix[nextCode] = k
          first[nextCode] = first[prev]
          len[nextCode] = len[prev] + 1
          nextCode = nextCode + 1
          if nextCode == codeMask and codeSize < 12 then
            codeSize = codeSize + 1
            codeMask = POW2[codeSize]
          end
        end
        -- write the string for `code` backwards
        local l = len[code]
        if op + l > npix then l = npix - op end
        local p = op + len[code]
        local c = code
        while c ~= -1 do
          if p <= npix then out[p] = suffix[c] end
          p = p - 1
          c = prefix[c]
        end
        op = op + l
      end
      prev = code
    end
  end
  return op
end


local function decodeGif(s, onInfo, onFrame)
  local sig = s:sub(1, 6)
  if sig ~= "GIF87a" and sig ~= "GIF89a" then error("Not a GIF file", 0) end
  local function u16(p) local a, b = s:byte(p, p + 1); return a + b * 256 end

  local W, H = u16(7), u16(9)
  local packed = s:byte(11)
  local pos = 14
  local gct
  if packed >= 128 then gct, pos = readColorTable(s, pos, POW2[packed % 8 + 1]) end
  onInfo(W, H)

  local npixCanvas = W * H
  local canvas = {}
  for i = 1, npixCanvas do canvas[i] = 0 end

  local out = {}
  local gDelay, gTrans, gDisposal = 10, -1, 0
  local slen = #s

  while pos <= slen do
    local b = s:byte(pos)
    if b == 0x21 then                                  
      local label = s:byte(pos + 1)
      pos = pos + 2
      if label == 0xF9 then
        local p2 = s:byte(pos + 1)
        gDisposal = floor(p2 / 4) % 8
        gDelay = u16(pos + 2)
        gTrans = (p2 % 2 == 1) and s:byte(pos + 4) or -1
      end
      while true do                                     `
        local l = s:byte(pos); pos = pos + 1
        if not l or l == 0 then break end
        pos = pos + l
      end

    elseif b == 0x2C then                               -- image
      local left, top, fw, fh = u16(pos + 1), u16(pos + 3), u16(pos + 5), u16(pos + 7)
      local p2 = s:byte(pos + 9)
      local interlaced = floor(p2 / 64) % 2 == 1
      pos = pos + 10
      local ct = gct
      if p2 >= 128 then ct, pos = readColorTable(s, pos, POW2[p2 % 8 + 1]) end
      if not ct then error("GIF has no colour table", 0) end
      local minCode = s:byte(pos); pos = pos + 1

      local parts = {}
      while true do
        local l = s:byte(pos); pos = pos + 1
        if not l or l == 0 then break end
        parts[#parts + 1] = s:sub(pos, pos + l - 1)
        pos = pos + l
      end
      local data = table.concat(parts)
      parts = nil

      local npix = fw * fh
      local got = lzwDecode(data, minCode, npix, out)
      for i = got + 1, npix do out[i] = -2 end      -- missing pixels: leave as-is
      maybeYield()

      -- row order (interlace)
      local rows = {}
      if interlaced then
        local r = 0
        for _, pass in ipairs({ { 0, 8 }, { 4, 8 }, { 2, 4 }, { 1, 2 } }) do
          for y = pass[1], fh - 1, pass[2] do rows[r] = y; r = r + 1 end
        end
      else
        for y = 0, fh - 1 do rows[y] = y end
      end

      -- save region for "restore to previous"
      local saved
      if gDisposal == 3 then
        saved = {}
        for y = 0, fh - 1 do
          local cy = top + y
          if cy < H then
            for x = 0, fw - 1 do
              if left + x < W then saved[y * fw + x] = canvas[cy * W + left + x + 1] end
            end
          end
        end
      end

      -- composite
      local xmax = min(fw, W - left) - 1
      for r = 0, fh - 1 do
        local cy = top + rows[r]
        if cy < H then
          local base = cy * W + left + 1
          local src = r * fw + 1
          for x = 0, xmax do
            local idx = out[src + x]
            if idx ~= gTrans then
              local c = ct[idx]
              if c then canvas[base + x] = c end
            end
          end
        end
      end

      onFrame(canvas, gDelay)
      maybeYield()

      -- disposal
      if gDisposal == 2 then
        for y = 0, fh - 1 do
          local cy = top + y
          if cy < H then
            for x = 0, xmax do canvas[cy * W + left + x + 1] = 0 end
          end
        end
      elseif gDisposal == 3 then
        for y = 0, fh - 1 do
          local cy = top + y
          if cy < H then
            for x = 0, xmax do
              local v = saved[y * fw + x]
              if v then canvas[cy * W + left + x + 1] = v end
            end
          end
        end
      end
      gDelay, gTrans, gDisposal = 10, -1, 0

    elseif b == 0x3B then
      break
    else
      break                                             -- junk / truncated
    end
  end
end

-------------------------------------------------------------------------------
-- Palette 
-------------------------------------------------------------------------------

local function cdist(r1, g1, b1, r2, g2, b2)
  local dr, dg, db = r1 - r2, g1 - g2, b1 - b2
  return 2 * dr * dr + 4 * dg * dg + 3 * db * db
end

local function buildPalette(hist)
  local ents = {}
  for code = 0, 32767 do
    local n = hist[code + 1]
    if n > 0 then
      ents[#ents + 1] = { floor(code / 1024), floor(code / 32) % 32, code % 32, n }
    end
  end
  if #ents <= 16 then
    local pal = {}
    for i, e in ipairs(ents) do pal[i] = { e[1], e[2], e[3] } end
    while #pal < 16 do pal[#pal + 1] = { 0, 0, 0 } end
    return pal
  end

  local function boxStats(box)
    local lo, hi, total = { 99, 99, 99 }, { -1, -1, -1 }, 0
    for _, e in ipairs(box) do
      for c = 1, 3 do
        if e[c] < lo[c] then lo[c] = e[c] end
        if e[c] > hi[c] then hi[c] = e[c] end
      end
      total = total + e[4]
    end
    local ch, range = 1, -1
    for c = 1, 3 do
      local w = (c == 2) and 1.2 or 1           -- green matters a bit more
      if (hi[c] - lo[c]) * w > range then range = (hi[c] - lo[c]) * w; ch = c end
    end
    return ch, range, total
  end

  local boxes = { ents }
  while #boxes < 16 do
    local best, bestScore, bestCh = nil, -1, 1
    for i, box in ipairs(boxes) do
      if #box > 1 then
        local ch, range, total = boxStats(box)
        local score = range * math.sqrt(total)
        if score > bestScore then best, bestScore, bestCh = i, score, ch end
      end
    end
    if not best or bestScore <= 0 then break end
    local box = boxes[best]
    table.sort(box, function(a, b) return a[bestCh] < b[bestCh] end)
    local _, _, total = boxStats(box)
    local acc, cut = 0, 1
    for i, e in ipairs(box) do
      acc = acc + e[4]
      if acc >= total / 2 then cut = i; break end
    end
    if cut >= #box then cut = #box - 1 end
    local a, b2 = {}, {}
    for i, e in ipairs(box) do if i <= cut then a[#a + 1] = e else b2[#b2 + 1] = e end end
    boxes[best] = a
    boxes[#boxes + 1] = b2
    maybeYield()
  end

  local pal = {}
  for i, box in ipairs(boxes) do
    local sr, sg, sb, n = 0, 0, 0, 0
    for _, e in ipairs(box) do
      sr = sr + e[1] * e[4]; sg = sg + e[2] * e[4]; sb = sb + e[3] * e[4]; n = n + e[4]
    end
    pal[i] = { sr / n, sg / n, sb / n }
  end

  -- k-means refinement
  for _ = 1, 4 do
    local acc = {}
    for i = 1, #pal do acc[i] = { 0, 0, 0, 0 } end
    for _, e in ipairs(ents) do
      local bi, bd = 1, math.huge
      for i = 1, #pal do
        local p = pal[i]
        local d = cdist(e[1], e[2], e[3], p[1], p[2], p[3])
        if d < bd then bd, bi = d, i end
      end
      local a = acc[bi]
      a[1] = a[1] + e[1] * e[4]; a[2] = a[2] + e[2] * e[4]
      a[3] = a[3] + e[3] * e[4]; a[4] = a[4] + e[4]
    end
    for i = 1, #pal do
      local a = acc[i]
      if a[4] > 0 then pal[i] = { a[1] / a[4], a[2] / a[4], a[3] / a[4] } end
    end
    maybeYield()
  end
  while #pal < 16 do pal[#pal + 1] = { 0, 0, 0 } end
  return pal
end

-------------------------------------------------------------------------------
-- Rendering to teletext blit strings
-------------------------------------------------------------------------------
local HEX = {}
for i = 0, 15 do HEX[i] = ("0123456789abcdef"):sub(i + 1, i + 1) end
local CHR = {}
for i = 128, 159 do CHR[i] = string.char(i) end

local BAYER = { [0] = 0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5 }

local function makeRenderer(pal, tw, th)
  local lut = {}
  local function nearest(code)
    local r, g, b = floor(code / 1024), floor(code / 32) % 32, code % 32
    local bi, bd = 0, math.huge
    for i = 1, 16 do
      local p = pal[i]
      local d = cdist(r, g, b, p[1], p[2], p[3])
      if d < bd then bd, bi = d, i - 1 end
    end
    lut[code] = bi
    return bi
  end

  
  local D = {}
  for a = 0, 15 do
    for b = 0, 15 do
      local p, q = pal[a + 1], pal[b + 1]
      D[a * 16 + b] = cdist(p[1], p[2], p[3], q[1], q[2], q[3])
    end
  end

  local idx = {}
  local cw, chh = tw / 2, th / 3
  local cnt, seenList = {}, {}
  for i = 0, 15 do cnt[i] = 0 end

  local function pixelsToIdx(str)
    local sbyte = string.byte
    local i = 0
    for y = 0, th - 1 do
      for x = 0, tw - 1 do
        i = i + 1
        local lo, hi = sbyte(str, 2 * i - 1, 2 * i)
        local code = lo + hi * 256
        if dither then
          local off = (BAYER[(y % 4) * 4 + x % 4] - 7.5) * 0.25   -- ±~2 levels
          local r = floor(code / 1024) + off
          local g = floor(code / 32) % 32 + off
          local b = code % 32 + off
          r = r < 0 and 0 or (r > 31 and 31 or floor(r + 0.5))
          g = g < 0 and 0 or (g > 31 and 31 or floor(g + 0.5))
          b = b < 0 and 0 or (b > 31 and 31 or floor(b + 0.5))
          code = r * 1024 + g * 32 + b
        end
        idx[i] = lut[code] or nearest(code)
      end
    end
  end

  -- returns rows = { {text, fg, bg}, ... }
  return function(str)
    pixelsToIdx(str)
    local rows = {}
    local px = { 0, 0, 0, 0, 0, 0 }
    for cy = 0, chh - 1 do
      local tT, tF, tB = {}, {}, {}
      local rowBase = cy * 3 * tw
      for cx = 0, cw - 1 do
        local o = rowBase + cx * 2 + 1
        px[1], px[2] = idx[o], idx[o + 1]
        px[3], px[4] = idx[o + tw], idx[o + tw + 1]
        px[5], px[6] = idx[o + 2 * tw], idx[o + 2 * tw + 1]

        -- distinct colours in the cell
        local nd = 0
        for k = 1, 6 do
          local c = px[k]
          if cnt[c] == 0 then nd = nd + 1; seenList[nd] = c end
          cnt[c] = cnt[c] + 1
        end

        local ca, cb
        if nd == 1 then
          ca, cb = px[1], px[1]
        elseif nd == 2 then
          ca, cb = seenList[1], seenList[2]
        else
          -- pick the colour pair with the least total error
          local bestE = math.huge
          for i = 1, nd - 1 do
            local a = seenList[i]
            for j = i + 1, nd do
              local b = seenList[j]
              local e = 0
              for k = 1, nd do
                local c = seenList[k]
                local da, db = D[a * 16 + c], D[b * 16 + c]
                e = e + (da < db and da or db) * cnt[c]
              end
              if e < bestE then bestE, ca, cb = e, a, b end
            end
          end
        end
        for k = 1, nd do cnt[seenList[k]] = 0 end

      
        local bg, fg
        local c6 = px[6]
        if D[ca * 16 + c6] <= D[cb * 16 + c6] then bg, fg = ca, cb else bg, fg = cb, ca end
        local ch = 128
        local bit = 1
        for k = 1, 5 do
          local c = px[k]
          if D[fg * 16 + c] < D[bg * 16 + c] then ch = ch + bit end
          bit = bit * 2
        end
        local n = cx + 1
        tT[n] = CHR[ch]; tF[n] = HEX[fg]; tB[n] = HEX[bg]
      end
      rows[cy + 1] = { table.concat(tT), table.concat(tF), table.concat(tB) }
    end
    return rows
  end
end

-------------------------------------------------------------------------------
-- Main
-------------------------------------------------------------------------------
local mon
if monName then mon = peripheral.wrap(monName)
else mon = peripheral.find("monitor") end
if not mon then error("No monitor found. Attach one or pass its name.", 0) end
mon.setTextScale(textScale)
local mw, mh = mon.getSize()

local gifData = resolveGif(url)
print(("Downloaded %d bytes"):format(#gifData))

local tw, th, sx, sy, gw
local hist = {}
for i = 1, 32768 do hist[i] = 0 end
local rawFrames, delays = {}, {}
local byteBuf = {}

decodeGif(gifData,
  function(W, H)
    gw = W
    local scale = min(mw * 2 / W, mh * 3 / H)
    tw = max(2, floor(W * scale / 2) * 2)
    th = max(3, floor(H * scale / 3) * 3)
    sx, sy = {}, {}
    for x = 0, tw - 1 do sx[x] = min(W - 1, floor((x + 0.5) * W / tw)) end
    for y = 0, th - 1 do sy[y] = min(H - 1, floor((y + 0.5) * H / th)) end
    print(("GIF %dx%d -> %dx%d px on %dx%d monitor"):format(W, H, tw, th, mw, mh))
  end,
  function(canvas, delay)
    local n = 0
    for y = 0, th - 1 do
      local rowOff = sy[y] * gw + 1
      for x = 0, tw - 1 do
        local c = canvas[rowOff + sx[x]]
        hist[c + 1] = hist[c + 1] + 1
        byteBuf[n + 1] = c % 256
        byteBuf[n + 2] = floor(c / 256)
        n = n + 2
      end
    end
    local chunks = {}
    for i = 1, n, 4096 do
      chunks[#chunks + 1] = string.char(unpack(byteBuf, i, min(i + 4095, n)))
    end
    rawFrames[#rawFrames + 1] = table.concat(chunks)
    -- browsers treat 0-1cs delays as 10cs
    delays[#delays + 1] = (delay < 2) and 100 or delay * 10
    if #rawFrames % 5 == 0 then print("Decoded " .. #rawFrames .. " frames") end
  end)
gifData = nil
if #rawFrames == 0 then error("GIF contained no frames", 0) end
print("Decoded " .. #rawFrames .. " frames, building palette...")

local pal = buildPalette(hist)
hist = nil

local render = makeRenderer(pal, tw, th)
local frames = {}
for i = 1, #rawFrames do
  frames[i] = render(rawFrames[i])
  rawFrames[i] = nil
  maybeYield()
end
print("Rendered. Playing - press Q to stop.")

local ox = floor((mw - tw / 2) / 2) + 1
local oy = floor((mh - th / 3) / 2) + 1

-- darkest palette entry for the letterbox
local darkest, dv = 0, math.huge
for i = 1, 16 do
  local p = pal[i]
  local v = p[1] + p[2] + p[3]
  if v < dv then dv, darkest = v, i - 1 end
end

local function restore()
  for i = 0, 15 do
    mon.setPaletteColour(2 ^ i, term.nativePaletteColour(2 ^ i))
  end
  mon.setBackgroundColour(colours.black)
  mon.clear()
end

local ok, err = pcall(function()
  for i = 1, 16 do
    local p = pal[i]
    mon.setPaletteColour(2 ^ (i - 1),
      min(1, (p[1] * 8 + 4) / 255), min(1, (p[2] * 8 + 4) / 255), min(1, (p[3] * 8 + 4) / 255))
  end
  mon.setBackgroundColour(2 ^ darkest)
  mon.clear()

  local prev = nil
  local f, loops = 1, 0
  local nextT = os.epoch("utc")
  local timer = os.startTimer(0)
  while true do
    local ev, p = os.pullEvent()
    if ev == "timer" and p == timer then
      local rows = frames[f]
      for r = 1, #rows do
        local row = rows[r]
        local pr = prev and prev[r]
        if not pr or pr[1] ~= row[1] or pr[2] ~= row[2] or pr[3] ~= row[3] then
          mon.setCursorPos(ox, oy + r - 1)
          mon.blit(row[1], row[2], row[3])
        end
      end
      prev = rows

      local now = os.epoch("utc")
      nextT = nextT + delays[f]
      if nextT < now then nextT = now end            -- running behind: don't spiral
      timer = os.startTimer((nextT - now) / 1000)

      f = f + 1
      if f > #frames then
        f = 1
        loops = loops + 1
        if maxLoops and loops >= maxLoops then break end
      end
    elseif ev == "key" and p == keys.q then
      break
    end
  end
end)

restore()
if not ok and err ~= "Terminated" then printError(err) end
