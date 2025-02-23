--[[ Copyright (c) 2017 Optera
 * Part of Logistics Train Network
 *
 * See LICENSE.md in the project directory for license information.
--]]

local tools = require('script.tools')

-- update dispatcher Deliveries.force when forces are removed/merged
script.on_event(defines.events.on_forces_merging, function(event)
    local dispatcher = tools.getDispatcher()

    for _, delivery in pairs(dispatcher.Deliveries) do
        if delivery.force == event.source then
            delivery.force = event.destination
        end
    end
end)

---------------------------------- MAIN LOOP ----------------------------------

---@param event EventData.on_tick
function OnTick(event)
    local dispatcher = tools.getDispatcher()

    local tick = event.tick
    -- log("DEBUG: (OnTick) "..tick.." storage.tick_state: "..tostring(storage.tick_state).." storage.tick_stop_index: "..tostring(storage.tick_stop_index).." storage.tick_request_index: "..tostring(storage.tick_request_index) )

    if storage.tick_state == 1 then -- update stops
        for i = 1, dispatcher_updates_per_tick, 1 do
            -- reset on invalid index
            if storage.tick_stop_index and not storage.LogisticTrainStops[storage.tick_stop_index] then
                storage.tick_state = 0

                if message_level >= 2 then tools.printmsg { 'ltn-message.error-invalid-stop-index', storage.tick_stop_index } end
                log(string.format('(OnTick) Invalid storage.tick_stop_index %d in storage.LogisticTrainStops. Removing stop and starting over.', storage.tick_stop_index))

                RemoveStop(storage.tick_stop_index)
                return
            end

            ---@type number, ltn.TrainStop
            local stopID, stop = next(storage.LogisticTrainStops, storage.tick_stop_index)
            if stopID then
                storage.tick_stop_index = stopID

                if debug_log then log(string.format('(OnTick) %d updating stopID %d', tick, stopID)) end

                UpdateStop(stopID, stop)
            else -- stop updates complete, moving on
                storage.tick_stop_index = nil
                storage.tick_state = 2
                return
            end
        end
    elseif storage.tick_state == 2 then -- clean up and sort lists
        storage.tick_state = 3

        -- clean up deliveries in case train was destroyed or removed
        local activeDeliveryTrains = ''
        for trainID, delivery in pairs(dispatcher.Deliveries) do
            if not (delivery.train and delivery.train.valid) then
                local from_entity = storage.LogisticTrainStops[delivery.from_id] and storage.LogisticTrainStops[delivery.from_id].entity
                local to_entity = storage.LogisticTrainStops[delivery.to_id] and storage.LogisticTrainStops[delivery.to_id].entity

                if message_level >= 1 then tools.printmsg({ 'ltn-message.delivery-removed-train-invalid', tools.richTextForStop(from_entity) or delivery.from, tools.richTextForStop(to_entity) or delivery.to }, delivery.force) end
                if debug_log then log(string.format('(OnTick) Delivery from %s to %s removed. Train no longer valid.', delivery.from, delivery.to)) end

                ---@type ltn.EventData.on_delivery_failed
                local data = {
                    train_id = trainID,
                    shipment = delivery.shipment
                }
                script.raise_event(on_delivery_failed_event, data)

                RemoveDelivery(trainID)
            elseif tick - delivery.started > delivery_timeout then
                local from_entity = storage.LogisticTrainStops[delivery.from_id] and storage.LogisticTrainStops[delivery.from_id].entity
                local to_entity = storage.LogisticTrainStops[delivery.to_id] and storage.LogisticTrainStops[delivery.to_id].entity

                if message_level >= 1 then tools.printmsg({ 'ltn-message.delivery-removed-timeout', tools.richTextForStop(from_entity) or delivery.from, tools.richTextForStop(to_entity) or delivery.to, tick - delivery.started }, delivery.force) end
                if debug_log then log(string.format('(OnTick) Delivery from %s to %s removed. Timed out after %d/%d ticks.', delivery.from, delivery.to, tick - delivery.started, delivery_timeout)) end

                ---@type ltn.EventData.on_delivery_failed
                local data = {
                    train_id = trainID,
                    shipment = delivery.shipment
                }
                script.raise_event(on_delivery_failed_event, data)

                RemoveDelivery(trainID)
            else
                activeDeliveryTrains = activeDeliveryTrains .. ' ' .. trainID
            end
        end

        if debug_log then log(string.format('(OnTick) Trains on deliveries: %s', activeDeliveryTrains)) end

        -- remove no longer active requests from dispatcher RequestAge[stopID]
        local newRequestAge = {}
        for _, request in pairs(dispatcher.Requests) do
            local ageIndex = request.item .. ',' .. request.stopID
            local age = dispatcher.RequestAge[ageIndex]
            if age then
                newRequestAge[ageIndex] = age
            end
        end
        dispatcher.RequestAge = newRequestAge

        -- sort requests by priority and age
        table.sort(dispatcher.Requests, function(a, b)
            if a.priority ~= b.priority then
                return a.priority > b.priority
            else
                return a.age < b.age
            end
        end)
    elseif storage.tick_state == 3 then -- parse requests and dispatch trains
        if dispatcher_enabled then
            if debug_log then log(string.format('(OnTick) Available train capacity: %d item stacks, %d fluid capacity.', dispatcher.availableTrains_total_capacity, dispatcher.availableTrains_total_fluid_capacity)) end

            for i = 1, dispatcher_updates_per_tick, 1 do
                -- reset on invalid index
                if storage.tick_request_index and not dispatcher.Requests[storage.tick_request_index] then
                    storage.tick_state = 0

                    if message_level >= 1 then tools.printmsg { 'ltn-message.error-invalid-request-index', storage.tick_request_index } end
                    log(string.format('(OnTick) Invalid storage.tick_request_index %s in dispatcher Requests. Starting over.', tostring(storage.tick_request_index)))

                    return
                end

                local request_index, request = next(dispatcher.Requests, storage.tick_request_index)
                if request_index and request then
                    storage.tick_request_index = request_index

                    if debug_log then log(string.format('(OnTick) %d parsing request %d/%d', tick, request_index, #dispatcher.Requests)) end

                    ProcessRequest(request_index, request)
                else -- request updates complete, moving on
                    storage.tick_request_index = nil
                    storage.tick_state = 4
                    return
                end
            end
        else
            if message_level >= 1 then tools.printmsg { 'ltn-message.warning-dispatcher-disabled' } end
            if debug_log then log('(OnTick) Dispatcher disabled.') end

            storage.tick_request_index = nil
            storage.tick_state = 4
            return
        end
    elseif storage.tick_state == 4 then -- raise API events
        storage.tick_state = 0
        -- raise events for mod API

        ---@type ltn.EventData.on_stops_updated
        local stops_data = {
            logistic_train_stops = storage.LogisticTrainStops,
        }
        script.raise_event(on_stops_updated_event, stops_data)

        ---@type ltn.EventData.on_dispatcher_updated
        local dispatcher_data = {
            update_interval = tick - storage.tick_interval_start,
            provided_by_stop = dispatcher.Provided_by_Stop,
            requests_by_stop = dispatcher.Requests_by_Stop,
            new_deliveries = dispatcher.new_Deliveries,
            deliveries = dispatcher.Deliveries,
            available_trains = dispatcher.availableTrains,
        }
        script.raise_event(on_dispatcher_updated_event, dispatcher_data)

    else -- reset
        storage.tick_stop_index = nil
        storage.tick_request_index = nil

        storage.tick_state = 1
        storage.tick_interval_start = tick
        -- clear Dispatcher.Storage
        dispatcher.Provided = {}
        dispatcher.Requests = {}
        dispatcher.Provided_by_Stop = {}
        dispatcher.Requests_by_Stop = {}
        dispatcher.new_Deliveries = {}
    end
end

---------------------------------- DISPATCHER FUNCTIONS ----------------------------------

-- ensures removal of trainID from dispatcher Deliveries and stop.active_deliveries

---@param trainID number
function RemoveDelivery(trainID)
    local dispatcher = tools.getDispatcher()

    for stopID, stop in pairs(storage.LogisticTrainStops) do
        if not stop.entity.valid or not stop.input.valid or not stop.output.valid or not stop.lamp_control.valid then
            RemoveStop(stopID)
        else
            for i = #stop.active_deliveries, 1, -1 do --trainID should be unique => checking matching stop name not required
                if stop.active_deliveries[i] == trainID then
                    table.remove(stop.active_deliveries, i)
                    if #stop.active_deliveries > 0 then
                        setLamp(stop, 'yellow', #stop.active_deliveries)
                    else
                        setLamp(stop, 'green', 1)
                    end
                end
            end
        end
    end
    dispatcher.Deliveries[trainID] = nil
end

-- NewScheduleRecord: returns new schedule_record

---@type WaitCondition
local condition_circuit_red = { type = 'circuit', compare_type = 'and', condition = { comparator = '=', first_signal = { type = 'virtual', name = 'signal-red' }, constant = 0 } }

---@type WaitCondition
local condition_circuit_green = { type = 'circuit', compare_type = 'or', condition = { comparator = '≥', first_signal = { type = 'virtual', name = 'signal-green' }, constant = 1 } }

---@type WaitCondition
local condition_wait_empty = { type = 'empty', compare_type = 'and' }

---@type WaitCondition
local condition_finish_loading = { type = 'inactivity', compare_type = 'and', ticks = 120 }
-- local condition_stop_timeout -- set in settings.lua to capture changes

---@class ltn.NewScheduleRecordParameters
---@field stationName string
---@field condType WaitConditionType
---@field condComp ComparatorString?
---@field itemList ltn.ItemLoadingElement[]?
---@field countOverride number?
---@field ticks number?

---@param map ltn.NewScheduleRecordParameters
function NewScheduleRecord(map)
    assert(map.stationName)
    assert(map.condType)

    ---@type ScheduleRecord
    local record = {
        station = map.stationName,
        wait_conditions = {}
    }

    local countOverride = map.countOverride and map.countOverride

    if map.condType == 'time' then
        assert(map.ticks)
        table.insert(record.wait_conditions, { type = map.condType, compare_type = 'and', ticks = map.ticks })
    elseif map.condType == 'item_count' then
        assert(map.condComp)
        assert(map.itemList)

        local waitEmpty = false
        -- write itemlist to conditions
        for i = 1, #map.itemList do
            local condFluid = nil
            if map.itemList[i].item.type == 'fluid' then
                condFluid = 'fluid_count'
                -- workaround for leaving with fluid residue due to Factorio rounding down to 0
                if map.condComp == '=' and countOverride == 0 then
                    waitEmpty = true
                end
            end

            -- make > into >=
            if map.condComp == '>' then
                countOverride = map.itemList[i].count - 1
            end

            ---@type CircuitCondition
            local cond = {
                comparator = map.condComp,
                first_signal = map.itemList[i].item,
                constant = countOverride or map.itemList[i].count
            }
            table.insert(record.wait_conditions, { type = condFluid or map.condType, compare_type = 'and', condition = cond })
        end

        if waitEmpty then
            table.insert(record.wait_conditions, condition_wait_empty)
        elseif finish_loading then -- let inserter/pumps finish
            table.insert(record.wait_conditions, condition_finish_loading)
        end

        -- with circuit control enabled keep trains waiting until red = 0 and force them out with green ≥ 1
        if schedule_cc then
            table.insert(record.wait_conditions, condition_circuit_red)
            table.insert(record.wait_conditions, condition_circuit_green)
        end

        if stop_timeout > 0 then -- send stuck trains away when stop_timeout is set
            table.insert(record.wait_conditions, condition_stop_timeout)
            -- should it also wait for red = 0?
            if schedule_cc then
                table.insert(record.wait_conditions, condition_circuit_red)
            end
        end
    elseif map.condType == 'inactivity' then
        assert(map.ticks)
        table.insert(record.wait_conditions, { type = map.condType, compare_type = 'and', ticks = map.ticks })
        -- with circuit control enabled keep trains waiting until red = 0 and force them out with green ≥ 1
        if schedule_cc then
            table.insert(record.wait_conditions, condition_circuit_red)
            table.insert(record.wait_conditions, condition_circuit_green)
        end
    end
    return record
end

local temp_wait_condition = { { type = 'time', compare_type = 'and', ticks = 0 } }

-- NewScheduleRecord: returns new schedule_record for waypoints
function NewTempScheduleRecord(rail, rail_direction)
    local record = { wait_conditions = temp_wait_condition, rail = rail, rail_direction = rail_direction, temporary = true }
    return record
end

---- ProcessRequest ----

-- returns the string "number1|number2" in consistent order: the smaller number is always placed first
local function sorted_pair(number1, number2)
    return (number1 < number2) and (number1 .. '|' .. number2) or (number2 .. '|' .. number1)
end

--- Return a list of matching { entity1, entity2, network_id } each connecting the two surfaces.
--- The list will be empty if surface1 == surface2 and it will be nil if there are no matching connections.
--- The second return value will be the number of entries in the list.
---@param surface1 LuaSurface
---@param surface2 LuaSurface
---@param force LuaForce
---@param network_id number
---@return ltn.SurfaceConnection[]?
---@return number?
local function find_surface_connections(surface1, surface2, force, network_id)
    if surface1 == surface2 then return {}, 0 end

    local surface_pair_key = sorted_pair(surface1.index, surface2.index)
    local surface_connections = storage.ConnectedSurfaces[surface_pair_key]
    if not surface_connections then return nil end

    local matching_connections = {}
    local count = 0
    for entity_pair_key, connection in pairs(surface_connections) do
        if connection.entity1.valid and connection.entity2.valid then
            if bit32.btest(network_id, connection.network_id)
                and connection.entity1.force == force and connection.entity2.force == force then
                count = count + 1
                matching_connections[count] = connection
            end
        else
            if debug_log then log('removing invalid surface connection ' .. entity_pair_key .. ' between surfaces ' .. surface_pair_key) end

            surface_connections[entity_pair_key] = nil
        end
    end

    if count > 0 then
        return matching_connections, count
    else
        return nil, nil
    end
end

-- return a list ordered priority > #active_deliveries > item-count of {entity, network_id, priority, activeDeliveryCount, item, count, providing_threshold, providing_threshold_stacks, min_carriages, max_carriages, locked_slots, surface_connections}
---@param requestStation ltn.TrainStop
---@param item ltn.ItemIdentifier
---@param req_count number
---@param min_length number
---@param max_length number
---@return ltn.Provider[]?
local function getProviders(requestStation, item, req_count, min_length, max_length)
    local dispatcher = tools.getDispatcher()

    ---@type ltn.Provider[]?
    local stations = {}
    local providers = dispatcher.Provided[item] --[[@as table<number, number>? ]]
    if not providers then return nil end

    local toID = requestStation.entity.unit_number
    local force = requestStation.entity.force
    local surface = requestStation.entity.surface

    for stopID, count in pairs(providers) do
        local stop = storage.LogisticTrainStops[stopID]
        if stop and stop.entity.valid then
            local matched_networks = bit32.band(requestStation.network_id, stop.network_id)
            -- log("DEBUG: comparing 0x"..format("%x", bit32.band(requestStation.network_id)).." & 0x"..format("%x", bit32.band(stop.network_id)).." = 0x"..format("%x", bit32.band(matched_networks)) )

            if stop.entity.force == force
                and matched_networks ~= 0
                -- and count >= stop.providing_threshold
                and (stop.min_carriages == 0 or max_length == 0 or stop.min_carriages <= max_length)
                and (stop.max_carriages == 0 or min_length == 0 or stop.max_carriages >= min_length) then
                --check if provider can accept more trains
                local activeDeliveryCount = #stop.active_deliveries
                if activeDeliveryCount and (stop.max_trains == 0 or activeDeliveryCount < stop.max_trains) then
                    -- check if surface transition is possible
                    local surface_connections, surface_connections_count = find_surface_connections(surface, stop.entity.surface, force, matched_networks)
                    if surface_connections then -- for same surfaces surface_connections = {}
                        assert(surface_connections_count)

                        if debug_log then
                            local from_network_id_string = string.format('0x%x', bit32.band(stop.network_id))
                            log(string.format('found %d(%d)/%d %s at %s {%s}, priority: %s, active Deliveries: %d, min_carriages: %d, max_carriages: %d, locked Slots: %d, #surface_connections: %d', count, stop.providing_threshold, req_count, item, stop.entity.backer_name, from_network_id_string, stop.provider_priority, activeDeliveryCount, stop.min_carriages, stop.max_carriages, stop.locked_slots, surface_connections_count))
                        end

                        table.insert(stations, {
                            entity = stop.entity,
                            network_id = matched_networks,
                            priority = stop.provider_priority,
                            activeDeliveryCount = activeDeliveryCount,
                            item = item,
                            count = count,
                            providing_threshold = stop.providing_threshold,
                            providing_threshold_stacks = stop.providing_threshold_stacks,
                            min_carriages = stop.min_carriages,
                            max_carriages = stop.max_carriages,
                            locked_slots = stop.locked_slots,
                            surface_connections = surface_connections,
                            surface_connections_count = surface_connections_count,
                        })
                    end
                end
            end
        end
    end

    -- sort best matching station to the top
    table.sort(stations, function(a, b)
        if a.priority ~= b.priority then                                       --sort by priority, will result in train queues if trainlimit is not set
            return a.priority > b.priority
        elseif a.surface_connections_count ~= b.surface_connections_count then --sort providers without surface transition to top
            return math.min(a.surface_connections_count, 1) < math.min(b.surface_connections_count, 1)
        elseif a.activeDeliveryCount ~= b.activeDeliveryCount then             --sort by #deliveries
            return a.activeDeliveryCount < b.activeDeliveryCount
        else
            return a.count > b.count --finally sort by item count
        end
    end)

    if debug_log then log(string.format('(getProviders) sorted providers: %s', serpent.block(stations))) end

    return stations
end

---@param stationA LuaEntity
---@param stationB LuaEntity
---@return number
local function getStationDistance(stationA, stationB)
    local stationPair = stationA.unit_number .. ',' .. stationB.unit_number
    if storage.StopDistances[stationPair] then
        --log(stationPair.." found, distance: "..storage.StopDistances[stationPair])
        return storage.StopDistances[stationPair]
    else
        local dist = tools.getDistance(stationA.position, stationB.position)
        storage.StopDistances[stationPair] = dist
        --log(stationPair.." calculated, distance: "..dist)
        return dist
    end
end

--- returns: available trains in depots or nil
---          filtered by NetworkID, carriages and surface
---          sorted by priority, capacity - locked slots and distance to provider
---@param nextStop ltn.Provider
---@param min_carriages number
---@param max_carriages number
---@param type string
---@param size number
---@return ltn.FreeTrain[]?
local function getFreeTrains(nextStop, min_carriages, max_carriages, type, size)
    local dispatcher = tools.getDispatcher()

    ---@type ltn.FreeTrain[]
    local filtered_trains = {}

    for trainID, trainData in pairs(dispatcher.availableTrains) do
        if trainData.train.valid and trainData.train.station and trainData.train.station.valid then
            local inventorySize
            if type == 'item' then
                -- subtract locked slots from every cargo wagon
                inventorySize = trainData.capacity - (nextStop.locked_slots * #trainData.train.cargo_wagons)
            else
                inventorySize = trainData.fluid_capacity
            end

            if debug_log then
                local depot_network_id_string = string.format('0x%x', bit32.band(trainData.network_id))
                local dest_network_id_string = string.format('0x%x', bit32.band(nextStop.network_id))

                log(string.format('(getFreeTrain) checking train %s, force %s/%s, network %s/%s, priority: %d, length: %d<=%d<=%d, inventory size: %d/%d, distance: %d', tools.getTrainName(trainData.train), trainData.force.name, nextStop.entity.force.name, depot_network_id_string, dest_network_id_string, trainData.depot_priority, min_carriages, #trainData.train.carriages, max_carriages, inventorySize, size, getStationDistance(trainData.train.station, nextStop.entity)))
            end

            if inventorySize > 0                                                                                                                                -- sending trains without inventory on deliveries would be pointless
                and trainData.force == nextStop.entity.force                                                                                                    -- forces match
                and trainData.surface == nextStop.entity.surface                                                                                                -- pathing between surfaces is impossible
                and bit32.btest(trainData.network_id, nextStop.network_id)                                                                                      -- depot is in the same network as requester and provider
                and (min_carriages == 0 or #trainData.train.carriages >= min_carriages) and (max_carriages == 0 or #trainData.train.carriages <= max_carriages) -- train length fits requester and provider limitations
            then
                local distance = getStationDistance(trainData.train.station, nextStop.entity)
                table.insert(filtered_trains, {
                    train = trainData.train,
                    inventory_size = inventorySize,
                    depot_priority = trainData.depot_priority,
                    provider_distance = distance,
                })
            end
        else
            -- remove invalid train from dispatcher availableTrains
            dispatcher.availableTrains_total_capacity = dispatcher.availableTrains_total_capacity - dispatcher.availableTrains[trainID].capacity
            dispatcher.availableTrains_total_fluid_capacity = dispatcher.availableTrains_total_fluid_capacity - dispatcher.availableTrains[trainID].fluid_capacity
            dispatcher.availableTrains[trainID] = nil
        end
    end

    -- return nil instead of empty table
    if next(filtered_trains) == nil then return nil end

    -- sort best matching train to top
    table.sort(filtered_trains, function(a, b)
        if a.depot_priority ~= b.depot_priority then
            --sort by priority
            return a.depot_priority > b.depot_priority
        elseif a.inventory_size ~= b.inventory_size and a.inventory_size >= size then
            --sort inventories capable of whole deliveries
            -- return not(b.inventory_size => size and a.inventory_size > b.inventory_size)
            return b.inventory_size < size or a.inventory_size < b.inventory_size
        elseif a.inventory_size ~= b.inventory_size and a.inventory_size < size then
            --sort inventories for partial deliveries
            -- return not(b.inventory_size >= size or b.inventory_size > a.inventory_size)
            return b.inventory_size < size and b.inventory_size < a.inventory_size
        else
            -- sort by distance to provider
            return a.provider_distance < b.provider_distance
        end
    end)

    if debug_log then log(string.format('(getFreeTrain) sorted trains: %s', serpent.block(filtered_trains))) end

    return filtered_trains
end

-- parse single request from dispatcher Request={stopID, item, age, count}
-- returns created delivery ID or nil
---@param reqIndex number
---@param request ltn.Request
---@return number?
function ProcessRequest(reqIndex, request)
    local dispatcher = tools.getDispatcher()

    -- ensure validity of request stop
    local toID = request.stopID
    local requestStation = storage.LogisticTrainStops[toID]

    if not requestStation or not (requestStation.entity and requestStation.entity.valid) then
        return nil
    end

    local surface_name = requestStation.entity.surface.name
    local to = requestStation.entity.backer_name
    local to_rail = requestStation.entity.connected_rail
    local to_rail_direction = requestStation.entity.connected_rail_direction
    local to_gps = tools.richTextForStop(requestStation.entity) or to
    local to_network_id_string = string.format('0x%x', bit32.band(requestStation.network_id))
    local item = request.item
    local count = request.count

    local max_carriages = requestStation.max_carriages
    local min_carriages = requestStation.min_carriages
    local requestForce = requestStation.entity.force

    if debug_log then log(string.format('request %d/%d: %d(%d) %s to %s {%s} priority: %d min length: %d max length: %d', reqIndex, #dispatcher.Requests, count, requestStation.requesting_threshold, item, requestStation.entity.backer_name, to_network_id_string, request.priority, min_carriages, max_carriages)) end

    if not (dispatcher.Requests_by_Stop[toID] and dispatcher.Requests_by_Stop[toID][item]) then
        if debug_log then log(string.format('Skipping request %s: %s. Item has already been processed.', requestStation.entity.backer_name, item)) end
        return nil
    end

    if requestStation.max_trains > 0 and #requestStation.active_deliveries >= requestStation.max_trains then
        if debug_log then log(string.format('%s Request station train limit reached: %d(%d)', requestStation.entity.backer_name, #requestStation.active_deliveries, requestStation.max_trains)) end
        return nil
    end

    -- find providers for requested item
    local item_info = tools.parseItemIdentifier(item)
    if not item_info then
        if message_level >= 1 then tools.printmsg({ 'ltn-message.error-parse-item', item }, requestForce) end
        if debug_log then log(string.format('(ProcessRequests) could not parse %s', item)) end

        return nil
    end

    local localname
    if item_info.type == 'fluid' then
        assert(prototypes.fluid[item_info.name], 'fluid prototype undefined!', item_info)
        localname = prototypes.fluid[item_info.name].localised_name
        -- skip if no trains are available
        if (dispatcher.availableTrains_total_fluid_capacity or 0) == 0 then
            create_alert(requestStation.entity, 'depot-empty', { 'ltn-message.empty-depot-fluid' }, requestForce)

            if message_level >= 1 then tools.printmsg({ 'ltn-message.empty-depot-fluid' }, requestForce) end
            if debug_log then log(string.format('Skipping request %s {%s}: %s. No trains available.', to, to_network_id_string, item)) end

            ---@type ltn.EventData.no_train_found_item
            local data = {
                to = to,
                to_id = toID,
                network_id = requestStation.network_id,
                item = item
            }
            script.raise_event(on_dispatcher_no_train_found_event, data)
            return nil
        end
    else
        assert(prototypes.item[item_info.name], 'item prototype undefined!', item_info)
        localname = prototypes.item[item_info.name].localised_name
        -- skip if no trains are available
        if (dispatcher.availableTrains_total_capacity or 0) == 0 then
            create_alert(requestStation.entity, 'depot-empty', { 'ltn-message.empty-depot-item' }, requestForce)

            if message_level >= 1 then tools.printmsg({ 'ltn-message.empty-depot-item' }, requestForce) end
            if debug_log then log(string.format('Skipping request %s {%s}: %s. No trains available.', to, to_network_id_string, item)) end

            ---@type ltn.EventData.no_train_found_item
            local data = {
                to = to,
                to_id = toID,
                network_id = requestStation.network_id,
                item = item
            }

            script.raise_event(on_dispatcher_no_train_found_event, data)

            return nil
        end
    end

    -- get providers ordered by priority
    local providers = getProviders(requestStation, item, count, min_carriages, max_carriages)
    if not providers or #providers < 1 then
        if requestStation.no_warnings == false and message_level >= 1 then tools.printmsg({ 'ltn-message.no-provider-found', to_gps, tools.prettyPrint(item_info), to_network_id_string }, requestForce) end

        if debug_log then log(string.format('No supply of %s found for Requester %s: surface: %s min length: %s, max length: %s, network-ID: %s', item, to, surface_name, min_carriages, max_carriages, to_network_id_string)) end

        return nil
    end

    local providerData = providers[1] -- only one delivery/request is created so use only the best provider

    local fromID = providerData.entity.unit_number
    assert(fromID)

    local from_rail = providerData.entity.connected_rail
    local from_rail_direction = providerData.entity.connected_rail_direction
    local from = providerData.entity.backer_name
    local from_gps = tools.richTextForStop(providerData.entity) or from
    local matched_network_id_string = string.format('0x%x', bit32.band(providerData.network_id))

    if message_level >= 3 then tools.printmsg({ 'ltn-message.provider-found', from_gps, tostring(providerData.priority), tostring(providerData.activeDeliveryCount), providerData.count, tools.prettyPrint(item_info) }, requestForce) end

    -- limit deliverySize to count at provider
    local deliverySize = count
    if count > providerData.count then
        deliverySize = providerData.count
    end

    local stacks = deliverySize                                              -- for fluids stack = tanker capacity
    if item_info.type == 'item' then
        assert(prototypes.item[item_info.name], 'item prototype undefined!', item_info)
        stacks = math.ceil(deliverySize / prototypes.item[item_info.name].stack_size) -- calculate amount of stacks item count will occupy
    end

    -- max_carriages = shortest set max-train-length
    if providerData.max_carriages > 0 and (providerData.max_carriages < requestStation.max_carriages or requestStation.max_carriages == 0) then
        max_carriages = providerData.max_carriages
    end
    -- min_carriages = longest set min-train-length
    if providerData.min_carriages > 0 and (providerData.min_carriages > requestStation.min_carriages or requestStation.min_carriages == 0) then
        min_carriages = providerData.min_carriages
    end

    dispatcher.Requests_by_Stop[toID][item] = nil -- remove before merge so it's not added twice

    ---@type ltn.ItemLoadingElement[]
    local loadingList = {
        {
            item = item_info,
            localname = localname,
            count = deliverySize,
            stacks = stacks
        }
    }

    local totalStacks = stacks
    if debug_log then log(string.format('created new order %s >> %s: %d %s in %d/%d stacks, min length: %d max length: %d', from, to, deliverySize, item, stacks, totalStacks, min_carriages, max_carriages)) end

    -- find possible mergeable items, fluids can't be merged in a sane way
    if item_info.type == 'item' then
        for merge_item, merge_count_req in pairs(dispatcher.Requests_by_Stop[toID]) do
            local merge_item_info = tools.parseItemIdentifier(merge_item)
            if merge_item_info and merge_item_info.type == 'item' then
                assert(prototypes.item[merge_item_info.name], 'item prototype undefined!', merge_item_info)
                local merge_localname = prototypes.item[merge_item_info.name].localised_name
                -- get current provider for requested item
                if dispatcher.Provided[merge_item] and dispatcher.Provided[merge_item][fromID] then
                    -- set delivery Size and stacks
                    local merge_count_prov = dispatcher.Provided[merge_item][fromID]
                    local merge_deliverySize = merge_count_req
                    if merge_count_req > merge_count_prov then
                        merge_deliverySize = merge_count_prov
                    end
                    local merge_stacks = math.ceil(merge_deliverySize / prototypes.item[merge_item_info.name].stack_size) -- calculate amount of stacks item count will occupy

                    -- add to loading list
                    table.insert(loadingList, {
                        item = merge_item_info,
                        localname = merge_localname,
                        count = merge_deliverySize,
                        stacks = merge_stacks
                    } --[[@as ltn.ItemLoadingElement ]])

                    totalStacks = totalStacks + merge_stacks
                    -- order.totalStacks = order.totalStacks + merge_stacks
                    -- order.loadingList[#order.loadingList+1] = loadingList
                    if debug_log then log(string.format('inserted into order %s >> %s: %d %s in %d/%d stacks.', from, to, merge_deliverySize, merge_item, merge_stacks, totalStacks)) end
                end
            end
        end
    end

    -- find train
    local free_trains = getFreeTrains(providerData, min_carriages, max_carriages, item_info.type, totalStacks)
    if not free_trains then
        create_alert(requestStation.entity, 'depot-empty', { 'ltn-message.no-train-found', from, to, matched_network_id_string, tostring(min_carriages), tostring(max_carriages) }, requestForce)

        if message_level >= 1 then tools.printmsg({ 'ltn-message.no-train-found', from_gps, to_gps, matched_network_id_string, tostring(min_carriages), tostring(max_carriages) }, requestForce) end
        if debug_log then log(string.format('No train with %d <= length <= %d to transport %d stacks from %s to %s in network %s found in Depot.', min_carriages, max_carriages, totalStacks, from, to, matched_network_id_string)) end

        ---@type ltn.EventData.no_train_found_shipment
        local data = {
            to = to,
            to_id = toID,
            from = from,
            from_id = fromID,
            network_id = requestStation.network_id,
            min_carriages = min_carriages,
            max_carriages = max_carriages,
            shipment = tools.createLoadingList(loadingList),
        }

        script.raise_event(on_dispatcher_no_train_found_event, data)

        dispatcher.Requests_by_Stop[toID][item] = count -- add removed item back to list of requested items.
        return nil
    end

    local selectedTrain = free_trains[1].train
    local trainInventorySize = free_trains[1].inventory_size

    if message_level >= 3 then tools.printmsg({ 'ltn-message.train-found', from_gps, to_gps, matched_network_id_string, tostring(trainInventorySize), tostring(totalStacks) }, requestForce) end
    if debug_log then log(string.format('Train to transport %d/%d stacks from %s to %s in network %s found in Depot.', trainInventorySize, totalStacks, from, to, matched_network_id_string)) end

    -- recalculate delivery amount to fit in train
    if trainInventorySize < totalStacks then
        -- recalculate partial shipment
        if item_info.type == 'fluid' then
            -- fluids are simple
            loadingList[1].count = trainInventorySize
        else
            -- items need a bit more math
            for i = #loadingList, 1, -1 do
                if totalStacks - loadingList[i].stacks < trainInventorySize then
                    -- remove stacks until it fits in train
                    loadingList[i].stacks = loadingList[i].stacks - (totalStacks - trainInventorySize)
                    totalStacks = trainInventorySize
                    local newcount = loadingList[i].stacks * prototypes.item[loadingList[i].item.name].stack_size
                    loadingList[i].count = math.min(newcount, loadingList[i].count)
                    break
                else
                    -- remove item and try again
                    totalStacks = totalStacks - loadingList[i].stacks
                    table.remove(loadingList, i)
                end
            end
        end
    end

    -- create delivery
    if message_level >= 2 then
        if #loadingList == 1 then
            tools.printmsg({ 'ltn-message.creating-delivery', from_gps, to_gps, loadingList[1].count, tools.prettyPrint(loadingList[1].item) }, requestForce)
        else
            tools.printmsg({ 'ltn-message.creating-delivery-merged', from_gps, to_gps, totalStacks }, requestForce)
        end
    end

    -- create schedule
    -- local selectedTrain = dispatcher availableTrains[trainID].train
    local depot = storage.LogisticTrainStops[selectedTrain.station.unit_number]

    ---@type TrainSchedule
    local schedule = {
        current = 1,
        records = {
            NewScheduleRecord {
                stationName = depot.entity.backer_name,
                condType = 'inactivity',
                ticks = depot_inactivity,
            }
        }
    }

    -- make train go to specific stations by setting a temporary waypoint on the rail the station is connected to
    -- schedules cannot have temporary stops on a different surface, those need to be added when the delivery is updated with a train on a different surface
    if from_rail and from_rail_direction and depot.entity.surface == from_rail.surface then
        table.insert(schedule.records, NewTempScheduleRecord(from_rail, from_rail_direction))
    else
        if debug_log then log('(ProcessRequest) Warning: creating schedule without temporary stop for provider.') end
    end

    table.insert(schedule.records, NewScheduleRecord {
        stationName = from,
        condType = 'item_count',
        condComp = '≥',
        itemList = loadingList
    })

    if to_rail and to_rail_direction and depot.entity.surface == to_rail.surface and (from_rail and to_rail.surface == from_rail.surface) then
        table.insert(schedule.records, NewTempScheduleRecord(to_rail, to_rail_direction))
    else
        if debug_log then log('(ProcessRequest) Warning: creating schedule without temporary stop for requester.') end
    end

    table.insert(schedule.records, NewScheduleRecord {
        stationName = to,
        condType = 'item_count',
        condComp = '=',
        itemList = loadingList,
        countOverride = 0
    })

    local shipment = {}
    if debug_log then log(string.format('Creating Delivery: %d stacks, %s >> %s', totalStacks, from, to)) end
    for i = 1, #loadingList do
        local loadingListItem = tools.createItemIdentifier(loadingList[i].item)
        -- store Delivery
        shipment[loadingListItem] = loadingList[i].count

        -- subtract Delivery from Provided items and check thresholds
        dispatcher.Provided[loadingListItem][fromID] = dispatcher.Provided[loadingListItem][fromID] - loadingList[i].count
        local new_provided = dispatcher.Provided[loadingListItem][fromID]
        local new_provided_stacks = 0
        local useProvideStackThreshold = false
        if loadingList[i].item.type == 'item' then
            if prototypes.item[loadingList[i].item.name] then
                new_provided_stacks = new_provided / prototypes.item[loadingList[i].item.name].stack_size
            end
            useProvideStackThreshold = providerData.providing_threshold_stacks > 0
        end

        if (useProvideStackThreshold and new_provided_stacks >= providerData.providing_threshold_stacks) or
            (not useProvideStackThreshold and new_provided >= providerData.providing_threshold) then
            dispatcher.Provided[loadingListItem][fromID] = new_provided
            dispatcher.Provided_by_Stop[fromID][loadingListItem] = new_provided
        else
            dispatcher.Provided[loadingListItem][fromID] = nil
            dispatcher.Provided_by_Stop[fromID][loadingListItem] = nil
        end

        -- remove Request and reset age
        dispatcher.Requests_by_Stop[toID][loadingListItem] = nil
        dispatcher.RequestAge[loadingListItem .. ',' .. toID] = nil

        if debug_log then log(string.format('  %s, %d in %d stacks', loadingListItem, loadingList[i].count, loadingList[i].stacks)) end
    end

    table.insert(dispatcher.new_Deliveries, selectedTrain.id)
    dispatcher.Deliveries[selectedTrain.id] = {
        force = requestForce,
        train = selectedTrain,
        from = from,
        from_id = fromID,
        to = to,
        to_id = toID,
        network_id = providerData.network_id,
        started = game.tick,
        surface_connections = providerData.surface_connections,
        shipment = shipment,
    }

    dispatcher.availableTrains_total_capacity = dispatcher.availableTrains_total_capacity - dispatcher.availableTrains[selectedTrain.id].capacity
    dispatcher.availableTrains_total_fluid_capacity = dispatcher.availableTrains_total_fluid_capacity - dispatcher.availableTrains[selectedTrain.id].fluid_capacity
    dispatcher.availableTrains[selectedTrain.id] = nil

    -- raises on_train_schedule_changed instantly
    -- GetNextLogisticStop relies on dispatcher Deliveries[train.id].train to be set
    selectedTrain.schedule = schedule
    -- dispatcher Deliveries[selectedTrain.id].train = selectedTrain -- not required, train object is stored as reference

    -- train is no longer available => set depot to yellow
    setLamp(depot, 'yellow', 1)

    -- update delivery count and lamps on provider and requester
    for _, stopID in pairs { fromID, toID } do
        local stop = storage.LogisticTrainStops[stopID]
        assert(stop)
        if stop.entity.valid and (stop.entity.unit_number == fromID or stop.entity.unit_number == toID) then
            table.insert(stop.active_deliveries, selectedTrain.id)

            local lamp_control = stop.lamp_control.get_or_create_control_behavior() --[[@as LuaConstantCombinatorControlBehavior ]]
            assert(lamp_control)

            if lamp_control.sections_count == 0 then
                assert(lamp_control.add_section())
            end

            local section = lamp_control.sections[1]
            assert(section)
            assert(section.filters_count == 1)

            -- only update blue signal count; change to yellow if it wasn't blue
            local current_signal = section.filters[1]
            if current_signal and current_signal.value.name == 'signal-blue' then
                setLamp(stop, 'blue', #stop.active_deliveries)
            else
                setLamp(stop, 'yellow', #stop.active_deliveries)
            end
        end
    end

    return selectedTrain.id -- deliveries are indexed by train.id
end
