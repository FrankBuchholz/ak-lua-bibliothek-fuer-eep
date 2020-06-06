if AkDebugLoad then print("Loading ak.road.Crossing ...") end

local Task = require("ak.scheduler.Task")
local Scheduler = require("ak.scheduler.Scheduler")
local StorageUtility = require("ak.storage.StorageUtility")
local CrossingSequence = require("ak.road.CrossingSequence")
local TrafficLightState = require("ak.road.TrafficLightState")
local fmt = require("ak.core.eep.TippTextFormatter")

--------------------
-- Klasse Kreuzung
--------------------
local allCrossings = {}
---@class Crossing
---@field public name string @Intersection Name
---@field private currentSequence CrossingSequence @Currently used sequence
---@field private sequences CrossingSequence[] @All sequences of the intersection
---@field private greenPhaseFinished boolean @If true, the Intersection can be switched
---@field private greenPhaseSeconds number @Integer value of how long the intersection will show green light
---@field private staticCams table @List of static cams
local Crossing = {}
Crossing.debug = AkStartMitDebug or false
---@type table<string,Crossing>
Crossing.allCrossings = {}
Crossing.showRequestsOnSignal = AkStartMitDebug or false
Crossing.showSequenceOnSignal = AkStartMitDebug or false
Crossing.showSignalIdOnSignal = false

function Crossing.loadSettingsFromSlot(eepSaveId)
    StorageUtility.registerId(eepSaveId, "Crossing settings")
    Crossing.saveSlot = eepSaveId
    local data = StorageUtility.loadTable(Crossing.saveSlot, "Crossing settings")
    Crossing.showRequestsOnSignal = StorageUtility.toboolean(data["reqInfo"]) or Crossing.showRequestsOnSignal
    Crossing.showSequenceOnSignal = StorageUtility.toboolean(data["seqInfo"]) or Crossing.showSequenceOnSignal
    Crossing.showSignalIdOnSignal = StorageUtility.toboolean(data["sigInfo"]) or Crossing.showSignalIdOnSignal
end

function Crossing.saveSettings()
    if Crossing.saveSlot then
        local data = {
            reqInfo = tostring(Crossing.showRequestsOnSignal),
            seqInfo = tostring(Crossing.showSequenceOnSignal),
            sigInfo = tostring(Crossing.showSignalIdOnSignal)
        }
        StorageUtility.saveTable(Crossing.saveSlot, data, "Crossing settings")
    end
end

function Crossing.setShowRequestsOnSignal(value)
    assert(value == true or value == false)
    Crossing.showRequestsOnSignal = value
    Crossing.saveSettings()
end

function Crossing.setShowSequenceOnSignal(value)
    assert(value == true or value == false)
    Crossing.showSequenceOnSignal = value
    Crossing.saveSettings()
end

function Crossing.setShowSignalIdOnSignal(value)
    assert(value == true or value == false)
    Crossing.showSignalIdOnSignal = value
    Crossing.saveSettings()
end

function Crossing.switchManuallyTo(crossingName, sequenceName)
    print("switchManuallyTo:" .. crossingName .. "/" .. sequenceName)
    ---@type Crossing
    local k = Crossing.allCrossings[crossingName]
    if k then k:setManualSequence(sequenceName) end
end

function Crossing.switchAutomatically(crossingName)
    print("switchAutomatically:" .. crossingName)
    ---@type Crossing
    local k = Crossing.allCrossings[crossingName]
    if k then k:setAutomaticSequence() end
end

function Crossing.getType() return "Crossing" end

function Crossing:getName() return self.name end

function Crossing:getSequences() return self.sequences end

function Crossing:getAktuelleSchaltung() return self.currentSequence end

function Crossing:onSwitchedToSequence(nextSchaltung)
    for _, lane in pairs(self.lanes) do
        if nextSchaltung:getLanes()[lane] then
            lane:resetWaitCount()
        else
            lane:incrementWaitCount()
        end
    end
    self.currentSequence = nextSchaltung
end

---@return CrossingSequence
function Crossing:calculateNextSequence()
    if self.manualSequence then
        self.nextSchaltung = self.manualSequence
    else
        local sortedTable = {}
        for sequence in pairs(self.sequences) do table.insert(sortedTable, sequence) end
        table.sort(sortedTable, CrossingSequence.sequencePriorityComparator)
        self.nextSchaltung = sortedTable[1]
    end
    return self.nextSchaltung
