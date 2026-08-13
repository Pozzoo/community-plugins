--!nonstrict

local haUrlRaw = noctalia.getConfig("ha_url")
local haToken = noctalia.getConfig("ha_token")

local entityStates = {}
local status = "unconfigured"
local expandedEntityId = nil
local sliderDraft = {}
local sliderDirty = {}

local pendingToggle = {}
local pendingSince = {} -- entity_id -> os.clock() when toggle was requested

local PENDING_TIMEOUT_SECONDS = 8

local view = "list" -- "list" | "browser"
local allEntities = {}
local browserIndex = nil -- { blob, offsets }, built alongside allEntities and only ever replaced with it
local browserLoading = false
local browserLoadingSince = nil
local browserFailed = false

local BROWSER_TIMEOUT_SECONDS = 20
-- Ticks a parse may go without advancing its phase, cursor or count before it is given up
-- on. Not a ceiling on the whole parse: that one killed large instances on slow hardware.
local BROWSER_STALL_SECONDS = 20
-- Each row or card is ~6 UI nodes and a closure, and the cards repaint on every state
-- publish rather than per keystroke.
local MAX_BROWSER_ROWS = 200
local MAX_LIST_CARDS = 200
local searchText = ""
local monitoredEntities = {} -- current monitored list (owned here, saved to file)
local panelOpenCount = 0

local function getCleanUrl()
  if type(haUrlRaw) ~= "string" then return "" end
  return (haUrlRaw:gsub("/$", ""))
end

local function tr(key, subst)
      return noctalia.tr("panel." .. key, subst)
end

local function getStatusText()
    if status == "connected" then
        return noctalia.tr("widget.status_connected")
    elseif status == "connecting" then
        return noctalia.tr("widget.status_connecting")
    elseif status == "disconnected" then
        return noctalia.tr("widget.status_disconnected")
    elseif status == "unreachable" then
        return noctalia.tr("widget.status_unreachable")
    elseif status == "auth_failed" then
        return noctalia.tr("widget.status_auth_failed")
    else
        return noctalia.tr("widget.status_unconfigured")
    end
end

local function getCleanToken()
    if type(haToken) ~= "string" then return "" end
    return haToken:gsub("^%s+", ""):gsub("%s+$", "")
end

local function haPost(path, body, onFailure)
    local url = getCleanUrl()
    local cleanToken = getCleanToken()
    if not url or url == "" or cleanToken == "" then
        if onFailure then onFailure() end
        return
    end
    local encodedBody = noctalia.json.encode(body)

    noctalia.http({
        url = url .. path,
        method = "POST",
        headers = {
            "Authorization: Bearer " .. cleanToken,
            "Content-Type: application/json",
        },
        body = encodedBody,
    }, function(response: HttpResponse)
        local httpStatus = response and response.status or 0
        if httpStatus >= 200 and httpStatus < 300 then return end
        noctalia.log("Home Assistant rejected " .. path .. ": status " .. tostring(httpStatus))
        if onFailure then onFailure() end
    end)
end

local function callService(domain, service, entityId, onFailure)
    haPost("/api/services/" .. domain .. "/" .. service, { entity_id = entityId }, onFailure)
end

local MANAGED_ENTITIES_FILE = "managed_entities.json"

local function managedEntitiesPath()
    local dataDir, dirErr = noctalia.pluginDataDir()
    if not dataDir then
        noctalia.log("Cannot resolve plugin data dir: " .. (dirErr or "unknown"))
        return nil
    end
    return dataDir .. "/" .. MANAGED_ENTITIES_FILE
end

local function loadMonitoredEntities()
    local path = managedEntitiesPath()
    local data = path and noctalia.readFile(path)
    if data and data ~= "" then
        local parsed = noctalia.json.decode(data)
        if type(parsed) == "table" then
            monitoredEntities = parsed
            return
        end
    end
    monitoredEntities = {}
end

local function saveMonitoredEntities()
    local path = managedEntitiesPath()
    if not path then
        noctalia.notifyError(noctalia.tr("shortcut.title"), tr("save_failed_no_data_dir"))
        return
    end

    local encodedEntities = noctalia.json.encode(monitoredEntities)
    local ok, writeErr = noctalia.writeFile(path, encodedEntities)
    if not ok then
        noctalia.log("Failed to save managed entities: " .. (writeErr or "unknown"))
        noctalia.notifyError(noctalia.tr("shortcut.title"), tr("save_failed"))
        return
    end
    noctalia.state.set("entities_override", monitoredEntities)
    noctalia.state.set("command", "reload_entities")
end

local function toggleBrowserPin(entityId)
    if not entityId then return end
    local newList, found = {}, false
    for _, eid in ipairs(monitoredEntities) do
        if eid == entityId then found = true
        else table.insert(newList, eid) end
    end
    if not found then table.insert(newList, entityId) end
    monitoredEntities = newList
    saveMonitoredEntities()
    render()
