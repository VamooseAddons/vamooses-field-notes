VFN = VFN or {}
VFN.CoordParser = {}

local NUMBER = "%-?%d+%.?%d*"

local function Trim(value)
    return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function NormalizeHint(value)
    local out = Trim(value):lower()
    if out == "" then return nil end
    return out
end

local function EmptyToNil(value)
    value = Trim(value)
    if value == "" then return nil end
    return value
end

local function IsKnownMapHint(mapHint)
    local db = VFN.MapAliasDB
    if not db or not mapHint then return false end

    local trimmed = Trim(mapHint)
    local normalized = NormalizeHint(trimmed)
    if trimmed == "" then return false end

    if db.exactNames and db.exactNames[trimmed] then return true end
    if db.exactNameLookup and normalized and db.exactNameLookup[normalized] then return true end
    if db.aliases and normalized and db.aliases[normalized] then return true end
    return false
end

local function ParseCoordinateBody(body, preferMapID)
    local mapHint, xText, yText, label

    if preferMapID then
        mapHint, xText, yText, label = body:match("^#?(%d+)%s+(" .. NUMBER .. ")%s*,%s*(" .. NUMBER .. ")%s*(.*)$")
        if not mapHint then
            mapHint, xText, yText, label = body:match("^#?(%d+)%s+(" .. NUMBER .. ")%s+(" .. NUMBER .. ")%s*(.*)$")
        end
        if mapHint then
            return mapHint, tonumber(xText), tonumber(yText), EmptyToNil(label)
        end
    end

    xText, yText, label = body:match("^(" .. NUMBER .. ")%s*,%s*(" .. NUMBER .. ")%s*(.*)$")
    if not xText then
        xText, yText, label = body:match("^(" .. NUMBER .. ")%s+(" .. NUMBER .. ")%s*(.*)$")
    end
    if xText then
        return nil, tonumber(xText), tonumber(yText), EmptyToNil(label)
    end

    mapHint, xText, yText, label = body:match("^mapID%s+#?(%d+)%s+(" .. NUMBER .. ")%s*,%s*(" .. NUMBER .. ")%s*(.*)$")
    if not mapHint then
        mapHint, xText, yText, label = body:match("^mapID%s+#?(%d+)%s+(" .. NUMBER .. ")%s+(" .. NUMBER .. ")%s*(.*)$")
    end
    if mapHint then
        return mapHint, tonumber(xText), tonumber(yText), EmptyToNil(label)
    end

    mapHint, xText, yText, label = body:match("^(.+)%s+(" .. NUMBER .. ")%s*,%s*(" .. NUMBER .. ")%s*(.*)$")
    if not mapHint then
        mapHint, xText, yText, label = body:match("^(.+)%s+(" .. NUMBER .. ")%s+(" .. NUMBER .. ")%s*(.*)$")
    end
    if mapHint and (preferMapID or IsKnownMapHint(mapHint)) then
        return Trim(mapHint), tonumber(xText), tonumber(yText), EmptyToNil(label)
    end

    return nil, nil, nil, nil
end

-- Detect Wowhead's in-game pin script + bare worldmap chat-link format.
-- Both contain `worldmap:MAPID:X:Y` somewhere in the line:
--   /script ... \124Hworldmap:2594:66.40:52.46\124h ...   (paste from Wowhead "in-game pin")
--   |Hworldmap:2594:66.40:52.46|h[Map Pin Location]|h     (a bare chat link)
-- The escaped `\124` is just a literal pipe character in the pasted text.
-- We strip it before pattern-matching so one regex covers both forms.
--
-- Coord scale: parsed values are Wowhead's display-style floats in the range
-- 0-100 (e.g. "66.40", "52.46"). CoordResolver validates this range and
-- normalises to 0-1 before storing on entries. Blizzard's server-signed
-- |Hworldmap:...|h links use scaled integers (x*10000); if those ever appear
-- in pasted text the >100 range check in CoordResolver will reject them.
local function ParseWorldmapLink(line)
    local normalized = line:gsub("\\124", "|")
    local mapID, xStr, yStr = normalized:match("|Hworldmap:(%d+):([%d%.%-]+):([%d%.%-]+)|h")
    if mapID then
        return mapID, tonumber(xStr), tonumber(yStr)
    end
    -- Fallback: match the worldmap segment without requiring `|H`/`|h`. Some
    -- Wowhead exports vary the wrapping.
    mapID, xStr, yStr = normalized:match("worldmap:(%d+):([%d%.%-]+):([%d%.%-]+)")
    if mapID then
        return mapID, tonumber(xStr), tonumber(yStr)
    end
    return nil, nil, nil
end

function VFN.CoordParser:Parse(text)
    local out = { lines = {}, candidates = {} }
    local currentHeading = nil
    local lineNo = 0

    for raw in (tostring(text or "") .. "\n"):gmatch("([^\n]*)\n") do
        local line = Trim(raw)
        if line ~= "" then
            lineNo = lineNo + 1

            local source = {
                lineNo = lineNo,
                text = line,
                rawLine = line,
                status = "unparsed",
            }
            out.lines[#out.lines + 1] = source

            local heading = line:match("^([^:]+):$")
            if heading then
                currentHeading = Trim(heading)
                source.status = "heading"
            else
                -- Wowhead in-game pin script (or bare worldmap chat link) is
                -- recognised by the `worldmap:MAPID:X:Y` segment. Map ID is
                -- always explicit so we don't need the headingHint fallback.
                local linkMapID, linkX, linkY = ParseWorldmapLink(line)
                if linkMapID and linkX and linkY then
                    source.status = "candidate"
                    out.candidates[#out.candidates + 1] = {
                        rawLine = line,
                        lineNo = lineNo,
                        mapHint = linkMapID,
                        headingHint = nil,
                        x = linkX,
                        y = linkY,
                        label = nil,
                    }
                    currentHeading = nil
                else
                    local body = line:match("^/way%s+(.+)$")
                    local fromWaypoint = body ~= nil
                    body = body or line
                    local mapHint, x, y, label = ParseCoordinateBody(body, fromWaypoint)

                    if x and y then
                        source.status = "candidate"

                        local headingHint = nil
                        if not mapHint then
                            headingHint = currentHeading
                        end

                        out.candidates[#out.candidates + 1] = {
                            rawLine = line,
                            lineNo = lineNo,
                            mapHint = mapHint,
                            headingHint = headingHint,
                            x = x,
                            y = y,
                            label = label,
                        }

                        if mapHint then
                            currentHeading = nil
                        end
                    else
                        source.status = "invalid"
                    end
                end
            end
        end
    end

    return out
end

function VFN.CoordParser:ParseText(text)
    return self:Parse(text)
end