end

function Crossing:setManualSequence(sequenceName)
    for sequence in pairs(self.sequences) do
        if sequence.name == sequenceName then
            self.manualSequence = sequence
            print("Manuell geschaltet auf: " .. sequence .. " (" .. self.name .. "')")
            self:setGreenPhaseFinished(true)
        end
    end
end

function Crossing:setAutomaticSequence()
    self.manualSequence = nil
    self:setGreenPhaseFinished(true)
    print("Automatikmodus aktiviert. (" .. self.name .. "')")
end

function Crossing:getGreenPhaseSeconds() return self.greenPhaseSeconds end

function Crossing:setGreenPhaseFinished(greenPhaseFinished) self.greenPhaseFinished = greenPhaseFinished end

function Crossing:isGreenPhaseFinished() return self.greenPhaseFinished end

function Crossing:setGreenPhaseReached(greenPhaseReached) self.greenPhaseReached = greenPhaseReached end

function Crossing:isGreenPhaseReached() return self.greenPhaseReached end

function Crossing:addStaticCam(kameraName) table.insert(self.staticCams, kameraName) end

function Crossing.resetVehicles()
    for _, crossing in pairs(allCrossings) do
        print("[Crossing ] SETZE ZURUECK: " .. crossing.name)
        if crossing.lanes then for _, lane in pairs(crossing.lanes) do lane:resetVehicles() end end
    end
end

--- Erzeugt eine neue Kreuzung und registriert diese automatisch fuer das automatische Schalten.
-- Fuegen sie Schaltungen zu dieser Kreuzung hinzu.
-- @param name string name of the crossing
-- @param greenPhaseSeconds nubmer number of seconds for a default green phase
---@return Crossing
function Crossing:new(name, greenPhaseSeconds)
    local o = {
        name = name,
        currentSequence = nil,
        sequences = {},
        lanes = {},
        pedestrianCrossings = {},
        trafficLights = {},
        pedestrianLights = {},
        greenPhaseReached = true,
        greenPhaseFinished = true,
        greenPhaseSeconds = greenPhaseSeconds or 15,
        staticCams = {}
    }
    self.__index = self
    setmetatable(o, self)
    Crossing.allCrossings[name] = o
    allCrossings[name] = o
    table.sort(allCrossings, function(name1, name2) return name1 < name2 end)
    return o
end

--- Erzeugt eine Fahrspur, welche durch eine Ampel gesteuert wird.
---@param name string @Name of the Pedestrian Crossing einer Kreuzung
function Crossing:newSequence(name, greenPhaseSeconds)
    local sequence = CrossingSequence:new(name, greenPhaseSeconds or self.greenPhaseSeconds)
    self:addSequence(sequence)
    return sequence
end

function Crossing:addSequence(sequence)
    sequence.crossing = self
    self.sequences[sequence] = true
    return sequence
end

local function allTrafficLights(circuits)
    local list = {}

    for sequence in pairs(circuits) do
        assert(sequence.getType() == "CrossingSequence", type(sequence))
        for _, trafficLight in pairs(sequence.trafficLights) do list[trafficLight] = true end
        for _, trafficLight in pairs(sequence.pedestrianLights) do list[trafficLight] = true end
    end

    return list
end

