local PM_READY = 15
local SWEEP_MS = 500
local HIGHLIGHT_MS = 60
local PROBE_HIDE_MS = 250
local NUDGE_AFTER_MS = 150
local WATCH_MS = 2000
local EMPTY_HIDE_MS = 1000
local EXIT_HOLD_MS = 1000
local TAB_HOLD_MS = 400
local REBUILD_SETTLE_MS = 1200
local PICK_HOLD_MS = 400

local shown = false
local hasFocus = false
local keepInput = true
local hoverOver = false
local typing = false
local released = false
local lastHighlight = -1
local lastBlipCount = -1
local dirty = false

---@type MapLocation[]?
local cache
---@type string?
local cacheDigest
---@type string?
local pendingDigest

---@type table<string, MapLocation[]>
local known = {}

---@type string[]
local knownOrder = {}
local KNOWN_MAX = 8

---@type table<MapLocation[], integer>
local familyOf = setmetatable({}, { __mode = 'k' })

---@type table<integer, string>
local familyDigest = {}
local nextFamily = 0

local MapData = require 'modules.mapdata'

---@param digest string
local function forget(digest)
    known[digest] = nil
    for i = #knownOrder, 1, -1 do
        if knownOrder[i] == digest then table.remove(knownOrder, i) end
    end
end