end

-- ── Entity list sources ─────────────────────────────────────────────────────
--
-- Every source is parsed by a resumable job, never in one go: the host kills a callback
-- over its CPU budget, and repeated overruns disable the panel's tick as well.

-- Escaping is Home Assistant's problem here, so no byte can be mistaken for a separator.
local ENTITY_JSON_TEMPLATE =
    "[{% for s in states %}{% if not loop.first %},{% endif %}"
        .. "[{{ s.entity_id | to_json }},{{ s.name | to_json }}]{% endfor %}]"

-- The tab and newline outside the {{ }} are the separators; the ones inside are Jinja's.
local ENTITY_LIST_TEMPLATE =
    "{% for s in states %}{{ s.entity_id }}\t{{ s.name | replace('\\t',' ') | replace('\\n',' ') }}\n{% endfor %}"

local ENTITY_ID_TEMPLATE =
    "{% for s in states %}{{ s.entity_id }}\n{% endfor %}"

local MAX_ENTITY_ID_LENGTH = 255
local MAX_FRIENDLY_NAME_LENGTH = 255
-- Comfortably past id + name, so a record is never cut short by it.
local MAX_RECORD_SCAN = 1024
-- Past this an entity's attributes put the friendly name out of reach; the id stands in.
local MAX_STATES_RECORD = 32768

-- Slices of the callback budget and of the smaller tick one. os.clock() is wall time,
-- which only overstates CPU time, so a deadline built from it stops early.
local SLICE_CALLBACK = 0.012
local SLICE_TICK = 0.006
-- Records between two clock reads, and so also the deadline overshoot.
local DEADLINE_CHECK_EVERY = 64

local STATES_ID_KEY = '"entity_id":"'
local STATES_NAME_KEY = '"friendly_name":"'

local function bodyPreview(body)
    return (string.gsub(string.sub(body, 1, 120), "%c", "."))
end

-- Index of the quote that closes a JSON string whose first content byte is `from`.
local function findStringEnd(s, from)
    local i = string.find(s, '"', from, true)
    while i do
        local j = i - 1
        while j >= from and string.byte(s, j) == 92 do j -= 1 end
        -- An even run of backslashes in front of it leaves the quote unescaped.
        if (i - 1 - j) % 2 == 0 then return i end
        i = string.find(s, '"', i + 1, true)
    end
    return nil
end

-- The decoder only ever sees one short value, never a whole payload.
local function jsonString(raw)
    if raw == "" then return nil end
    if not string.find(raw, "\\", 1, true) then return raw end
    local decoded = noctalia.json.decode('["' .. raw .. '"]')
    if type(decoded) == "table" and type(decoded[1]) == "string" then return decoded[1] end
    return nil
end

local function addEntity(job, entityId, name)
    local dot = string.find(entityId, ".", 1, true)
    if not dot or dot == 1 or dot == #entityId then return end
    if #entityId > MAX_ENTITY_ID_LENGTH then return end
    -- An id is a slug, so it has no spaces. Stops an HTML error page served with status 200
    -- from parsing as one entity instead of falling through to the next source. Plain find,
    -- not a character class: the pattern matcher calls the interrupt per byte it examines.
    if string.find(entityId, " ", 1, true) then return end
    -- "entity_id" also appears inside group and helper attributes.
    if job.seen[entityId] then return end

    if name == nil or name == "" then
        name = entityId
    elseif #name > MAX_FRIENDLY_NAME_LENGTH then
        name = string.sub(name, 1, MAX_FRIENDLY_NAME_LENGTH)
    end

    local domain = string.sub(entityId, 1, dot - 1)

    -- One run of plain stores, no table.insert: the interrupt lands only on calls, returns
    -- and loop edges, so list, count and seen cannot end up disagreeing.
    local n = job.count + 1
    job.list[n] = {
        entity_id     = entityId,
        friendly_name = name,
        domain        = domain,
    }
    job.count = n
    job.seen[entityId] = true
end

-- One `id<TAB>name` record per line. Plain string.find only: a pattern like "([^\t\n]+)\t"
-- backtracks over every separator-free byte inside one uninterruptible C call.
local function stepLines(job, deadline)
    local body = job.body
    local len = #body
    if job.splitOnSpace == nil then
        -- Without any newline the whole body is one record, so a space is not a separator.
        job.splitOnSpace = string.find(body, "\n", 1, true) ~= nil
    end

    local pos = job.cursor
    local n = 0
    while pos <= len do
        local eol = string.find(body, "\n", pos, true) or (len + 1)
        local lineEnd = eol - 1
        if string.sub(body, lineEnd, lineEnd) == "\r" then lineEnd -= 1 end

        -- Bounded copy: searching the body itself re-scans to its far end per line.
        local record = string.sub(body, pos, math.min(lineEnd, pos + MAX_RECORD_SCAN - 1))
        local sep = string.find(record, "\t", 1, true)
        if not sep and job.splitOnSpace then sep = string.find(record, " ", 1, true) end

        if sep then
            addEntity(job, string.sub(record, 1, sep - 1), string.sub(record, sep + 1))
        else
            addEntity(job, record, nil)
        end

        pos = eol + 1
        -- Advanced only once the record is in, so a resume neither drops nor repeats it.
        job.cursor = pos
        n += 1
        if n % DEADLINE_CHECK_EVERY == 0 and os.clock() >= deadline then return "more" end
    end
    return "done"
