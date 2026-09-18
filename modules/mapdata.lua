---@class MapLocation
---@field index integer
---@field label string
---@field icon string?
---@field color string
---@field count integer
---@field value integer
---@field pending boolean
---@field labels table<integer, string>?

---@alias MapProgressFn fun(list: MapLocation[])
---@alias MapCancelledFn fun(): boolean

local OP_DUMP = -0x52480001
local OP_PICK = -0x52480002
local OP_HIGHLIGHT = -0x52480003
local OP_CLEAR = -0x52480004
local OP_REVISION = -0x52480005
local OP_PROBE = -0x52480006
local OP_BUDGET = -0x52480007
local OP_DIGEST = -0x52480008

local COLUMN = 0
local BATCH = 8
local REPLY_TIMEOUT_MS = 150
local PM_READY = 15

---@param opcode integer
---@param a integer?
---@param b integer?
---@return boolean
local function sendOpcode(opcode, a, b)
    if not BeginScaleformMovieMethodOnFrontend('SET_DATA_SLOT') then
        return false
    end
    ScaleformMovieMethodAddParamInt(COLUMN)
    ScaleformMovieMethodAddParamInt(opcode)
    ScaleformMovieMethodAddParamInt(a or 0)
    ScaleformMovieMethodAddParamInt(b or 0)
    EndScaleformMovieMethod()
    return true
end

---@return string?
local function readSelection()
    if not BeginScaleformMovieMethodOnFrontend('GET_COLUMN_SELECTION') then
        return nil
    end
    ScaleformMovieMethodAddParamInt(COLUMN)

    local handle = EndScaleformMovieMethodReturnValue()
    local deadline = GetGameTimer() + REPLY_TIMEOUT_MS

    while not IsScaleformMovieMethodReturnValueReady(handle) do
        if GetGameTimer() > deadline or GetPauseMenuState() ~= PM_READY then return nil end
        Wait(0)
    end

    return GetScaleformMovieMethodReturnValueString(handle)
end

---@param opcode integer
---@param a integer?
---@return integer?
local function queueSelection(opcode, a)
    if not sendOpcode(opcode, a) then return nil end
    if not BeginScaleformMovieMethodOnFrontend('GET_COLUMN_SELECTION') then return nil end
    ScaleformMovieMethodAddParamInt(COLUMN)

    local handle = EndScaleformMovieMethodReturnValue()
    if not handle or handle == 0 then return nil end

    return handle
end

---@param handles integer[]
---@return string[]?
local function awaitSelections(handles)
    local deadline = GetGameTimer() + REPLY_TIMEOUT_MS
    local results = {}

    for i = 1, #handles do
        while not IsScaleformMovieMethodReturnValueReady(handles[i]) do
            if GetGameTimer() > deadline or GetPauseMenuState() ~= PM_READY then return nil end
            Wait(0)
        end
        results[i] = GetScaleformMovieMethodReturnValueString(handles[i])
    end

    return results
end

---@param opcode integer
---@param a integer?
---@param b integer?
---@param validate fun(packed: string): boolean
---@return string?
local function readTagged(opcode, a, b, validate)
    for _ = 1, 3 do
        if not sendOpcode(opcode, a, b) then return nil end

        local packed = readSelection()
        if not packed then return nil end

        if validate(packed) then
            return packed
        end
    end

    return nil
end

---@param entry string
---@return MapLocation?
local function parseEntry(entry)
    local index, label, icon, colour, pending, count, value =
        entry:match('^(%d+)~(.-)~(.-)~(%x%x%x%x%x%x)(p?)~(%d+)~(%d+)$')

    index = tonumber(index)
    if not index then return nil end

    return {
        index = index,
        label = label,
        icon = icon ~= '' and ('radar_' .. icon) or nil,
        color = '#' .. colour,
        count = tonumber(count) or 1,
        value = tonumber(value) or 0,
        pending = pending == 'p',
    }
end

