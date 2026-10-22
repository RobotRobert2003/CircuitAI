-- Read-only census of metal extractors by team and water depth, once a game
-- minute, plus the map's spot survey at start. Evidence for mex ownership by
-- theatre (land / shallow / naval); the AI's own theatre classification is
-- logged separately as [MexTerritory]. No orders, gifts or AI messages.
function widget:GetInfo()
    return {name="BARb mex theatre census", desc="Read-only extractor census by water depth",
            author="CircuitAI", layer=127, enabled=true}
end

local NAVAL_DEPTH = 8 -- the native 8-deep water body threshold (CBattleAnalysis body8)

local function emit(s) Spring.Echo("[MexTheatre] " .. s) end

local function classify(y)
    if y <= -NAVAL_DEPTH then return "naval" end
    if y < 0 then return "shallow" end
    return "land"
end

local surveyed = false

local function survey()
    local finder = WG.resource_spot_finder
    if not finder or not finder.metalSpotsList then return false end
    local counts = {land = 0, shallow = 0, naval = 0}
    for index, spot in ipairs(finder.metalSpotsList) do
        local y = Spring.GetGroundHeight(spot.x, spot.z)
        local kind = classify(y)
        counts[kind] = counts[kind] + 1
        emit(string.format("spot %d x=%.0f z=%.0f y=%.0f kind=%s", index, spot.x, spot.z, y, kind))
    end
    emit(string.format("survey spots=%d land=%d shallow=%d naval=%d",
        #finder.metalSpotsList, counts.land, counts.shallow, counts.naval))
    return true
end

function widget:GameFrame(frame)
    if not surveyed and frame >= 150 and frame % 30 == 0 then surveyed = survey() end
    if frame == 0 or frame % 1800 ~= 0 then return end
    local minute = frame / 1800
    for _, team in ipairs(Spring.GetTeamList() or {}) do
        local _, _, dead, isAI, _, ally = Spring.GetTeamInfo(team, false)
        local counts = {land = 0, shallow = 0, naval = 0}
        local unfinished = 0
        local naval, all = {}, {}
        for _, unit in ipairs(Spring.GetTeamUnits(team) or {}) do
            local definition = UnitDefs[Spring.GetUnitDefID(unit) or -1]
            if definition and (definition.extractsMetal or 0) > 0 then
                local _, _, _, _, progress = Spring.GetUnitHealth(unit)
                if (progress or 0) >= 1 then
                    local x, _, z = Spring.GetUnitPosition(unit)
                    local kind = classify(Spring.GetGroundHeight(x, z))
                    counts[kind] = counts[kind] + 1
                    all[#all + 1] = string.format("%.0f:%.0f", x, z)
                    if kind == "naval" then naval[#naval + 1] = string.format("%.0f:%.0f", x, z) end
                else
                    unfinished = unfinished + 1
                end
            end
        end
        local _, _, _, metalIncome = Spring.GetTeamResources(team, "metal")
        emit(string.format("census minute=%d team=%d ally=%d dead=%s land=%d shallow=%d naval=%d unfinished=%d metalIncome=%.1f navalAt=%s allAt=%s",
            minute, team, ally or -1, tostring(dead), counts.land, counts.shallow, counts.naval, unfinished,
            metalIncome or 0, table.concat(naval, ";"), table.concat(all, ";")))
    end
end