end

-- [["light.kitchen","Kitchen"],["light.hall","Hall"]]
local function stepPairs(job, deadline)
    local body = job.body
    local at = job.cursor
    local n = 0
    while true do
        local open = string.find(body, '["', at, true)
        if not open then return "done" end

        local idStart = open + 2
        local idEnd = findStringEnd(body, idStart)
        if not idEnd then return "done" end

        local name = nil
        at = idEnd + 1
        if string.sub(body, idEnd + 1, idEnd + 2) == ',"' then
            local valueStart = idEnd + 3
            local valueEnd = findStringEnd(body, valueStart)
            if valueEnd then
                name = jsonString(string.sub(body, valueStart, valueEnd - 1))
                at = valueEnd + 1
            end
        end

        addEntity(job, string.sub(body, idStart, idEnd - 1), name)
        job.cursor = at
        n += 1
        if n % DEADLINE_CHECK_EVERY == 0 and os.clock() >= deadline then return "more" end
    end
end

-- Every element of the compact array opens with `[{"entity_id":"` or `,{"entity_id":"`.
-- The same key one level down is an attribute naming another entity, and taking it for a
-- record misfiles the friendly name.
local function nextStatesKey(body, at, strict)
    local key = string.find(body, STATES_ID_KEY, at, true)
    if not strict then return key end
    while key do
        if string.byte(body, key - 1) == 123 then
            local before = string.byte(body, key - 2)
            if before == 91 or before == 44 then return key end
        end
        key = string.find(body, STATES_ID_KEY, key + 1, true)
    end
    return nil
end

-- The raw /api/states payload, never noctalia.json.decode: it is megabytes, and the decode
-- is one C call that outruns the whole callback budget.
local function stepStates(job, deadline)
    local body = job.body
    local len = #body
    if job.strict == nil then
        -- Anything not compact falls back to matching the key anywhere, leaning on the dedupe.
        job.strict = string.find(body, '[{' .. STATES_ID_KEY, 1, true) ~= nil
            or string.find(body, ',{' .. STATES_ID_KEY, 1, true) ~= nil
    end

    local at = job.cursor
    local n = 0
    while true do
        local key = nextStatesKey(body, at, job.strict)
        if not key then return "done" end

        local idStart = key + #STATES_ID_KEY
        local idEnd = string.find(body, '"', idStart, true)
        if not idEnd then return "done" end

        local nextKey = nextStatesKey(body, idEnd + 1, job.strict)

        -- Forward-only: a fresh find per record rescans to the far end of the body for
        -- every entity that has no name. false means none left.
        local hit = job.nameHit
        if hit == nil or (hit ~= false and hit <= idEnd) then
            hit = string.find(body, STATES_NAME_KEY, idEnd + 1, true) or false
            job.nameHit = hit
        end

        local name = nil
        local limit = math.min(nextKey or (len + 1), idEnd + MAX_STATES_RECORD)
        if hit and hit < limit then
            local valueStart = hit + #STATES_NAME_KEY
            local valueEnd = findStringEnd(body, valueStart)
            if valueEnd then name = jsonString(string.sub(body, valueStart, valueEnd - 1)) end
        end

        addEntity(job, string.sub(body, idStart, idEnd - 1), name)

        if not nextKey then return "done" end
        at = nextKey
        job.cursor = at
        n += 1
        if n % DEADLINE_CHECK_EVERY == 0 and os.clock() >= deadline then return "more" end
    end
end