---------------------------
-- Funktion switchTrafficLights
---------------------------
local function switch(crossing)
    if Crossing.debug then
        print(string.format("[Crossing ] Schalte Kreuzung %s: %s", crossing:getName(),
                            crossing:isGreenPhaseFinished() and "Ja" or "Nein"))
    end
    if not crossing:isGreenPhaseFinished() or not crossing.greenPhaseReached then do return true end end

    local TrafficLight = require("ak.road.TrafficLight")
    crossing.greenPhaseReached = false
    crossing:setGreenPhaseFinished(false)
    ---@type CrossingSequence
    local nextSequence = crossing:calculateNextSequence()
    local nextName = crossing.name .. " " .. nextSequence:getName()
    local currentCircuit = crossing:getAktuelleSchaltung()
    local currentName = currentCircuit and crossing.name .. " " .. currentCircuit:getName() or crossing.name ..
                            " Rot fuer alle"
    local greenPhaseSeconds = nextSequence.greenPhaseSeconds

    local trafficLightsToTurnRed, trafficLightsToTurnGreen =
        nextSequence:trafficLightsToTurnRedAndGreen(currentCircuit)
    local pedestrianLightsToTurnRed, pedestrianLightsToTurnGreen =
        nextSequence:pedestrianLightsToTurnRedAndGreen(currentCircuit)

    -- If there is no current sequence, we need to reset all old signals
    local lastTask
    if currentCircuit then
        if Crossing.debug then
            print("[Crossing ] Schalte " .. crossing:getName() .. " zu " .. nextSequence:getName() .. " (" ..
                      nextSequence:lanesNamesText() .. ")")
        end

        local reasonPed = "Schalte " .. currentName .. " auf Fussgaenger Rot"
        local turnPedestrianRed = Task:new(function()
            TrafficLight.switchAll(pedestrianLightsToTurnRed, TrafficLightState.RED, reasonPed)
        end, "Schalte " .. currentName .. " auf Fussgaenger Rot")
        Scheduler:scheduleTask(3, turnPedestrianRed)

        -- * Hier k�nnte noch die DDR-Schaltung rein (2 Sekunden gr�n-gelb)

        local reasonYellow = "Schalte " .. currentName .. " auf gelb"
        local turnTrafficLightsYellow = Task:new(function()
            TrafficLight.switchAll(trafficLightsToTurnRed, TrafficLightState.YELLOW, reasonYellow)
        end, reasonYellow)
        Scheduler:scheduleTask(0, turnTrafficLightsYellow, turnPedestrianRed)

        local reasonRed = "Schalte " .. currentName .. " auf rot"
        local turnTrafficLightsRed = Task:new(function()
            TrafficLight.switchAll(trafficLightsToTurnRed, TrafficLightState.RED, reasonRed)
        end, reasonRed)
        Scheduler:scheduleTask(2, turnTrafficLightsRed, turnTrafficLightsYellow)
        lastTask = turnTrafficLightsRed
    else
        local reason = "Schalte initial auf rot"
        trafficLightsToTurnRed = allTrafficLights(crossing.sequences)
        TrafficLight.switchAll(trafficLightsToTurnRed, TrafficLightState.RED, reason)
        lastTask = Task:new(function() end, "clear crossing")
        Scheduler:scheduleTask(3, lastTask)
    end

    local reasonRedYellow = "Schalte " .. nextName .. " auf rot-gelb"
    local turnNextTrafficLightsYellow = Task:new(function()
        TrafficLight.switchAll(trafficLightsToTurnGreen, TrafficLightState.REDYELLOW, reasonRedYellow)
        TrafficLight.switchAll(pedestrianLightsToTurnGreen, TrafficLightState.PEDESTRIAN, reasonRedYellow)
    end, reasonRedYellow)
    Scheduler:scheduleTask(3, turnNextTrafficLightsYellow, lastTask)

    local reasonGreen = "Schalte " .. nextName .. " auf gruen"
    local turnNextTrafficLightsGreen = Task:new(function()
        TrafficLight.switchAll(trafficLightsToTurnGreen, TrafficLightState.GREEN, reasonGreen)
        crossing:onSwitchedToSequence(nextSequence)
        crossing.greenPhaseReached = true
    end, reasonGreen)
    Scheduler:scheduleTask(1, turnNextTrafficLightsGreen, turnNextTrafficLightsYellow)

    local changeToReadyStatus = Task:new(function()
        if Crossing.debug then
            print("[Crossing ] " .. crossing.name .. ": Fahrzeuge sind gefahren, kreuzung ist dann frei.")
        end
        crossing:setGreenPhaseFinished(true)
    end, crossing.name .. " ist nun bereit (war " .. greenPhaseSeconds .. "s auf gruen geschaltet)")
    Scheduler:scheduleTask(greenPhaseSeconds, changeToReadyStatus, turnNextTrafficLightsGreen)
end