---@param onProgress MapProgressFn?
---@param cancelled MapCancelledFn?
---@return MapLocation[]
---@return boolean complete
local function fetchSequential(onProgress, cancelled)
    local list = {}
    local cursor = 0
    local complete = false

    for _ = 1, 300 do
        if cancelled and cancelled() then break end
        if not sendOpcode(OP_DUMP, cursor) then break end

        local packed = readSelection()
        if not packed then break end

        if packed == '' then
            complete = true
            break
        end

        local advanced = false

        for entry in packed:gmatch('[^|]+') do
            local item = parseEntry(entry)

            if item and item.index >= cursor then
                list[#list + 1] = item
                cursor = item.index + 1
                advanced = true
            end
        end

        if not advanced then break end
        if onProgress then onProgress(list) end
    end

    sendOpcode(OP_CLEAR)

    return list, complete
end

---@return integer?
local function readCount()
    if not sendOpcode(OP_REVISION) then return nil end

    local packed = readSelection()
    if not packed then return nil end

    return tonumber(packed:match('^R~%d+~(%d+)$'))
end

---@param onProgress MapProgressFn?
---@param cancelled MapCancelledFn?
---@return MapLocation[]
---@return boolean complete
local function fetchLocations(onProgress, cancelled)
    local total = readCount()
    if not total then return fetchSequential(onProgress, cancelled) end

    local list = {}
    local cursor = 0
    local complete = total == 0
    local retries = 0

    while cursor < total do
        if cancelled and cancelled() then break end

        local handles, indices = {}, {}
        local last = math.min(cursor + BATCH - 1, total - 1)

        for i = cursor, last do
            local handle = queueSelection(OP_DUMP, i)
            if not handle then break end
            handles[#handles + 1] = handle
            indices[#indices + 1] = i
        end

        if #handles == 0 then
            sendOpcode(OP_CLEAR)
            local rest, restComplete = fetchSequential(onProgress, cancelled)
            for i = 1, #rest do
                if rest[i].index >= cursor then list[#list + 1] = rest[i] end
            end
            return list, restComplete
        end

        local results = awaitSelections(handles)
        local batch = {}

        if results then
            for k = 1, #results do
                local first = results[k] and results[k]:match('^[^|]+')
                local item = first and parseEntry(first)
                if not item or item.index ~= indices[k] then
                    batch = nil
                    break
                end
                batch[k] = item
            end
        else
            batch = nil
        end

        if batch then
            for k = 1, #batch do list[#list + 1] = batch[k] end
            cursor = indices[#indices] + 1
            retries = 0
            if onProgress then onProgress(list) end
        else
            retries = retries + 1
            if retries > 3 then break end
            Wait(0)
        end
    end

    if cursor >= total then complete = true end

    sendOpcode(OP_CLEAR)

    return list, complete
end

---@return integer? index
---@return integer? value
local function fetchHighlight()
    if not sendOpcode(OP_HIGHLIGHT) then return nil end

    local packed = readSelection()
    sendOpcode(OP_CLEAR)

    if not packed then return nil end

    local index, value = packed:match('^H~(%-?%d+)~(%d+)$')
    if not index then return nil end

    return tonumber(index), tonumber(value)
end

---@class MapData
MapData = {}

---@type fun(onProgress: MapProgressFn?, cancelled: MapCancelledFn?): MapLocation[], boolean
MapData.fetch = fetchLocations

---@type fun(): integer?, integer?
MapData.highlight = fetchHighlight

---@param index integer
---@return MapLocation?
MapData.fetchOne = function(index)
    local packed = readTagged(OP_DUMP, index, 0, function(s)
        local first = s:match('^[^|]+')
        local item = first and parseEntry(first)
        return item ~= nil and item.index == index
    end)

    sendOpcode(OP_CLEAR)

    return packed and parseEntry(packed:match('^[^|]+')) or nil
end

---@return integer? revision
---@return integer? count
MapData.revision = function()
    if not sendOpcode(OP_REVISION) then return nil end

    local packed = readSelection()
    sendOpcode(OP_CLEAR)

    if not packed then return nil end

    local revision, count = packed:match('^R~(%d+)~(%d+)$')
    if not revision then return nil end

    return tonumber(revision), tonumber(count)
end

---@param index integer
---@param valueIndex integer? Indeks blip, atau -1 (maju) / -2 (mundur).
---@return boolean
MapData.pick = function(index, valueIndex)
    return sendOpcode(OP_PICK, index, valueIndex or 0)
end

---@param chars integer
---@return boolean
MapData.setBudget = function(chars)
    return sendOpcode(OP_BUDGET, chars)
end

---@return string?
MapData.digest = function()
    for _ = 1, 3 do
        local out, cursor, total = {}, 0, 0
        local ok = true

        for _ = 1, 20 do
            local packed = readTagged(OP_DIGEST, cursor, 0, function(s)
                local n, start = s:match('^(%d+)~(%d+)~')
                return n ~= nil and tonumber(start) == cursor
            end)

            if not packed then
                ok = false
                break
            end

            local n, _, chunk = packed:match('^(%d+)~(%d+)~(.*)$')
            total = tonumber(n) --[[@as integer]]

            if chunk == '' then break end

            out[#out + 1] = chunk
            cursor = cursor + #chunk

            if cursor >= total then break end
        end

        sendOpcode(OP_CLEAR)

        local joined = table.concat(out)
        if ok and #joined == total then return joined end
    end

    return nil
end

---@param n integer
---@return integer?
MapData.probe = function(n)
    if not sendOpcode(OP_PROBE, n) then return nil end

    local packed = readSelection()
    sendOpcode(OP_CLEAR)

    return packed and #packed or 0
end

return MapData