-- Home Assistant hands `states` back in entity_id order, so this is normally just the
-- linear check. No Lua comparator: table.sort calls one per comparison from native code,
-- where an overrun kills the whole callback.
local function stepOrder(job, deadline)
    local n = 0
    while true do
        if job.orderStage == "check" then
            local list = job.list
            local total = #list
            local i = job.cursor
            while i <= total do
                if list[i].entity_id < list[i - 1].entity_id then
                    job.orderStage = "collect"
                    job.cursor = 1
                    job.ids = {}
                    job.byId = {}
                    break
                end
                i += 1
                job.cursor = i
                n += 1
                if n % DEADLINE_CHECK_EVERY == 0 and os.clock() >= deadline then return "more" end
            end
            if job.orderStage == "check" then return "done" end

        elseif job.orderStage == "collect" then
            local list = job.list
            local total = #list
            local ids, byId = job.ids, job.byId
            local i = job.cursor
            while i <= total do
                local e = list[i]
                ids[i] = e.entity_id
                byId[e.entity_id] = e
                i += 1
                job.cursor = i
                n += 1
                if n % DEADLINE_CHECK_EVERY == 0 and os.clock() >= deadline then return "more" end
            end
            table.sort(ids)
            job.orderStage = "rebuild"
            job.cursor = 1
            job.list = {}
            if os.clock() >= deadline then return "more" end

        else
            local ids, byId = job.ids, job.byId
            local out = job.list
            local total = #ids
            local i = job.cursor
            while i <= total do
                out[i] = byId[ids[i]]
                i += 1
                job.cursor = i
                n += 1
                if n % DEADLINE_CHECK_EVERY == 0 and os.clock() >= deadline then return "more" end
            end
            return "done"
        end
    end
end

-- `id\nname\nid\nname...` lowercased, plus each entity's start offset, so a search is one
-- string.find per matching row instead of one per entity. A per-entity loop spends most of
-- a keystroke's budget on the interrupt alone, whatever its body does.
local function stepIndex(job, deadline)
    local list = job.list
    local total = #list
    local parts, offsets = job.parts, job.offsets
    local i = job.cursor
    local pos = job.blobPos
    local n = 0

    while i <= total do
        local e = list[i]
        local id, name = e.entity_id, e.friendly_name
        -- Two slots rather than a joined string: table.concat supplies the separator, so
        -- nothing is allocated per entity.
        local p = i + i
        parts[p - 1] = id
        parts[p] = name
        offsets[i] = pos
        -- The separator inside the record, and the one that ends it.
        pos = pos + #id + #name + 2
        i += 1
        job.cursor = i
        job.blobPos = pos
        n += 1
        if n % DEADLINE_CHECK_EVERY == 0 and os.clock() >= deadline then return "more" end
    end

    -- Whole-blob C calls, last so an abort above only repeats them.
    job.index = { blob = string.lower(table.concat(parts, "\n")), offsets = offsets }
    return "done"
end

local function finishBrowserLoad(list, index, failed)
    allEntities = list
    browserIndex = index
    browserLoading = false
    browserLoadingSince = nil
    browserFailed = failed == true
    render()
end

local browserJob = nil

local function startBrowserJob(scan, body, label, onUnusable)
    browserJob = {
        scan = scan,
        body = body,
        label = label,
        onUnusable = onUnusable,
        phase = "scan",
        orderStage = "check",
        cursor = 1,
        count = 0,
        list = {},
        seen = {},
        parts = {},
        offsets = {},
        blobPos = 1,
    }
end

local function runBrowserJob(slice)
    local job = browserJob
    if job == nil then return end
    local deadline = os.clock() + slice

    while true do
        -- Finishing is a phase of its own: clearing browserJob is a plain store but the
        -- handover after it is a call, so an abort in between would drop a parsed list.
        if job.phase == "done" then
            finishBrowserLoad(job.list, job.index)
            browserJob = nil
            return
        elseif job.phase == "unusable" then
            noctalia.log(job.label .. " returned nothing usable (" .. #job.body
                .. " bytes, starts with: " .. bodyPreview(job.body) .. ")")
            if job.onUnusable then
                -- Cleared first here: the fallback installs the next job, and a leftover
                -- would have update() re-fire the request every tick.
                browserJob = nil
                job.onUnusable()
            else
                finishBrowserLoad({}, nil, true)
                browserJob = nil
            end
            return
        end

        local outcome
        if job.phase == "scan" then
            outcome = job.scan(job, deadline)
        elseif job.phase == "order" then
            outcome = stepOrder(job, deadline)
        else
            outcome = stepIndex(job, deadline)
        end
        if outcome == "more" then return end

        if job.phase == "scan" then
            if job.count == 0 then
                job.phase = "unusable"
            else
                job.phase = "order"
                job.cursor = 2
                if os.clock() >= deadline then return end
            end
        elseif job.phase == "order" then
            -- After ordering, never during the scan: the offsets describe the final order.
            job.phase = "index"
            job.cursor = 1
            if os.clock() >= deadline then return end
        else
            job.phase = "done"
        end
    end
end

-- This and fetchAllEntitiesFromTemplate continue an in-flight load, so neither re-checks
-- browserLoading.
local function fetchAllEntitiesFromStates()
    local cleanToken = getCleanToken()
    local url = getCleanUrl()

    noctalia.http({
        url = url .. "/api/states",
        headers = {
            "Authorization: Bearer " .. cleanToken,
        }
    }, function(response: HttpResponse)
        local httpStatus = response and response.status or 0
        local body = response and response.body or ""
        if httpStatus < 200 or httpStatus >= 300 or body == "" then
            noctalia.log("Could not list entities: /api/states returned " .. tostring(httpStatus))
            finishBrowserLoad({}, nil, true)
            return
        end

        startBrowserJob(stepStates, body, "/api/states", nil)
        runBrowserJob(SLICE_CALLBACK)
    end)