--- Diese Funktion sucht sich aus den Ampeln die mit der passenden Fahrspur
-- raus und setzt deren Texte auf die aktuelle Schaltung
-- @param kreuzung
local function recalculateSignalInfo(crossing)
    for _, lane in pairs(crossing.lanes) do lane:checkRequests() end

    local trafficLights = {}
    local sequences = {}

    -- sort the circuits
    local sortedSequences = {}
    for k in pairs(crossing:getSequences()) do table.insert(sortedSequences, k) end
    table.sort(sortedSequences, function(s1, s2) return (s1.name < s2.name) end)

    for _, sequence in ipairs(sortedSequences) do
        for _, tl in pairs(sequence.trafficLights) do
            sequences[tl.signalId] = sequences[tl.signalId] or {}
            sequences[tl.signalId][sequence] = TrafficLightState.GREEN
            trafficLights[tl] = true
        end
        for _, tl in pairs(sequence.pedestrianLights) do
            sequences[tl.signalId] = sequences[tl.signalId] or {}
            sequences[tl.signalId][sequence] = TrafficLightState.PEDESTRIAN
            trafficLights[tl] = true
        end
    end

    local trafficLightsToRefresh = {}
    for _, lane in pairs(crossing.lanes) do
        local trafficLight = lane.trafficLight
        trafficLightsToRefresh[trafficLight.signalId] = trafficLight
        local text = "<br></j>" .. lane:getRequestInfo() .. " / " .. lane.waitCount
        trafficLight:setLaneInfo(text)
    end

    for trafficLight in pairs(trafficLights) do
        trafficLightsToRefresh[trafficLight.signalId] = trafficLight
        do
            local text = ""
            for _, sequence in ipairs(sortedSequences) do
                local farbig = sequence == crossing:getAktuelleSchaltung()
                if sequences[trafficLight.signalId][sequence] then
                    if sequences[trafficLight.signalId][sequence] == TrafficLightState.GREEN then
                        text = text .. "<br><j>" ..
                                   (farbig and fmt.bgGreen(sequence.name .. " (Gruen)") or
                                       (sequence.name .. " " .. fmt.bgGreen("(Gruen)")))
                    elseif sequences[trafficLight.signalId][sequence] == TrafficLightState.PEDESTRIAN then
                        text = text .. "<br><j>" ..
                                   (farbig and fmt.bgYellow(sequence.name .. " (FG)") or
                                       (sequence.name .. " " .. fmt.bgYellow("(FG)")))
                    else
                        assert(false)
                    end
                else
                    text = text .. "<br><j>" ..
                               (farbig and fmt.bgRed(sequence.name .. " (Rot)") or
                                   (sequence.name .. " " .. fmt.bgRed("(Rot)")))
                end
            end
            trafficLight:setSequenceInfo(text)
        end
    end

    for _, trafficLight in pairs(trafficLightsToRefresh) do trafficLight:refreshInfo() end
end

local aufbauHilfeErzeugt = Crossing.showSignalIdOnSignal

--- Init all crossing lanes and traffic lights according to their sequences' traffic lights
--- ----
--- Speichert die Fahrspuren und Ampeln in den einzelnen Kreuzungen --> Weniger Suche danach
function Crossing.initSequences()
    for _, crossing in pairs(allCrossings) do
        for sequence in pairs(crossing.sequences) do
            sequence:initSequence()
            local laneFound = false
            for v in pairs(sequence.lanes) do
                crossing.lanes[v.name] = v
                laneFound = true
            end
            assert(laneFound, "No LANE found in sequence " .. sequence.name .. " (" .. crossing.name .. ")")
            for v in pairs(sequence.pedestrianCrossings) do crossing.pedestrianCrossings[v.name] = v end
            for _, v in pairs(sequence.trafficLights) do crossing.trafficLights[v.signalId] = v end
            for _, v in pairs(sequence.pedestrianLights) do crossing.pedestrianLights[v.signalId] = v end

            if Crossing.debug then
                local text = "[Crossing ] %s - %s: %s"
                print(string.format(text, crossing.name, sequence.name, sequence:lanesNamesText()))
            end
        end
    end
end

--- Switch all sequences according to the current crossing settings
function Crossing.switchSequences()
    if aufbauHilfeErzeugt ~= Crossing.showSignalIdOnSignal then
        aufbauHilfeErzeugt = Crossing.showSignalIdOnSignal
        for signalId = 1, 1000 do
            EEPShowInfoSignal(signalId, Crossing.showSignalIdOnSignal)
            if Crossing.showSignalIdOnSignal then EEPChangeInfoSignal(signalId, "<j>Signal: " .. signalId) end
        end
    end

    for _, crossing in pairs(allCrossings) do
        switch(crossing)
        recalculateSignalInfo(crossing)
    end
end

return Crossing
