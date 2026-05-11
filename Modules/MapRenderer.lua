-- VFN.MapRenderer
--
-- Renders a uiMap's art tiles into a host frame, scaled to fit. Pure-render
-- module: takes a host frame + uiMapID, paints map tiles + returns a canvas
-- frame whose width/height is the SCALED map size (not the host's). Pin
-- overlays go on the canvas at (canvas_w * x, canvas_h * y).
--
-- Pattern ported from VamoosesPetPatrol/UI/MapDrawer.lua's RenderTiles +
-- LoadMap art-walk-up. Simplified: no fade animation, no fog-of-war
-- overlay, no zoom/pan. If the player wants those features, lift more from
-- VPP's MapDrawer.
--
-- Public API:
--   VFN.MapRenderer:Render(host, uiMapID)  -> canvas, artMapID
--   VFN.MapRenderer:Clear(host)            -- removes existing canvas
--
-- Returns nil if uiMapID has no art (continent/world/cosmic). Caller should
-- fall back to "no map preview" state.

VFN = VFN or {}
VFN.MapRenderer = VFN.MapRenderer or {}

local MR = VFN.MapRenderer

-- Walk parents until we find a uiMap with art tiles. Some IDs (cities,
-- micro-zones, instance interiors) don't have art -- we render the parent
-- zone instead. Cap walk depth so a broken parent chain doesn't loop.
local function findArtableMap(uiMapID)
    local C_MapAPI = _G and _G.C_Map
    if not (C_MapAPI and C_MapAPI.GetMapArtLayers) then return nil end
    local walkID = uiMapID
    for _ = 0, 5 do
        local layers = C_MapAPI.GetMapArtLayers(walkID)
        if layers and layers[1] and layers[1].layerWidth and layers[1].layerWidth > 0 then
            return walkID, layers[1]
        end
        local info = C_MapAPI.GetMapInfo and C_MapAPI.GetMapInfo(walkID)
        if not info or not info.parentMapID or info.parentMapID == 0 then return nil end
        walkID = info.parentMapID
    end
    return nil
end

function MR:Clear(host)
    if not host or not host._vfnMapCanvas then return end
    local canvas = host._vfnMapCanvas
    if canvas.Hide then canvas:Hide() end
    if canvas.ClearAllPoints then canvas:ClearAllPoints() end
    -- Texture children stay attached to the canvas frame; hiding the canvas
    -- hides them all. We don't aggressively destroy textures because
    -- WoW reuses them efficiently and the next Render replaces them.
    host._vfnMapCanvas = nil
end

function MR:Render(host, uiMapID)
    if not host or not uiMapID then return nil end
    if not _G or not _G.CreateFrame then return nil end

    local C_MapAPI = _G.C_Map
    if not C_MapAPI then return nil end

    local artMapID, layer = findArtableMap(uiMapID)
    if not artMapID or not layer then return nil end

    local textures = C_MapAPI.GetMapArtLayerTextures
        and C_MapAPI.GetMapArtLayerTextures(artMapID, 1) or nil
    if not textures or #textures == 0 then return nil end

    -- Drop any prior canvas before building a fresh one.
    self:Clear(host)

    local hostW = host.GetWidth and host:GetWidth() or 0
    local hostH = host.GetHeight and host:GetHeight() or 0
    if hostW <= 0 or hostH <= 0 then return nil end

    -- Fit canvas to host while preserving the map's aspect ratio.
    local scaleW = hostW / layer.layerWidth
    local scaleH = hostH / layer.layerHeight
    local scale = math.min(scaleW, scaleH)

    local canvas = _G.CreateFrame("Frame", nil, host)
    canvas:SetSize(layer.layerWidth, layer.layerHeight)
    canvas:SetScale(scale)
    -- Centre the scaled map inside the host. SetPoint coords are in the
    -- canvas's own scale, so we divide host dims by scale to get the
    -- offset that lands the canvas centre at the host centre.
    local offsetX = (hostW / scale - layer.layerWidth) / 2
    local offsetY = (hostH / scale - layer.layerHeight) / 2
    canvas:ClearAllPoints()
    canvas:SetPoint("TOPLEFT", host, "TOPLEFT", offsetX, -offsetY)

    -- Tile the BASE texture grid. Tile size from layer (typically 256 / 256).
    -- Base tiles render dim/fogged in unexplored areas; the explored overlay
    -- (below) layers bright revealed art on top.
    local tileW = layer.tileWidth or 256
    local tileH = layer.tileHeight or 256
    local cols = math.ceil(layer.layerWidth / tileW)
    local rows = math.ceil(layer.layerHeight / tileH)

    local idx = 1
    for r = 0, rows - 1 do
        for c = 0, cols - 1 do
            if idx > #textures then break end
            local tex = canvas:CreateTexture(nil, "ARTWORK")
            tex:SetPoint("TOPLEFT", c * tileW, -(r * tileH))
            -- Last column/row may be partial; clip the texture coords so
            -- we don't stretch a full tile across a smaller area.
            local w = (c == cols - 1) and (layer.layerWidth - c * tileW) or tileW
            local h = (r == rows - 1) and (layer.layerHeight - r * tileH) or tileH
            tex:SetSize(w, h)
            tex:SetTexture(textures[idx])
            if w < tileW or h < tileH then
                tex:SetTexCoord(0, w / tileW, 0, h / tileH)
            end
            idx = idx + 1
        end
    end

    -- EXPLORED overlay: bright textures for player-revealed areas, layered
    -- over the dim base tiles via sublayer 1. Without this the map looks
    -- fogged-out for any zone the player hasn't fully explored. Ported
    -- straight from VPP's MapDrawer:RenderTiles. Each explored region has
    -- its own grid (positioned at offsetX/Y, with its own width/height) so
    -- we tile them independently of the base grid.
    local explorationAPI = _G.C_MapExplorationInfo
    local explored = explorationAPI and explorationAPI.GetExploredMapTextures
        and explorationAPI.GetExploredMapTextures(artMapID) or nil
    if explored then
        for _, info in ipairs(explored) do
            local fileIDs = info.fileDataIDs
            local regW, regH = info.textureWidth or 0, info.textureHeight or 0
            local ofsX, ofsY = info.offsetX or 0, info.offsetY or 0
            if fileIDs and regW > 0 and regH > 0 then
                local eCols = math.ceil(regW / tileW)
                local eRows = math.ceil(regH / tileH)
                local eIdx = 1
                for eRow = 0, eRows - 1 do
                    for eCol = 0, eCols - 1 do
                        if eIdx > #fileIDs then break end
                        local eTex = canvas:CreateTexture(nil, "ARTWORK", nil, 1)
                        eTex:SetPoint("TOPLEFT", ofsX + eCol * tileW, -(ofsY + eRow * tileH))
                        local eW = math.min(tileW, regW - eCol * tileW)
                        local eH = math.min(tileH, regH - eRow * tileH)
                        eTex:SetSize(eW, eH)
                        eTex:SetTexture(fileIDs[eIdx])
                        if eW < tileW or eH < tileH then
                            eTex:SetTexCoord(0, eW / tileW, 0, eH / tileH)
                        end
                        eIdx = eIdx + 1
                    end
                end
            end
        end
    end

    host._vfnMapCanvas = canvas
    return canvas, artMapID
end