end

local function fetchAllEntitiesFromTemplate(template, label, scan, onUnusable)
    local cleanToken = getCleanToken()
    local url = getCleanUrl()

    noctalia.http({
        url = url .. "/api/template",
        method = "POST",
        headers = {
            "Authorization: Bearer " .. cleanToken,
            "Content-Type: application/json",
        },
        body = noctalia.json.encode({ template = template }),
    }, function(response: HttpResponse)
        local httpStatus = response and response.status or 0
        local body = response and response.body or ""

        if httpStatus < 200 or httpStatus >= 300 or body == "" then
            -- Home Assistant puts the template error in the body.
            noctalia.log(label .. " template unavailable (status " .. tostring(httpStatus)
                .. ", body: " .. bodyPreview(body) .. ")")
            onUnusable()
            return
        end

        startBrowserJob(scan, body, label .. " template", onUnusable)
        runBrowserJob(SLICE_CALLBACK)
    end)
end

local function fetchAllEntities()
    if browserLoading then return end
    browserJob = nil
    local cleanToken = getCleanToken()
    local url = getCleanUrl()
    if not url or url == "" or cleanToken == "" then
        allEntities = {}
        browserIndex = nil
        browserLoading = false
        browserLoadingSince = nil
        render()
        return
    end

    browserLoading = true
    browserLoadingSince = os.clock()
    browserFailed = false
    render()

    -- Least fragile first: the tab template covers instances without to_json, the id-only
    -- one those that reject `name`, and /api/states is last because it is the largest.
    fetchAllEntitiesFromTemplate(ENTITY_JSON_TEMPLATE, "Entity JSON", stepPairs, function()
        fetchAllEntitiesFromTemplate(ENTITY_LIST_TEMPLATE, "Entity list", stepLines, function()
            fetchAllEntitiesFromTemplate(ENTITY_ID_TEMPLATE, "Entity id", stepLines, fetchAllEntitiesFromStates)
        end)
    end)
end

local function initDraft(entityId)
    if sliderDraft[entityId] then return end
    local e = entityStates[entityId]
    local ct = e and e.color_temp or -1
    local ctKelvin
    if ct > 500 then ctKelvin = math.floor(ct + 0.5)
    elseif ct > 0 then ctKelvin = math.floor(1000000 / ct + 0.5)
    else ctKelvin = 4000 end
    sliderDraft[entityId] = {
        brightness = e and (e.brightness > 0 and e.brightness or 255) or 255,
        color_temp = ctKelvin,
        hue        = e and (e.hue or 0) or 0,
    }
end

local function markDirty(key)
    if not expandedEntityId then return end
    if not sliderDirty[expandedEntityId] then sliderDirty[expandedEntityId] = {} end
    sliderDirty[expandedEntityId][key] = true
end

local function clearPending(entityId)
    pendingToggle[entityId] = nil
    pendingSince[entityId] = nil
end

local function isPendingTimedOut(entityId, now)
    local startedAt = pendingSince[entityId]
    if not startedAt then return false end
    return (now or os.clock()) - startedAt >= PENDING_TIMEOUT_SECONDS
end

local function reconcilePending(now)
    local changed = false
    for entityId, expected in pairs(pendingToggle) do
        local real = entityStates[entityId]
        if not real or real.state == expected or isPendingTimedOut(entityId, now) then
            clearPending(entityId)
            changed = true
        end
    end
    return changed
end

local function actEntity(eid)
    local entity = entityStates[eid]
    if not entity then return end
    local d = entity.domain
    if d == "script" then callService("script", "turn_on", eid)
    elseif d == "automation" then callService("automation", "trigger", eid)
    else
        local newState = entity.state == "on" and "off" or "on"
        pendingToggle[eid] = newState
        pendingSince[eid] = os.clock()
        callService(d, "toggle", eid, function()
            clearPending(eid)
            render()
        end)
        render()
    end
end

local function expandEntity(eid)
    if expandedEntityId == eid then
        expandedEntityId = nil
    else
        sliderDraft[eid] = nil
        sliderDirty[eid] = nil
        expandedEntityId = eid
    end
    render()
end

function onBrightness(value)
    if not expandedEntityId then return end
    initDraft(expandedEntityId)
    sliderDraft[expandedEntityId].brightness = math.floor((tonumber(value) or 255) + 0.5)
    markDirty("brightness")
    render()
end

function onColorTemp(value)
    if not expandedEntityId then return end
    initDraft(expandedEntityId)
    sliderDraft[expandedEntityId].color_temp = math.floor((tonumber(value) or 4000) + 0.5)
    markDirty("color_temp")
    render()
end

