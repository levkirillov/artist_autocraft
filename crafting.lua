-- Load JSON library (assuming you're using a JSON parsing library like dkjson or cjson)
local class = require "artist.lib.class"
local Crafting = class "artist.custom.crafting" --- @type Crafting

local json = require 'json'
local have_enough
local log
local load_crafting_status
local count_active_custom_crafts_for_devices
local save_crafting_status
local do_craft
local pretty = require "cc.pretty"
local items
local get_amount

local file = io.open("crafting_status.json", "w")
file:write("{}")
file:close()
local file = io.open("log.txt", "w")
file:write("")
file:close()

-- Load the recipes from the file
local function load_recipes()
    local file = io.open("recipes.json", "r")
    if file then
        local content = file:read("*a")
        file:close()
        return json.decode(content)
    else
        return {}
    end
end

function count_active_custom_crafts_for_devices(devices)
    local crafting_status = load_crafting_status()
    local active_crafts = 0

    -- Count how many processes are using the same custom devices
    for _, process in ipairs(crafting_status) do
        if process.recipe.devices then
            for device, _ in pairs(devices) do
                if process.recipe.devices[device] and process.status == "in_progress" then
                    active_crafts = active_crafts + 1
                end
            end
        end
    end

    return active_crafts
end

-- Function to count how many processes are using the same input chest (or devices)
local function count_active_crafts_for_input(input_c)
    local crafting_status = load_crafting_status()
    local active_crafts = 0

    -- Count how many processes are using the same input chest
    for _, process in ipairs(crafting_status) do
        if process.recipe.input_c == input_c and process.status == "in_progress" then
            active_crafts = active_crafts + 1
        end
    end

    return active_crafts
end

-- Function to check if custom crafting is busy, now considering multi_craft and multi_limit
local function is_crafting_busy(recipe)
    local crafting_status = load_crafting_status()
    if not crafting_status or not crafting_status.recipe then
        return false
    end
    
    -- If multi_craft is enabled, check the limit for both input chest and devices
    if recipe.multi_craft then
        -- Check for chest-based multi-crafting (input_c)
        local active_crafts_input = count_active_crafts_for_input(recipe.input_c)
        if active_crafts_input >= recipe.multi_limit then
            return true -- Input chest multi-craft limit reached
        end

        -- Check for custom devices multi-crafting
        if recipe.devices then
            local active_crafts_devices = count_active_custom_crafts_for_devices(recipe.devices)
            if active_crafts_devices >= recipe.multi_limit then
                return true -- Devices multi-craft limit reached
            end
        end

        -- Check if devices are being used for other recipes
        for device, _ in pairs(recipe.devices) do
            for _, process in ipairs(crafting_status) do
                if process.recipe.devices and process.recipe.devices[device] and process.status == "in_progress" and process.recipe.name ~= recipe.name then
                    return true -- Device is in use by another crafting process with a different recipe
                end
            end
        end
    else
        -- Non-multi-craft: Check if input chest is in use
        for _, process in ipairs(crafting_status) do
            if process.recipe.input_c == recipe.input_c and process.status == "in_progress" then
                return true -- Input chest is already in use
            end
        end

        -- Check if custom devices are in use
        if recipe.devices then
            for device, _ in pairs(recipe.devices) do
                for _, process in ipairs(crafting_status) do
                    if process.recipe.devices and process.recipe.devices[device] and process.status == "in_progress" then
                        return true -- Device is in use by another crafting process
                    end
                end
            end
        end
    end

    return false -- No busy process found
end


function not_enough(missing_items)
    for _, item in ipairs(missing_items) do
        local missing_item = type(item[1]) == "table" and item[1].tags[1] or item[1]
        log("not enough  "..missing_item)
    end
end

-- Save the crafting process to a file (ensure it's always an array)
function save_crafting_status(status)
    -- Ensure that 'status' is always a list (array)
    if type(status) ~= "table" or status[1] == nil then
        if status[1] == nil then
            status = {}
        else
            status = {status}  -- Wrap single object in array if it's not already
        end
    end

    local file = io.open("crafting_status.json", "w")

    file:write(json.encode(status))  -- Save as JSON array
    file:close()
end


-- Load the crafting process from a file
function load_crafting_status()
    local file = io.open("crafting_status.json", "r")
    if file then
        local content = file:read("*a")
        file:close()
        local status = json.decode(content)
        -- Ensure it is an array, not nested tables
        return type(status) == "table" and status or {}
    else
        return {}  -- No active crafting processes
    end
end


function log_status()
    local crafting_status = load_crafting_status()
    log("Current crafting status: " .. json.encode(crafting_status))
end

-- Define tag groups (can also be loaded from a file)
tags = {
    ['minecraft:logs'] = {'minecraft:oak_log', 'minecraft:birch_log'}
}

-- Function that checks if the given item or tag is available in sufficient quantity
function has_enough_item_or_tag(item_or_tag, count)
    if type(item_or_tag) == "table" and item_or_tag.tags then
        log("check")
        -- Check for each item in the tag
        for _, tag in ipairs(item_or_tag.tags) do
            log("pairs")
            log(tag)
            if type(tag) == "string" then
                if have_enough(tag, count) then
                    log("true")
                    return true
                end
            end
            for _, tag_item in ipairs(tags[tag] or {}) do
                if have_enough(tag_item, count) then
                    log("true")
                    return true
                end
            end
        end
    else
        -- Direct check for the item itself
        return have_enough(item_or_tag, count)
    end
    return false
end

-- Function to gather missing ingredients from the crafting scheme
function get_missing_from_scheme(scheme)
    local missing_items = {}

    for row = 1, #scheme do
        for col = 1, #scheme[row] do
            local item = scheme[row][col]
            if item ~= "" then  -- Ignore empty slots
                if not has_enough_item_or_tag(item, 1) then
                    table.insert(missing_items, {item, 1})
                end
            end
        end
    end

    return missing_items
end

-- Function to craft an item based on the type of recipe (crafting, custom)
function craft(item)
    local recipes = load_recipes()
    
    -- Check all types of recipes (crafting, custom) for the item
    local recipe_found = false

    -- Check if the item is a crafting recipe
    for _, recipe in pairs(recipes.crafting) do
        if recipe.result == item then
            craft_crafting_recipe(recipe)
            recipe_found = true
            break  -- Exit loop after crafting
        end
    end
    
    if not recipe_found then
        -- Check if the item is a custom device recipe
        for _, recipe in pairs(recipes.custom) do
            if recipe.result == item then
                craft_custom_recipe(recipe)
                recipe_found = true
                break  -- Exit loop after crafting
            end
        end
    end

    -- If no recipe found, item cannot be crafted
    if not recipe_found then
        not_enough({item})
    end
end

-- Function to handle crafting recipes
function craft_crafting_recipe(recipe)
    local scheme = recipe['scheme']
    local input_container = recipe['input_c']
    local output_container = recipe['output_c']

    -- Check if all materials are available
    local missing_items = get_missing_from_scheme(scheme)
    if #missing_items > 0 then
        not_enough(missing_items)
        return
    end

    -- If all materials are present, call do_craft with the crafting details
    local craft_status = do_craft(recipe, scheme, input_container, output_container)
    if craft_status == "busy" then
        table.insert(crafting_status, {
            recipe = recipe,
            type = "crafting",
            status = "busy",
            amount = tostring(get_amount(recipe.result)),
        })
    else 
        table.insert(crafting_status, {
            recipe = recipe,
            type = "crafting",
            status = "in_progress",
            amount = tostring(get_amount(recipe.result)),
        })
    end
    save_crafting_status(crafting_status)
end

-- Function to handle custom device recipes
function craft_custom_recipe(recipe)
    
    for device, inputs in pairs(recipe.devices) do
        for slot, input in pairs(inputs) do
            local item = input[1]
            log("item "..pretty.pretty(item))
            if item ~= "output" then
                local count = input[2].count
                log(pretty.pretty(item.tags))
                local old = item
                if item.tags then
                    item = item.tags
                else 
                end
                log(type(item))
                if not has_enough_item_or_tag(old, count) then
                    log("1")
                    not_enough({{old, count}})
                    return
                end
            end
        end
    end

    -- Custom device crafting process would be triggered here
    local crafting_status = load_crafting_status()
    local craft_status = do_craft(recipe, nil, nil, recipe.output_c)
    log("status")
    log(craft_status)
    if craft_status == "busy" then
        table.insert(crafting_status, {
            recipe = recipe,
            type = "custom",
            status = "busy",
            amount = tostring(get_amount(recipe.result)),
        })
    else 
        table.insert(crafting_status, {
            recipe = recipe,
            type = "custom",
            status = "in_progress",
            amount = tostring(get_amount(recipe.result)),
        })
    end
    save_crafting_status(crafting_status)
end

-- Periodic function to check crafting progress and retry "busy" items
function check_crafting_status()
    log('reload')
    local crafting_status = load_crafting_status()
    local updated_status = {}
    for _, process in ipairs(crafting_status) do
        local recipe = process.recipe
        if recipe then
            local output_container = recipe.output_c
            local result = recipe.result
            if recipe.devices then
                log('recipe.devices')
                log(pretty.pretty(recipe.devices))
                for dev, slots in pairs(recipe.devices) do
                    log('dev')
                    log(pretty.pretty(dev))
                    log(pretty.pretty(slots))
                    for slot, data in pairs(slots) do
                        log(data[1])
                        if data[1] == "output" then
                            log("insert now")
                            items:insert(dev, tonumber(slot), 64)
                        end
                    end
                end
            end
            -- Check if the output container has the crafted items
            if have_enough(result, recipe.count+tonumber(process.amount)) then
                process.status = "completed"
                log("crafting for item "..result.." done")
            else
                -- Retry crafting if necessary
                if process.status == "busy" then
                    local craft_status = do_craft(recipe, nil, nil, output_container)
                    if craft_status == "busy" then
                        table.insert(updated_status, process)  -- Retry in the next cycle
                    elseif craft_status == "" then
                    else
                        process.status = craft_status
                        table.insert(updated_status, process)  -- Keep in progress
                    end
                elseif process.status == "in_progress" then
                    table.insert(updated_status, process)
                end
            end
        end
    end

    -- Save the updated crafting status
    save_crafting_status(updated_status)
end

function log(text)
    local file = io.open("log.txt", "a")  -- Open in append mode
    file:write(tostring(text) .. "\n")    -- Add a newline after each log entry
    file:close()
end



return function(context)
    items = context:require "artist.core.items"

    -- have_enough function
    function have_enough(item_name, count)
        log("Checking availability for item: " .. item_name)
        local total_count = 0

        for _, inventory in pairs(items.inventories) do
            for _, slot in pairs(inventory.slots or {}) do
                local item = items.item_cache[slot.hash]
                if item and item.details.name == item_name then
                    total_count = total_count + slot.count
                end
            end
        end

        log("Total count of " .. item_name .. ": " .. total_count)
        return total_count >= count
    end

    function get_amount(item_name)
        log("Getting amount of item: " .. item_name)
        local total_count = 0

        for _, inventory in pairs(items.inventories) do
            for _, slot in pairs(inventory.slots or {}) do
                local item = items.item_cache[slot.hash]
                if item and item.details.name == item_name then
                    total_count = total_count + slot.count
                end
            end
        end

        log("Total count of " .. item_name .. ": " .. total_count)
        return total_count
    end

    -- do_craft function
    function do_craft(recipe)
        if is_crafting_busy(recipe) then
            if not recipe.input_c then
                log("Crafting is busy for input chest " .. (function() for key, _ in pairs(recipe.devices) do return key end end)() .. " or a device.")
            else
                log("Crafting is busy for input chest " .. recipe.input_c .. " or a device.")
            end
            return "busy"
        end

        if recipe.multi_craft then
            local active_crafts_input = count_active_crafts_for_input(recipe.input_c)
            if active_crafts_input >= recipe.multi_limit then
                log("Input chest crafting limit reached for " .. recipe.result .. ": " .. active_crafts_input .. "/" .. recipe.multi_limit)
                return "busy"
            end

            if recipe.devices then
                local active_crafts_devices = count_active_custom_crafts_for_devices(recipe.devices)
                if active_crafts_devices >= recipe.multi_limit then
                    log("Device crafting limit reached for " .. recipe.result .. ": " .. active_crafts_devices .. "/" .. recipe.multi_limit)
                    return "busy"
                end
            end
        else
            local active_crafts_input = count_active_crafts_for_input(recipe.input_c)
            if active_crafts_input >= 1 then
                log("Input chest crafting limit reached for " .. recipe.result .. ": " .. active_crafts_input .. "/" .. 1)
                return "busy"
            end

            if recipe.devices then
                local active_crafts_devices = count_active_custom_crafts_for_devices(recipe.devices)
                if active_crafts_devices >= 1 then
                    log("Device crafting limit reached for " .. recipe.result .. ": " .. active_crafts_devices .. "/" .. 1)
                    return "busy"
                end
            end
        end

        log("Starting crafting for " .. recipe.result)
        if recipe.scheme ~= nil then
            local num = 0
            for _, row in ipairs(recipe.scheme) do
                for _, item in ipairs(row) do
                    num = num + 1
                    if item ~= "" then
                        if type(item) == "table" then
                            local c = item.count or 1
                            local use
                            for _, name in ipairs(item.tags) do
                                if have_enough(name, c) then
                                    use = name
                                end
                            end
                            local cache
                            for _, val in pairs(items.item_cache) do
                                if val.hash == use then
                                    cache = val
                                end
                            end
                            local status, result = pcall(function()
                                items:extract(recipe.input_c, cache.hash, c, num)
                            end)
                            if not status then return '' end
                        else
                            local name = item
                            local c = 1
                            if have_enough(name, c) then
                                local cache
                                for _, val in pairs(items.item_cache) do
                                    if val.hash == name then
                                        cache = val
                                    end
                                end
                                local status, result = pcall(function()
                                    items:extract(recipe.input_c, cache.hash, c, num)
                                end)
                                if not status then return '' end
                            end
                        end
                    end
                end
            end
        elseif recipe.devices ~= nil then
            log("dev rec "..pretty.pretty(recipe))
            for device, ins in pairs(recipe.devices) do
                for slot,item in pairs(ins) do
                    if item[1] ~= "output" then
                        if not item[1].tags then
                            log("non tags")
                            local c = item[2].count or 1
                            if have_enough(item[1], c) then
                                local cache
                                for _, val in pairs(items.item_cache) do
                                    if val.hash == item[1] then
                                        cache = val
                                    end
                                end
                                items:extract(device, cache.hash, c, tonumber(slot))
                            end
                        else
                            log("tags")
                            local use
                            local c = item[2].count or 1
                            for _, name in ipairs(item[1].tags) do
                                if have_enough(name, c) then
                                    use = name
                                end
                            end
                            local cache
                            for _, val in pairs(items.item_cache) do
                                if val.hash == use then
                                    cache = val
                                end
                            end
                            items:extract(device, cache.hash, c, tonumber(slot))
                        end
                    end
                end
            end
            --
        end
        return "in_progress"
    end
    --save_crafting_status({})
    local next_reload = nil
    local function queue_reload()
        if next_reload then return end
        next_reload = os.startTimer(0.2)
    end
    local function update_dropoff_pl(item)
        local crafting_status = load_crafting_status()
        for _, process in ipairs(crafting_status) do
            if process.recipe.result == item.name then
                process.amount = process.amount + item.count
            end
        end
        save_crafting_status(crafting_status)
    end
    local function update_dropoff_mn(item)
        local crafting_status = load_crafting_status()
        for _, process in ipairs(crafting_status) do
            if process.recipe.result == item.name then
                process.amount = process.amount - item.count
            end
        end
        save_crafting_status(crafting_status)
    end
    context.mediator:subscribe("items.inventories_change", queue_reload)
    context.mediator:subscribe("items.change", queue_reload)
    context.mediator:subscribe("dropoff.add", update_dropoff_pl)
    context.mediator:subscribe("pickup.take", update_dropoff_mn)
    Crafting.craft = craft
    context:spawn(function()
        os.sleep(2)
        while true do
            os.sleep(2)
            check_crafting_status()
        end
    end)
    return Crafting
end

