-- VFN.LibrarySeeder
--
-- Pre-loads curated libraries from Data/*Seed files. Idempotent: runs on
-- addon load and bails fast if the target library already exists.
--
-- Current seeds:
--   "Decor Vendors"  from VFN_DecorVendorsDB (one card per zone; each entry
--                    is a vendor coord with the vendor name as its label).
--
-- Architecture:
--   - Reads pure data from VFN_DecorVendorsDB (loaded in TOC before this).
--   - Creates the library via VFN_LIBRARY_CREATE dispatch, then looks up
--     the new library by name (the action doesn't return its ID).
--   - Creates each zone card via VFN.Store:CreateSet so the entries[]
--     embed directly without parser/resolver round-trips.

VFN = VFN or {}
VFN.LibrarySeeder = VFN.LibrarySeeder or {}

local LibrarySeeder = VFN.LibrarySeeder

-- Resolve a library by name (case-sensitive). Returns libraryID or nil.
local function FindLibraryByName(state, name)
    if not (state and state.account and state.account.libraries) then return nil end
    for libID, lib in pairs(state.account.libraries) do
        if lib.name == name and not lib.deletedAt then return libID end
    end
    return nil
end

-- Build a VFN entry from a {name, mapID, x (0..100), y (0..100)} vendor row.
-- Each entry carries its own mapID -- a single zone-name card spans the
-- parent + sub-zone maps (Boralus 895+1161, Harandar 2413+2480, etc).
local function BuildVendorEntry(zone, vendor, index)
    local rawX  = tonumber(vendor.x) or 0
    local rawY  = tonumber(vendor.y) or 0
    local mapID = tonumber(vendor.mapID) or 0
    return {
        id           = string.format("vendor:%d:%d:%.1f:%.1f", mapID, index, rawX, rawY),
        coordMapID   = mapID,
        displayMapID = mapID,
        mapName      = zone,
        label        = vendor.name or "Vendor",
        x            = rawX / 100,
        y            = rawY / 100,
        rawX         = rawX,
        rawY         = rawY,
        resolution   = "seed",
        confidence   = 1.0,
        status       = "new",
    }
end

-- Build a sourceLines list (one /way per vendor, using each vendor's own
-- mapID) so the Curator's Copy-coords dialog reproduces the seed faithfully.
local function BuildSourceLines(vendors)
    local lines = {}
    for i, v in ipairs(vendors) do
        lines[#lines + 1] = {
            lineNo = i,
            text   = string.format("/way %d %.1f %.1f %s",
                tonumber(v.mapID) or 0,
                tonumber(v.x) or 0,
                tonumber(v.y) or 0,
                v.name or "Vendor"),
        }
    end
    return lines
end

local function SeedDecorVendors()
    local db = _G.VFN_DecorVendorsDB
    if not (db and db.zones and db.libraryName) then return end
    if not (VFN.Store and VFN.Store.GetState and VFN.Store.CreateSet) then return end

    local state = VFN.Store:GetState()
    if FindLibraryByName(state, db.libraryName) then
        return  -- already seeded; idempotent no-op
    end

    -- Create the library, then look it up by name to capture its generated ID.
    VFN.Store:Dispatch("VFN_LIBRARY_CREATE", { name = db.libraryName })
    state = VFN.Store:GetState()
    local libraryID = FindLibraryByName(state, db.libraryName)
    if not libraryID then return end  -- creation rejected (cap?), nothing more to do

    local createdCount = 0
    for _, zone in ipairs(db.zones) do
        if zone.vendors and #zone.vendors > 0 then
            local entries = {}
            for i, v in ipairs(zone.vendors) do
                entries[#entries + 1] = BuildVendorEntry(zone.zone, v, i)
            end
            local result = VFN.Store:CreateSet({
                libraryID  = libraryID,
                title      = string.format("%s - decor", zone.zone),
                source     = { type = "seed", owner = "VFN", addon = "VFN" },
                visibility = { scope = "account", character = nil },
                entries    = entries,
                sourceLines = BuildSourceLines(zone.vendors),
                sourceText = "",
                payload    = { note = "" },
            })
            if result and result.setID then createdCount = createdCount + 1 end
        end
    end

    if createdCount > 0 then
        VFN.Store:RebuildIndexes()
        VFN.Store:_Notify("VFN_LIBRARY_SEEDED")
    end
end

function LibrarySeeder:Run()
    SeedDecorVendors()
end

-- Auto-run on PLAYER_LOGIN (after Store:LoadFromSavedVariables has populated
-- the persisted state). MainFrame's Init wires this.
function LibrarySeeder:OnPlayerLogin()
    self:Run()
end