function onHue(value)
    if not expandedEntityId then return end
    initDraft(expandedEntityId)
    sliderDraft[expandedEntityId].hue = math.floor((tonumber(value) or 0) + 0.5)
    markDirty("hue")
    render()
end

function onApplyLight()
    if not expandedEntityId then return end
    local draft = sliderDraft[expandedEntityId]
    local dirty = sliderDirty[expandedEntityId] or {}
    local entity = entityStates[expandedEntityId]
    if not draft or not entity then return end

    local data = { entity_id = expandedEntityId }
    if dirty.hue and entity.supports_rgb then
        data.hs_color = { draft.hue, 100 }
        if dirty.brightness and entity.supports_brightness then
            data.brightness = draft.brightness
        end
    else
        if dirty.brightness and entity.supports_brightness then
            data.brightness = draft.brightness
        end
        if dirty.color_temp and entity.supports_color_temp then
            data.color_temp_kelvin = draft.color_temp
        end
    end

    if dirty.brightness or dirty.color_temp or dirty.hue then
        haPost("/api/services/light/turn_on", data)
        sliderDirty[expandedEntityId] = {}
    end
end

function onNoop() end

function onOpenBrowser()
    view = "browser"
    searchText = ""
    fetchAllEntities()
end

function onBackToList()
    view = "list"
    allEntities = {}
    browserIndex = nil
    searchText = ""
    browserFailed = false
    render()
end

function onSearchChange(value)
    searchText = value or ""
    render()
end

local function isControllable(domain)
    return domain == "light" or domain == "switch" or domain == "input_boolean"
        or domain == "fan" or domain == "cover" or domain == "lock"
end

local function isSensor(domain)
    return domain == "sensor" or domain == "binary_sensor" or domain == "weather" or domain == "number"
end

local function isAutomation(domain)
    return domain == "automation" or domain == "script"
end

local function domainGlyph(domain)
    local g = {
        light = "bulb", switch = "toggle-right", input_boolean = "toggle-right",
        sensor = "chart-line", binary_sensor = "activity", climate = "temperature",
        cover = "door", fan = "wind", lock = "lock", media_player = "device-speaker",
        weather = "cloud", automation = "robot", script = "player-play",
    }
    return g[domain] or "smart-home"
end

local function stateGlyph(domain, isOn)
    if domain == "light" then return isOn and "bulb" or "bulb-off"
    elseif domain == "switch" or domain == "input_boolean" then return isOn and "toggle-right" or "toggle-left"
    elseif domain == "fan" then return isOn and "wind" or "wind-off"
    elseif domain == "lock" then return isOn and "lock" or "lock-open"
    elseif domain == "cover" then return isOn and "door-open" or "door"
    end
    return domainGlyph(domain)
end

local function entityStateLabel(entity)
    if isSensor(entity.domain) then
        return entity.state .. (entity.unit ~= "" and " " .. entity.unit or "")
    end
    if entity.domain == "light" and entity.state == "on" and entity.brightness >= 0 then
        local pct = math.floor(entity.brightness / 255 * 100 + 0.5)
        return tr("state_on_brightness", { percent = pct })
    end
    return entity.state
end

local function buildExpandedSection(entity)
    local eid = entity.entity_id
    initDraft(eid)
    local draft = sliderDraft[eid]
    local rows = {}

    if entity.supports_brightness then
        local bv = draft.brightness
        table.insert(rows, ui.row({ align = "center", gap = 8 }, {
            ui.label({ text = tr("brightness"), color = "on_surface_variant" }),
            ui.slider({ min = 1, max = 255, step = 1, value = bv, onChange = "onBrightness", flexGrow = 1 }),
            ui.label({ text = math.floor(bv / 255 * 100 + 0.5) .. "%" }),
        }))
    end

    if entity.supports_color_temp then
        local ctk = draft.color_temp
        table.insert(rows, ui.row({ align = "center", gap = 8 }, {
            ui.label({ text = tr("color_temp"), color = "on_surface_variant" }),
            ui.slider({ min = 2000, max = 6500, step = 50, value = ctk, onChange = "onColorTemp", flexGrow = 1 }),
            ui.label({ text = math.floor(ctk) .. "K" }),
        }))
    end

    if entity.supports_rgb then
        local hv = draft.hue
        table.insert(rows, ui.row({ align = "center", gap = 8 }, {
            ui.label({ text = tr("hue"), color = "on_surface_variant" }),
            ui.slider({ min = 0, max = 360, step = 1, value = hv, onChange = "onHue", flexGrow = 1 }),
            ui.label({ text = math.floor(hv) .. "°" }),
        }))
    end

    if #rows == 0 then return nil end

    table.insert(rows, ui.row({ justify = "end" }, {
        ui.button({ glyph = "check", onClick = "onApplyLight" }),
    }))

    return ui.column({ gap = 8 }, rows)
end