---@param digest string
---@param list MapLocation[]
local function memorize(digest, list)
    local family = familyOf[list]

    if not family then
        nextFamily = nextFamily + 1
        family = nextFamily
        familyOf[list] = family
    end

    local previous = familyDigest[family]
    if previous and previous ~= digest then forget(previous) end
    familyDigest[family] = digest

    if not known[digest] then
        knownOrder[#knownOrder + 1] = digest
        if #knownOrder > KNOWN_MAX then
            known[table.remove(knownOrder, 1)] = nil
        end
    end
    known[digest] = list
end

---@type integer?
local emptySince
---@type integer?
local probeMissSince

local holdUntil = 0
local rebuildAt = 0
local nudgedAt = 0
local pickedAt = 0
local generation = 0

---@class RowWatch
---@field index integer
---@field target integer
---@field from integer
---@field before string
---@field since integer
---@field deadline integer
---@field nudge boolean
---@field nudged boolean
---@field lastSnapshot string?

---@type RowWatch?
local watch = nil

---@param row MapLocation
---@param item MapLocation
---@param staleValue integer?
---@param staleLabel string?
---@return boolean
local function absorb(row, item, staleValue, staleLabel)
    if item.pending then return false end
    if staleLabel and item.value ~= staleValue and item.label == staleLabel then return false end
    row.labels = row.labels or {}
    row.labels[item.value] = item.label
    return true
end

---@param row MapLocation?
local function remember(row)
    if not row then return end
    absorb(row, row)
end

---@param index integer
---@return MapLocation?
---@return integer? position
local function findRow(index)
    if not cache then return nil end

    for i = 1, #cache do
        if cache[i].index == index then return cache[i], i end
    end

    return nil
end

---@param action string
---@param data table?
local function send(action, data)
    SendNUIMessage({ action = action, data = data })
end

local function applyFocus()
    if hasFocus ~= shown then
        hasFocus = shown
        SetNuiFocus(shown, shown)
    end

    if hasFocus then
        SetNuiFocusKeepInput(keepInput)
    end
end

local function releaseFocus()
    if not hasFocus then return end
    hasFocus = false
    keepInput = true
    hoverOver = false
    typing = false
    released = false
    SetNuiFocus(false, false)
end

local function hide()
    if not shown then return end
    shown = false
    generation = generation + 1
    pendingDigest = nil
    emptySince = nil
    probeMissSince = nil
    lastHighlight = -1
    watch = nil
    releaseFocus()
    send('close')
end

---@param list MapLocation[]
local function show(list)
    shown = true
    applyFocus()
    send('open', { locations = list })
end

---@return MapLocation[]?
local function pullAll()
    local gen = generation

    local function cancelled()
        return gen ~= generation or GetPauseMenuState() ~= PM_READY
    end

    ---@type MapProgressFn?
    local onProgress

    if not shown then
        onProgress = function(partial)
            if cancelled() then return end

            if shown then
                send('update', { locations = partial })
            else
                show(partial)
            end
        end
    end

    local list, complete = MapData.fetch(onProgress, cancelled)

    if not complete or cancelled() or #list == 0 then return nil end

    cache = list

    for i = 1, #list do
        remember(list[i])
    end

    if shown then
        send('update', { locations = list })
    else
        show(list)
    end

    return list
end

---@param fallbackDigest string
---@return boolean
local function pullAndMemorize(fallbackDigest)
    local list = pullAll()
    if not list then return false end

    local fresh = MapData.digest()

    if fresh and #fresh == #list then
        cacheDigest = fresh
        memorize(fresh, list)
    else
        cacheDigest = fallbackDigest
    end

    return true
end

---@param digest string
local function reconcile(digest)
    if not cache or not cacheDigest then
        local recalled = known[digest]
        if recalled then
            cache = recalled
            cacheDigest = digest
            send('update', { locations = recalled })
        else
            pullAndMemorize(digest)
        end
        return
    end

    local old, new = cacheDigest, digest
    local oldLen, newLen = #old, #new

    local head = 0
    while head < oldLen and head < newLen and old:byte(head + 1) == new:byte(head + 1) do
        head = head + 1
    end

    local tail = 0
    while tail < oldLen - head and tail < newLen - head
        and old:byte(oldLen - tail) == new:byte(newLen - tail) do
        tail = tail + 1
    end

    local fresh = newLen - head - tail

    if fresh > 8 or oldLen - head - tail > 8 then
        local recalled = known[digest]

        if recalled and recalled ~= cache then
            cache = recalled
            cacheDigest = digest
            send('update', { locations = recalled })
            return
        end

        pullAndMemorize(digest)
        return
    end

    local rebuilt = {}
    local gen = generation

    for i = 1, head do
        rebuilt[#rebuilt + 1] = cache[i]
    end

    for i = 0, fresh - 1 do
        local item = MapData.fetchOne(head + i)
        if gen ~= generation then return end
        if not item then
            dirty = true
            return
        end
        local prev = cache[head + i + 1]
        local sameRow = prev and prev.icon == item.icon and prev.color == item.color
        if sameRow then
            if prev.labels then item.labels = prev.labels end

            local ours = watch and watch.index == item.index and prev.count == item.count
            local intact

            if ours and watch then
                intact = absorb(item, item, watch.from, watch.before)
            else
                intact = absorb(item, item, prev.value, prev.label)
            end

            if ours then
                item.value = prev.value
                item.label = item.labels and item.labels[item.value] or prev.label
            elseif not intact then
                item.label = item.labels and item.labels[item.value] or prev.label
            end
        else
            remember(item)
        end
        rebuilt[#rebuilt + 1] = item
    end

    for i = oldLen - tail + 1, oldLen do
        local moved = cache[i]
        if not moved then
            pullAndMemorize(digest)
            return
        end
        rebuilt[#rebuilt + 1] = {
            index = #rebuilt,
            label = moved.label,
            icon = moved.icon,
            color = moved.color,
            count = moved.count,
            value = moved.value,
            labels = moved.labels,
        }
    end

    if #rebuilt ~= newLen then
        pullAndMemorize(digest)
        return
    end

    familyOf[rebuilt] = familyOf[cache]
    cache = rebuilt
    cacheDigest = digest
    memorize(digest, rebuilt)
    send('update', { locations = rebuilt })
end

local function refresh()
    local gen = generation
    local digest = MapData.digest()

    if gen ~= generation then return end
    if GetPauseMenuState() ~= PM_READY then return end

    if not digest or #digest == 0 then
        local now = GetGameTimer()
        emptySince = emptySince or now
        if digest then rebuildAt = now end

        if now - emptySince >= EMPTY_HIDE_MS then
            hide()
        elseif shown then
            dirty = true
        end

        return
    end

    emptySince = nil

    if not shown then
        if GetGameTimer() < holdUntil then return end

        local recalled = known[digest]

        if recalled then
            cache = recalled
            cacheDigest = digest
            show(recalled)
            return
        elseif cache then
            show(cache)
        else
            pullAndMemorize(digest)
            return
        end
    end

    if digest == cacheDigest then
        pendingDigest = nil
        memorize(digest, cache --[[@as MapLocation[] ]])
        return
    end

    if cacheDigest and #digest ~= #cacheDigest then
        local now = GetGameTimer()
        rebuildAt = now

        if now - nudgedAt < REBUILD_SETTLE_MS then
            pendingDigest = nil
            return
        end

        if digest ~= pendingDigest then
            pendingDigest = digest
            dirty = true
            return
        end
    end

    pendingDigest = nil
    reconcile(digest)
end

local function syncHighlight()
    local index, value = MapData.highlight()

    if not index then
        local now = GetGameTimer()
        probeMissSince = probeMissSince or now
        if now - probeMissSince >= PROBE_HIDE_MS then hide() end
        return
    end

    probeMissSince = nil

    local now = GetGameTimer()
    if now - pickedAt < PICK_HOLD_MS then return end

    local row = findRow(index)
    local valueChanged = row and value ~= nil and value ~= row.value
        and not (watch and watch.index == index)

    if index == lastHighlight and not valueChanged then return end

    if index ~= lastHighlight and index == 0 and lastHighlight > 0
        and now - rebuildAt < REBUILD_SETTLE_MS then return
    end

    if index ~= lastHighlight then
        lastHighlight = index
        send('highlight', { index = index })
    end

    if not row or row.count <= 1 then return end

    local item = MapData.fetchOne(index)
    if not item or item.icon ~= row.icon or item.color ~= row.color or item.count ~= row.count then
        return
    end

    if not absorb(row, item, row.value, row.label) then
        if not item.pending and item.value ~= row.value then
            row.value = item.value
            row.label = row.labels and row.labels[item.value] or row.label
            send('row', { location = row })
        end
        return
    end
    if item.value == row.value and item.label == row.label then return end

    row.value = item.value
    row.label = item.label
    send('row', { location = row })
end

local function nudgeLegend()
    local coords = GetEntityCoords(PlayerPedId())
    local blip = AddBlipForCoord(coords.x, coords.y, coords.z)
    SetBlipAlpha(blip, 0)
    nudgedAt = GetGameTimer()
    rebuildAt = nudgedAt
    Wait(0)
    RemoveBlip(blip)
end

local function pollWatch()
    local current = watch
    if not current then return end

    local row = findRow(current.index)

    if not row or row.value ~= current.target then
        watch = nil
        return
    end

    local now = GetGameTimer()

    if now >= current.deadline then
        watch = nil
        return
    end

    if current.nudge and not current.nudged and now >= current.since + NUDGE_AFTER_MS then
        current.nudged = true
        nudgeLegend()
        return
    end

    local item = MapData.fetchOne(current.index)
    if not item or watch ~= current then return end

    if item.icon ~= row.icon or item.color ~= row.color or item.count ~= row.count then
        return
    end

    if not absorb(row, item, current.from, current.before) then return end

    if item.value ~= current.target then
        if row.labels[current.target] and row.label ~= row.labels[current.target] then
            row.label = row.labels[current.target]
            send('row', { location = row })
        end
        return
    end

    watch = nil
    if row.label ~= item.label then
        row.label = item.label
        send('row', { location = row })
    end
end

---@class PickPayload
---@field index integer
---@field value integer?

RegisterNUICallback('pick', function(data, cb)
    cb({ ok = true })

    ---@cast data PickPayload?
    if not data or not data.index then return end

    lastHighlight = data.index
    pickedAt = GetGameTimer()

    local row = findRow(data.index)
    if not row then
        if (data.value or 0) >= 0 then MapData.pick(data.index, data.value or 0) end
        return
    end

    local movieIndex = data.index
    local matched = false
    local fallback = nil

    for _, offset in ipairs({ 0, 1, -1, 2, -2 }) do
        local candidate = data.index + offset
        if candidate >= 0 then
            local probe = MapData.fetchOne(candidate)
            if probe and probe.icon == row.icon and probe.color == row.color and probe.count == row.count then
                if probe.label == row.label then
                    movieIndex = candidate
                    matched = true
                    break
                elseif not fallback then
                    fallback = candidate
                end
            end
        end
    end

    if not matched and fallback then
        movieIndex = fallback
        matched = true
    end

    if movieIndex ~= data.index then
        dirty = true
    end

    if not shown then return end
    lastHighlight = data.index
    pickedAt = GetGameTimer()

    local target = data.value or 0

    if target < 0 and row.count > 0 then
        target = ((row.value or 0) + (target == -1 and 1 or -1) + row.count) % row.count
    end

    MapData.pick(movieIndex, target)

    local shifted = target ~= (row.value or 0)
    local from = row.value or 0
    local before = row.label

    row.value = target
    row.labels = row.labels or {}

    if shifted and row.labels[target] then
        row.label = row.labels[target]
    end

    send('row', { location = row })

    if not shifted then return end

    watch = {
        index = row.index,
        target = target,
        from = from,
        before = before,
        since = GetGameTimer(),
        deadline = GetGameTimer() + WATCH_MS,
        nudge = row.labels[target] == nil,
        nudged = false,
    }
end)

local function updateInputRouting()
    keepInput = not typing and (not hoverOver or released)
    applyFocus()
end

RegisterNUICallback('hover', function(data, cb)
    hoverOver = data and data.over == true
    if hoverOver then released = false end
    updateInputRouting()
    cb({ ok = true })
end)

RegisterNUICallback('typing', function(data, cb)
    typing = data and data.active == true
    updateInputRouting()
    cb({ ok = true })
end)

RegisterNUICallback('release', function(_, cb)
    cb({ ok = true })
    released = true
    updateInputRouting()
end)

local WAYPOINT_SETTLE_MS = 200

RegisterNUICallback('waypoint', function(_, cb)
    cb({ ok = true })
    if not shown then return end

    local elapsed = GetGameTimer() - pickedAt
    if elapsed < WAYPOINT_SETTLE_MS then Wait(WAYPOINT_SETTLE_MS - elapsed) end

    if not shown then return end
    SetControlNormal(0, 201, 1.0)

    dirty = true
end)

local TYPING_BLOCKED_CONTROLS = { 172, 173, 174, 175, 176, 177, 194, 199, 200, 201, 202, 205, 206 }
local EXIT_CONTROLS = { 194, 200, 225 }
local TAB_CONTROLS = { 205, 206 }

---@param controls integer[]
---@return boolean
local function anyPressed(controls)
    for i = 1, #controls do
        if IsDisabledControlJustPressed(0, controls[i]) then return true end
    end
    return false
end

CreateThread(function()
    while true do
        local state = GetPauseMenuState()
        local active = IsPauseMenuActive()

        if typing and shown then
            for i = 1, #TYPING_BLOCKED_CONTROLS do
                DisableControlAction(0, TYPING_BLOCKED_CONTROLS[i], true)
            end
        end

        if state ~= PM_READY or not active then
            holdUntil = 0
            hide()
        elseif keepInput and anyPressed(EXIT_CONTROLS) then
            holdUntil = GetGameTimer() + EXIT_HOLD_MS
            generation = generation + 1
            hide()
        elseif keepInput and anyPressed(TAB_CONTROLS) then
            holdUntil = GetGameTimer() + TAB_HOLD_MS
            generation = generation + 1
            hide()
        end

        Wait(0)
    end
end)

CreateThread(function()
    local nextSweep = 0
    local nextHighlight = 0

    while true do
        if GetPauseMenuState() == PM_READY then
            local now = GetGameTimer()

            local blips = GetNumberOfActiveBlips()

            if blips ~= lastBlipCount then
                lastBlipCount = blips
                dirty = true
            end

            if dirty or now >= nextSweep then
                dirty = false
                nextSweep = now + SWEEP_MS
                refresh()
            end

            if shown and watch then
                pollWatch()
            end

            if shown and now >= nextHighlight then
                nextHighlight = now + HIGHLIGHT_MS
                syncHighlight()
            end

            Wait(0)
        else
            hide()
            Wait(250)
        end
    end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then
        releaseFocus()
    end
end)