local function buildEntityCard(entity)
    local pending = pendingToggle[entity.entity_id]
    local isOn = (pending or entity.state) == "on"
    local domain = entity.domain
    local canExpand = domain == "light"
        and (entity.supports_brightness or entity.supports_color_temp or entity.supports_rgb)
    local isExpanded = expandedEntityId == entity.entity_id

    local expandBtn
    if canExpand then
        expandBtn = ui.button({
            glyph = isExpanded and "chevron-up" or "chevron-down",
            onClick = function() expandEntity(entity.entity_id) end,
        })
    end

    local isPending = pending ~= nil
    local iconClick = isPending and "onNoop"
        or (isControllable(domain) or isAutomation(domain)) and function() actEntity(entity.entity_id) end or "onNoop"
    local iconGlyph = isPending and "loader"
        or isAutomation(domain) and "player-play" or stateGlyph(domain, isOn)

    local rowChildren = {
        ui.button({ glyph = iconGlyph, onClick = iconClick }),
                ui.column({ flexGrow = 1, gap = 2 }, {
            ui.label({ text = entity.friendly_name or entity.entity_id, fontWeight = "medium" }),
            ui.label({ text = entityStateLabel(entity), color = "on_surface_variant", fontSize = 12 }),
        }),
    }
    if expandBtn then table.insert(rowChildren, expandBtn) end

    local cardChildren = { ui.row({ align = "center", gap = 8 }, rowChildren) }

    if isExpanded then
        local expanded = buildExpandedSection(entity)
        if expanded then table.insert(cardChildren, expanded) end
    end

    return ui.column({ gap = 8 }, cardChildren)
end

local function getOrderedIds()
    local ids, seen = {}, {}
    for _, eid in ipairs(monitoredEntities) do
        if entityStates[eid] then
            table.insert(ids, eid)
            seen[eid] = true
        end
    end
    for eid in pairs(entityStates) do
        if not seen[eid] then
            table.insert(ids, eid)
        end
    end
    return ids
end

local function buildListBody(ids)
    if not getCleanUrl() or getCleanUrl() == "" or getCleanToken() == "" then
        return ui.label({ text = tr("not_configured"), color = "on_surface_variant" })
    end
    if status == "auth_failed" then
        return ui.label({ text = tr("auth_failed"), color = "error" })
    end
    if status == "connecting" then
        return ui.label({ text = tr("connecting"), color = "on_surface_variant" })
    end
    if status == "disconnected" then
        return ui.label({ text = tr("disconnected_reconnecting"), color = "error" })
    end
    if status == "unreachable" then
        return ui.label({ text = tr("unreachable"), color = "error" })
    end
    if #ids == 0 then
        return ui.label({
            text = status == "connected"
                and tr("no_entities_monitored")
                or tr("status_fallback", { status = status }),
            color = "on_surface_variant",
        })
    end
    local shown = math.min(#ids, MAX_LIST_CARDS)
    local cards = {}
    for i = 1, shown do
        table.insert(cards, buildEntityCard(entityStates[ids[i]]))
    end
    if #ids > shown then
        table.insert(cards, ui.label({
            text = tr("list_truncated", { count = shown, total = #ids }),
            color = "on_surface_variant",
            fontSize = 12,
        }))
    end
    return ui.scroll({ flexGrow = 1, gap = 8 }, cards)
end

local function buildBrowserBody()
    if browserLoading then
        if browserJob ~= nil and browserJob.count > 0 then
            return ui.label({
                text = tr("loading_entities_count", { count = browserJob.count }),
                color = "on_surface_variant",
            })
        end
        return ui.label({ text = tr("loading_entities"), color = "on_surface_variant" })
    end
    if browserFailed then
        return ui.label({ text = tr("load_entities_failed"), color = "error" })
    end
    -- Index and list are handed over together.
    if #allEntities == 0 or browserIndex == nil then
        return ui.label({ text = tr("no_entities_found"), color = "on_surface_variant" })
    end

    local q = searchText:lower()
    local filtered = {}
    local truncated = false
    local total = #allEntities

    if q == "" then
        for i = 1, math.min(total, MAX_BROWSER_ROWS) do
            filtered[i] = allEntities[i]
        end
        truncated = total > MAX_BROWSER_ROWS
    else
        local blob, offsets = browserIndex.blob, browserIndex.offsets
        local blobEnd = #blob + 1
        local pos, lo = 1, 1
        while true do
            local hit = string.find(blob, q, pos, true)
            if not hit then break end
            if #filtered >= MAX_BROWSER_ROWS then
                truncated = true
                break
            end

            -- Which entity owns that byte. Hits move forwards, so the last match is a floor.
            local hi = total
            while lo < hi do
                local mid = (lo + hi + 1) // 2
                if offsets[mid] <= hit then lo = mid else hi = mid - 1 end
            end
            filtered[#filtered + 1] = allEntities[lo]

            -- Past the record, not past the hit: one row per entity, and a linear walk.
            lo += 1
            pos = lo <= total and offsets[lo] or blobEnd
        end
    end

    if #filtered == 0 then
        return ui.label({ text = tr("no_entities_match"), color = "on_surface_variant" })
    end

    local pinnedSet = {}
    for _, eid in ipairs(monitoredEntities) do
        pinnedSet[eid] = true
    end

    local rows = {}
    for _, e in ipairs(filtered) do
        local entityId = e.entity_id
        local pinned = pinnedSet[entityId] == true
        table.insert(rows, ui.row({ align = "center", gap = 8 }, {
            ui.column({ flexGrow = 1, gap = 2 }, {
                ui.label({ text = e.friendly_name, fontWeight = "medium" }),
                ui.label({ text = e.entity_id, color = "on_surface_variant", fontSize = 12 }),
            }),
            ui.button({ glyph = pinned and "pin-filled" or "pin", onClick = function() toggleBrowserPin(entityId) end }),
        }))
    end

    if truncated then
        table.insert(rows, ui.label({
            text = tr("browser_truncated", { count = MAX_BROWSER_ROWS }),
            color = "on_surface_variant",
            fontSize = 12,
        }))
    end

    return ui.scroll({ flexGrow = 1, gap = 4 }, rows)
end

function render()
    reconcilePending(os.clock())

    if view == "browser" then
        panel.render(ui.column({ flexGrow = 1, gap = 16 }, {
            ui.row({ align = "center", gap = 8 }, {
                ui.button({ glyph = "arrow-left", onClick = "onBackToList" }),
                ui.label({ text = tr("manage_entities_title"), fontSize = 16, fontWeight = "bold", color = "primary", flexGrow = 1 }),
                ui.button({ glyph = "close", onClick = "onCloseClicked" }),
            }),
            ui.input({ key = "entity_search", placeholder = tr("search_placeholder"), onChange = "onSearchChange" }),
            buildBrowserBody(),
        }))
    else
        local ids = getOrderedIds()
        panel.render(ui.column({ flexGrow = 1, gap = 16 }, {
            ui.row({ align = "center", gap = 8 }, {
                ui.glyph({ name = "smart-home", size = 20, color = "primary" }),
                ui.label({ text = noctalia.tr("shortcut.title"), fontSize = 16, fontWeight = "bold", color = "primary", flexGrow = 1 }),
                ui.label({ text = getStatusText(), color = status == "connected" and "primary" or "on_surface_variant" }),
                ui.button({ glyph = "list-search", onClick = "onOpenBrowser" }),
                ui.button({ glyph = "close", onClick = "onCloseClicked" }),
            }),
            buildListBody(ids),
        }))
    end
end

function onOpen(_context)
    status = noctalia.state.get("connection_status") or "unconfigured"
    entityStates = noctalia.state.get("entities") or {}
    loadMonitoredEntities()
    panelOpenCount = panelOpenCount + 1
    panel.setWantsSecondTicks(true)
    noctalia.state.set("panel_open_signal", panelOpenCount)
    render()
end

function onClose()
    panel.setWantsSecondTicks(false)
end

function update()
    local now = os.clock()

    -- A load still parsing outranks the network timeout. What it gives up on is a job that
    -- stops advancing, not one that is merely slow: a tick only spends a few ms, so a large
    -- instance legitimately takes a minute or more of them, the more so on slow hardware.
    if browserJob ~= nil then
        local job = browserJob
        local mark = job.phase .. tostring(job.cursor) .. "/" .. tostring(job.count)
        if mark ~= job.mark then
            job.mark = mark
            job.markAt = now
        elseif (now - job.markAt) > BROWSER_STALL_SECONDS then
            noctalia.log("Entity parse stalled in phase " .. job.phase .. "; giving up")
            browserJob = nil
            finishBrowserLoad({}, nil, true)
            return
        end
        runBrowserJob(SLICE_TICK)
        -- finishBrowserLoad already rendered if the job landed on this tick.
        if browserJob ~= nil then render() end
        return
    end

    if browserLoading and browserLoadingSince and (now - browserLoadingSince) > BROWSER_TIMEOUT_SECONDS then
        browserLoading = false
        browserLoadingSince = nil
        browserFailed = true
        reconcilePending(now)
        render()
        return
    end

    if reconcilePending(now) then
        render()
    end
end

function onCloseClicked()
    panel.close()
end

-- The browser view reads neither entityStates nor status, and onBackToList renders on the
-- way out, so rendering here would rebuild the filtered list per publish for nothing.
noctalia.state.watch("entities", function(value)
    entityStates = value or {}
    reconcilePending(os.clock())
    if view ~= "browser" then render() end
end)

noctalia.state.watch("connection_status", function(value)
    status = value or "unconfigured"
    if view ~= "browser" then render() end
end)
