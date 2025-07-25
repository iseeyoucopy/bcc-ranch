-- Creation and checking if in ranch area --
RanchersOnline = {} -- This will be used to store the ranchers who are online of each ranch so we can sync changes firing etc to all online players of the ranch (It will store the playersSource and remove it if they leave (done by checking if they are online using getplayerped(plrysrc) native))

local function checkOnlineRanchers(ranchId)
    devPrint("Checking online ranchers for ranchId: " .. ranchId)
    if RanchersOnline[ranchId] then
        --devPrint("Current RanchersOnline: " .. json.encode(RanchersOnline[ranchId]))
        for k, v in pairs(RanchersOnline[ranchId]) do
            --devPrint("Checking rancher source: " .. tostring(v.rancherSource))
            if not GetPlayerPed(v.rancherSource) then
                --devPrint("Rancher with source " .. v.rancherSource .. " is offline. Removing from RanchersOnline.")
                if v.doesRancherHaveAnimalsOut then
                    MySQL.update.await("UPDATE bcc_ranch SET is_any_animals_out = 'false' WHERE ranchid = ?", { ranchId })
                end
                table.remove(RanchersOnline[ranchId], k)
            end
        end
    else
        devPrint("No RanchersOnline entry for ranchId: " .. ranchId)
    end
end

function newRancherOnline(sourceToInput, ranchId)
    --devPrint("Adding new rancher with source: " .. sourceToInput .. " to ranchId: " .. ranchId)
    if not RanchersOnline[ranchId] then
        RanchersOnline[ranchId] = {}
    end
    --devPrint("Current RanchersOnline before adding: " .. json.encode(RanchersOnline[ranchId]))
    if #RanchersOnline[ranchId] > 0 then
        local alreadyExists = false
        for k, v in pairs(RanchersOnline[ranchId]) do
            if sourceToInput == v.rancherSource then
                alreadyExists = true
                --devPrint("Rancher source already exists: " .. tostring(sourceToInput))
                break
            end
        end
        if not alreadyExists then
            table.insert(RanchersOnline[ranchId], { rancherSource = sourceToInput, isRancherAging = false, doesRancherHaveAnimalsOut = false })
            --devPrint("Added rancher source: " .. tostring(sourceToInput))
        end
    else
        table.insert(RanchersOnline[ranchId], { rancherSource = sourceToInput, isRancherAging = false })
        --devPrint("First rancher added for ranchId: " .. ranchId)
    end
    --devPrint("Updated RanchersOnline: " .. json.encode(RanchersOnline[ranchId]))
end

function UpdateAllRanchersRanchData(ranchId)
    devPrint("Updating ranch data for ranchId: " .. ranchId)

    checkOnlineRanchers(ranchId)

    local ranchData = MySQL.query.await("SELECT * FROM bcc_ranch WHERE ranchid = ?", { ranchId })
    if not ranchData or #ranchData == 0 or not ranchData[1].ranchcoords then
        devPrint("Invalid ranch data for ranchId: " .. ranchId)
        return
    end

    if not RanchersOnline[ranchId] or #RanchersOnline[ranchId] == 0 then
        devPrint("No ranchers online for ranchId: " .. ranchId)
        return
    end

    for index, rancher in ipairs(RanchersOnline[ranchId]) do
        local isSpawner = (index == 1)
        BccUtils.RPC:Notify("bcc-ranch:UpdateRanchData", { ranch = ranchData[1], isSpawner = isSpawner }, rancher.rancherSource)
    end
end

BccUtils.RPC:Register("bcc-ranch:GetAnimalCondition", function(params, cb)
    local ranchId = params.ranchId
    local animalType = params.animalType
    local conditionQuery = ""
    local maxCondition = 0  -- Default max condition value
    -- Define the query based on the animal type and get the max condition from Config
    if animalType == 'cows' then
        conditionQuery = "SELECT cows_cond FROM bcc_ranch WHERE ranchid = ?"
        maxCondition = ConfigAnimals.animalSetup.cows.maxCondition  -- Get max condition from config
    elseif animalType == 'chickens' then
        conditionQuery = "SELECT chickens_cond FROM bcc_ranch WHERE ranchid = ?"
        maxCondition = ConfigAnimals.animalSetup.chickens.maxCondition
    elseif animalType == 'pigs' then
        conditionQuery = "SELECT pigs_cond FROM bcc_ranch WHERE ranchid = ?"
        maxCondition = ConfigAnimals.animalSetup.pigs.maxCondition
    elseif animalType == 'sheeps' then
        conditionQuery = "SELECT sheeps_cond FROM bcc_ranch WHERE ranchid = ?"
        maxCondition = ConfigAnimals.animalSetup.sheeps.maxCondition
    elseif animalType == 'goats' then
        conditionQuery = "SELECT goats_cond FROM bcc_ranch WHERE ranchid = ?"
        maxCondition = ConfigAnimals.animalSetup.goats.maxCondition
    else
        devPrint("Error: Invalid animal type provided: " .. tostring(animalType))
        cb(nil)  -- Return nil to indicate an error
        return
    end
    -- Query the database for the animal's current condition
    MySQL.scalar(conditionQuery, { ranchId }, function(condition)
        if condition then
            -- Check if the animal's condition is at its max
            if condition >= maxCondition then
                devPrint(animalType .. " condition is at max (" .. maxCondition .. ")")
            end
            -- Return the condition to the client
            cb(condition)
        else
            devPrint("Error: Failed to fetch animal condition for " .. animalType)
            cb(nil)  -- Return nil to indicate an error
        end
    end)
end)

BccUtils.RPC:Register("bcc-ranch:GetRanchDataById", function(params, cb)
    local ranchId = params.ranchId
    local result = MySQL.query.await("SELECT * FROM bcc_ranch WHERE ranchid = ?", { ranchId })

    if result and #result > 0 then
        cb(result[1])
    else
        cb(nil)
    end
end)

BccUtils.RPC:Register("bcc-ranch:CreateRanch", function(params, cb, source)
    devPrint("Received Ranch Params: " .. json.encode(params))

    local ranchName = params.ranchName
    local ranchRadius = params.ranchRadius
    local ranchTaxAmount = params.ranchTaxAmount
    local ownerCharId = params.ownerCharId
    local ownerSource = params.ownerSource
    local coords = params.coords

    -- Retrieve character data for creator and owner
    local creatorChar = VORPcore.getUser(source).getUsedCharacter
    local ownerChar = VORPcore.getUser(ownerSource).getUsedCharacter
    if not creatorChar or not ownerChar then
        NotifyClient(source, _U("invalidPlayer"), "error", 4000)
        return cb(false)
    end

    -- Validate inputs
    if not ranchName or ranchName == "" or not ranchRadius or ranchRadius == "" or not ranchTaxAmount or ranchTaxAmount == "" then
        return cb(false)
    end

    -- Check if the owner already owns a ranch
    local ownerHasRanch = MySQL.query.await("SELECT 1 FROM bcc_ranch WHERE charidentifier = ?", { ownerCharId })
    if #ownerHasRanch > 0 then
        NotifyClient(source, _U("alreadyOwnsRanch"), "error", 4000)
        return cb(false)
    end

    -- Check for duplicate ranch names
    local ranchNameExists = MySQL.query.await("SELECT 1 FROM bcc_ranch WHERE ranchname = ?", { ranchName })
    if #ranchNameExists > 0 then
        NotifyClient(source, _U("ranchNameAlreadyExists"), "error", 4000)
        return cb(false)
    end

    -- Insert the ranch into database
    local insertSuccess = MySQL.insert.await("INSERT INTO bcc_ranch (ranchname, charidentifier, taxamount, ranch_radius_limit, ranchcoords) VALUES (?, ?, ?, ?, ?)", {
        ranchName, ownerCharId, ranchTaxAmount, ranchRadius, json.encode(coords)
    })

    if not insertSuccess then
        NotifyClient(source, _U("databaseError"), "error", 4000)
        return cb(false)
    end

    -- Retrieve newly inserted ranch
    local insertedRanch = MySQL.query.await("SELECT * FROM bcc_ranch WHERE ranchname = ? AND charidentifier = ?", { ranchName, ownerCharId })
    if not insertedRanch or #insertedRanch == 0 then
        NotifyClient(source, _U("databaseError"), "error", 4000)
        return cb(false)
    end

    local ranch = insertedRanch[1]
    MySQL.update.await("UPDATE characters SET ranchid = ? WHERE charidentifier = ?", { ranch.ranchid, ownerCharId })

    -- Send updated ranch info to the owner
    TriggerClientEvent("bcc-ranch:PlayerOwnsARanch", ownerSource, ranch, true)
    TriggerClientEvent("bcc-ranch:PlayerIsAEmployee", ownerSource, ranch, true)

    -- Log the ranch creation to Discord
    BccUtils.Discord.sendMessage(Config.Webhook,
        Config.WebhookTitle,
        Config.WebhookAvatar,
        "🌾 Ranch Created",
        nil,
        {
            {
                color = 5763719, -- Blue-green
                title = "✅ Ranch Created",
                description = table.concat({
                    "**Ranch Name:** `" .. ranchName .. "`",
                    "**Ranch ID:** `" .. tostring(ranch.ranchid) .. "`",
                    "**Owner ID:** `" .. ownerCharId .. "`",
                    "**Owner Name:** `" .. (ownerChar.firstname or "Unknown") .. " " .. (ownerChar.lastname or "Unknown") .. "`",
                    "**Created By:** `" .. (creatorChar.firstname or "Unknown") .. " " .. (creatorChar.lastname or "Unknown") .. "`"
                }, "\n")
            }
        }
    )
    cb(true)
end)

-- Server-side handler for checking if a player owns a ranch
BccUtils.RPC:Register("bcc-ranch:CheckIfPlayerOwnsARanch", function(params, cb, recSource)
    local _source = recSource
    devPrint("Checking if player owns a ranch for source: " .. _source)

    -- Get the user's character data
    local character = VORPcore.getUser(_source).getUsedCharacter
    if not character then
        devPrint("No character found for source: " .. _source)
        return cb(false)
    end
    
    --devPrint("Character ID: " .. character.charIdentifier)

    -- Query to check if player owns a ranch
    local result = MySQL.query.await("SELECT * FROM bcc_ranch WHERE charidentifier = ?", { character.charIdentifier })

    -- If ranch data is found, proceed
    if #result > 0 then
        devPrint("Player owns a ranch. Ranch data: " .. result[1].ranchname)
        -- Register the ranch inventory
        local data = {
            id = 'Player_' .. result[1].ranchid .. '_bcc-ranchinv',
            name = _U("inventoryName"),
            limit = ConfigRanch.ranchSetup.ranchInvLimit,
            acceptWeapons = true,
            shared = true,
            ignoreItemStackLimit = true,
            whitelistItems = false,
            UsePermissions = false,
            UseBlackList = false,
            whitelistWeapons = false
        }

        -- Register ranch inventory
        exports.vorp_inventory:registerInventory(data)

        -- Update online ranchers
        if not RanchersOnline[result[1].ranchid] then
            RanchersOnline[result[1].ranchid] = {}
        end

        -- Check if the player is already in the list
        if not table.contains(RanchersOnline[result[1].ranchid], _source) then
            newRancherOnline(_source, result[1].ranchid)
        end
        -- Send ranch data to the client
        cb(true, result[1])
    else
        devPrint("Player does not own a ranch.")
        cb(false)  -- If no ranch is found, return false
    end
end)

-- Helper function to check if a table contains a value
function table.contains(table, element)
    for _, value in pairs(table) do
        if value == element then
            return true
        end
    end
    return false
end

BccUtils.RPC:Register('bcc-ranch:AffectLedger', function(params, cb, source)
    local _source = source
    local ranchId = params.ranchId
    local type = params.type
    local amount = tonumber(params.amount)
    devPrint("Affecting ledger for ranchId: " .. ranchId .. " with type: " .. type .. " and amount: " .. amount)
    -- Retrieve character and ranch data
    local character = VORPcore.getUser(_source).getUsedCharacter
    local ranch = MySQL.query.await("SELECT * FROM bcc_ranch WHERE ranchid = ?", { ranchId })
    -- Check if ranch exists
    if #ranch > 0 then
        if type == "withdraw" then
            -- Handle withdrawal
            if amount <= tonumber(ranch[1].ledger) then
                MySQL.update.await("UPDATE bcc_ranch SET ledger = ledger - ? WHERE ranchid = ?", { amount, ranchId })
                character.addCurrency(0, amount)
                NotifyClient(_source, _U("withdrewFromLedger") .. " " .. amount, "success", 4000)
                UpdateAllRanchersRanchData(ranchId)
                cb(true)
            else
                NotifyClient(_source, _U("notEnoughMoney"), "error", 4000)
                cb(false)
            end
        elseif type == "deposit" then
            -- Handle deposit
            if tonumber(character.money) >= amount then
                MySQL.update.await("UPDATE bcc_ranch SET ledger = ledger + ? WHERE ranchid = ?", { amount, ranchId })
                character.removeCurrency(0, amount)
                NotifyClient(_source, _U("depositedToLedger") .. " " .. amount, "success", 4000)
                UpdateAllRanchersRanchData(ranchId)
                cb(true)
            else
                NotifyClient(_source, _U("notEnoughMoney"), "error", 4000)
                cb(false)
            end
        end
    else
        NotifyClient(_source, _U("ranchNotFound"), "error", 4000)
        cb(false)
    end
end)

BccUtils.RPC:Register("bcc-ranch:InsertChoreCoordsIntoDB", function(params, cb, source)
    local _source = source
    local choreCoords = params.choreCoords
    local ranchId = params.ranchId
    local choreType = params.choreType

    devPrint("Inserting chore coords for ranchId: " .. ranchId .. " with choreType: " .. choreType)

    local databaseUpdate = {
        ['shovehaycoords'] = function()
            return MySQL.update.await("UPDATE bcc_ranch SET shovel_hay_coords = ? WHERE ranchid = ?", { json.encode(choreCoords), ranchId })
        end,
        ['wateranimalcoords'] = function()
            return MySQL.update.await("UPDATE bcc_ranch SET water_animal_coords = ? WHERE ranchid = ?", { json.encode(choreCoords), ranchId })
        end,
        ['repairtroughcoords'] = function()
            return MySQL.update.await("UPDATE bcc_ranch SET repair_trough_coords = ? WHERE ranchid = ?", { json.encode(choreCoords), ranchId })
        end,
        ['scooppoopcoords'] = function()
            return MySQL.update.await("UPDATE bcc_ranch SET scoop_poop_coords = ? WHERE ranchid = ?", { json.encode(choreCoords), ranchId })
        end
    }

    if databaseUpdate[choreType] then
        local result = databaseUpdate[choreType]()
        if result then
            UpdateAllRanchersRanchData(ranchId)
            cb(true)
            devPrint(_U("coordsSet"))
        else
            cb(false)
            devPrint("Database error")
        end
    else
        cb(false)
        devPrint("Invalid chore type")
    end
end)

BccUtils.RPC:Register("bcc-ranch:IncreaseRanchCond", function(params, cb, source)
    local ranchId = params.ranchId
    local amount = tonumber(params.amount)
    -- Validate parameters
    if not ranchId or not amount then
        devPrint("[ERROR] Invalid parameters: ranchId:", ranchId, "amount:", amount)
        cb(false, "Invalid parameters") -- Respond with failure if inputs are invalid
        return
    end
    devPrint("[DEBUG] Increasing ranch condition for ranchId: " .. ranchId .. " by amount: " .. amount)
    -- Update the database
    local result = MySQL.update.await("UPDATE bcc_ranch SET ranchCondition = ranchCondition + ? WHERE ranchid = ?", { amount, ranchId })
    -- Check database operation
    if result then
        devPrint("[DEBUG] Ranch condition updated successfully for ranchId: " .. ranchId)
        UpdateAllRanchersRanchData(ranchId) -- Notify all ranchers of the update
        cb(true) -- Respond with success
    else
        devPrint("[ERROR] Failed to update ranch condition for ranchId: " .. ranchId)
        cb(false) -- Respond with failure
    end
end)

BccUtils.RPC:Register("bcc-ranch:AnimalBought", function(params, cb, source)
    local ranchId = params.ranchId
    local animalType = params.animalType
    devPrint("Animal bought for ranchId: " .. ranchId .. " with animalType: " .. animalType)
    local character = VORPcore.getUser(source).getUsedCharacter
    local ranch = MySQL.query.await("SELECT * FROM bcc_ranch WHERE ranchid = ?", { ranchId })

    if #ranch > 0 then
        local function animalBoughtLogic(cost)
            character.removeCurrency(0, cost)
            NotifyClient(source, _U("animalBought"), "success", 4000)
        end
        local buyAnimalOptions = {
            ['cows'] = function()
                if character.money >= ConfigAnimals.animalSetup.cows.cost then
                    if ranch[1].cows == "false" then
                        animalBoughtLogic(ConfigAnimals.animalSetup.cows.cost)
                        MySQL.update.await("UPDATE bcc_ranch SET cows='true' WHERE ranchid = ?", { ranchId })
                        UpdateAllRanchersRanchData(ranchId)
                    else
                        NotifyClient(source, _U("alreadyOwnsAnimal"), "error", 4000)
                    end
                else
                    NotifyClient(source, _U("notEnoughMoney"), "error", 4000)
                end
            end,
            ['pigs'] = function()
                if character.money >= ConfigAnimals.animalSetup.pigs.cost then
                    if ranch[1].pigs == "false" then
                        animalBoughtLogic(ConfigAnimals.animalSetup.pigs.cost)
                        MySQL.update.await("UPDATE bcc_ranch SET pigs='true' WHERE ranchid = ?", { ranchId })
                        UpdateAllRanchersRanchData(ranchId)
                    else
                        NotifyClient(source, _U("alreadyOwnsAnimal"), "error", 4000)
                    end
                else
                    NotifyClient(source, _U("notEnoughMoney"), "error", 4000)
                end
            end,
            ['sheeps'] = function()
                if character.money >= ConfigAnimals.animalSetup.sheeps.cost then
                    if ranch[1].sheeps == "false" then
                        animalBoughtLogic(ConfigAnimals.animalSetup.sheeps.cost)
                        MySQL.update.await("UPDATE bcc_ranch SET sheeps='true' WHERE ranchid = ?", { ranchId })
                        UpdateAllRanchersRanchData(ranchId)
                    else
                        NotifyClient(source, _U("alreadyOwnsAnimal"), "error", 4000)
                    end
                else
                    NotifyClient(source, _U("notEnoughMoney"), "error", 4000)
                end
            end,
            ['goats'] = function()
                if character.money >= ConfigAnimals.animalSetup.goats.cost then
                    if ranch[1].goats == "false" then
                        animalBoughtLogic(ConfigAnimals.animalSetup.goats.cost)
                        MySQL.update.await("UPDATE bcc_ranch SET goats='true' WHERE ranchid = ?", { ranchId })
                        UpdateAllRanchersRanchData(ranchId)
                    else
                        NotifyClient(source, _U("alreadyOwnsAnimal"), "error", 4000)
                    end
                else
                    NotifyClient(source, _U("notEnoughMoney"), "error", 4000)
                end
            end,
            ['chickens'] = function()
                if character.money >= ConfigAnimals.animalSetup.chickens.cost then
                    if ranch[1].chickens == "false" then
                        animalBoughtLogic(ConfigAnimals.animalSetup.chickens.cost)
                        MySQL.update.await("UPDATE bcc_ranch SET chickens='true' WHERE ranchid = ?", { ranchId })
                        UpdateAllRanchersRanchData(ranchId)
                    else
                        NotifyClient(source, _U("alreadyOwnsAnimal"), "error", 4000)
                    end
                else
                    NotifyClient(source, _U("notEnoughMoney"), "error", 4000)
                end
            end
        }
        if buyAnimalOptions[animalType] then
            buyAnimalOptions[animalType]()
            cb(true) -- Return success callback
        else
            NotifyClient(source, _U("invalidAnimalType"), "error", 4000)
            cb(false) -- Return failure callback if invalid animal type
        end
    else
        NotifyClient(source, _U("ranchNotFound"), "error", 4000)
        cb(false) -- Return failure callback if ranch not found
    end
end)

BccUtils.RPC:Register("bcc-ranch:InsertAnimalRelatedCoords", function(params, cb, recSource)
    local _source = recSource or source
    if not _source then
        devPrint("Error: _source is nil")
        return
    end
    local user = VORPcore.getUser(_source)
    if not user then
        devPrint("Error: User not found for source: " .. tostring(_source))
        return
    end
    local character = user.getUsedCharacter
    if not character then
        devPrint("Error: No character found for user: " .. tostring(_source))
        return
    end
    local ranchId = params.ranchId
    local coords = params.coords
    local type = params.type
    local moneyToRemove = params.cost
    devPrint("Inserting animal-related coords for ranchId: " .. ranchId .. ", Type: " .. type)
    -- Fetch ranch data
    local ranch = MySQL.query.await("SELECT * FROM bcc_ranch WHERE ranchid = ?", { ranchId })
    if not ranch or #ranch == 0 then
        devPrint("Error: No ranch found for ranchId: " .. ranchId)
        cb(false)
        return
    end
    devPrint("Ranch data successfully retrieved for ranchId: " .. ranchId)
    -- Define update actions based on type
    local updateTable = {
        ['herdCoords'] = function()
            devPrint("Updating herdCoords for ranchId: " .. ranchId)
            MySQL.update("UPDATE bcc_ranch SET herd_coords = ? WHERE ranchid = ?", { json.encode(coords), ranchId })
        end,
        ['feedWagonCoords'] = function()
            devPrint("Updating feedWagonCoords for ranchId: " .. ranchId)
            MySQL.update("UPDATE bcc_ranch SET feed_wagon_coords = ? WHERE ranchid = ?", { json.encode(coords), ranchId })
        end,
        ['cowCoords'] = function()
            devPrint("Updating cowCoords for ranchId: " .. ranchId)
            MySQL.update("UPDATE bcc_ranch SET cow_coords = ? WHERE ranchid = ?", { json.encode(coords), ranchId })
        end,
        ['pigCoords'] = function()
            devPrint("Updating pigCoords for ranchId: " .. ranchId)
            MySQL.update("UPDATE bcc_ranch SET pig_coords = ? WHERE ranchid = ?", { json.encode(coords), ranchId })
        end,
        ['sheepCoords'] = function()
            devPrint("Updating sheepCoords for ranchId: " .. ranchId)
            MySQL.update("UPDATE bcc_ranch SET sheep_coords = ? WHERE ranchid = ?", { json.encode(coords), ranchId })
        end,
        ['goatCoords'] = function()
            devPrint("Updating goatCoords for ranchId: " .. ranchId)
            MySQL.update("UPDATE bcc_ranch SET goat_coords = ? WHERE ranchid = ?", { json.encode(coords), ranchId })
        end,
        ['chickenCoords'] = function()
            devPrint("Updating chickenCoords for ranchId: " .. ranchId)
            MySQL.update("UPDATE bcc_ranch SET chicken_coords = ? WHERE ranchid = ?", { json.encode(coords), ranchId })
        end,
        ['coopCoords'] = function()
            devPrint("Updating coopCoords for ranchId: " .. ranchId)
            MySQL.update("UPDATE bcc_ranch SET chicken_coop = 'true', chicken_coop_coords = ? WHERE ranchid = ?", { json.encode(coords), ranchId })
        end
    }
    if updateTable[type] then
        devPrint("Valid type provided: " .. type)
        if moneyToRemove then
            devPrint("Cost to remove: " .. moneyToRemove)
            devPrint("Character money: " .. tostring(character.money))
            if character.money >= moneyToRemove then
                devPrint("Sufficient funds. Removing money and updating coordinates.")
                character.removeCurrency(0, moneyToRemove)
                updateTable[type]()
                UpdateAllRanchersRanchData(ranchId)
                devPrint("Coordinates successfully updated for type: " .. type)
                cb(true)
            else
                devPrint("Error: Insufficient funds for _source: " .. _source)
                cb(false)
            end
        else
            devPrint("No cost required. Proceeding to update coordinates.")
            updateTable[type]()
            UpdateAllRanchersRanchData(ranchId)
            devPrint("Coordinates successfully updated for type: " .. type)
            cb(true)
            return
        end

        -- Fetch updated ranch data
        local updatedRanchData = MySQL.query.await("SELECT * FROM bcc_ranch WHERE ranchid = ?", { ranchId })
        -- Notify all clients about the updated ranch data
        BccUtils.RPC:Call("bcc-ranch:UpdateRanchData",  _source, updatedRanchData[1])
        cb(true)
    else
        devPrint("Error: Invalid type provided: " .. type)
        cb(false)
        return
    end
end)

BccUtils.RPC:Register("bcc-ranch:UpdateAnimalsOut", function(params, cb, recSource)
    local ranchId = params.ranchId
    local isOut = params.isOut
    devPrint("Updating animals out for ranchId: " .. ranchId .. " with isOut: " .. tostring(isOut))
    devPrint("Received recSource: " .. tostring(recSource))
    if RanchersOnline[ranchId] then
        devPrint("Current RanchersOnline: " .. json.encode(RanchersOnline[ranchId]))
        for k, v in pairs(RanchersOnline[ranchId]) do
            devPrint("Comparing recSource: " .. tostring(recSource) .. " with rancherSource: " .. tostring(v.rancherSource))
            if recSource == v.rancherSource then
                if isOut then
                    devPrint("Setting is_any_animals_out to true for ranchId: " .. ranchId)
                    MySQL.update.await("UPDATE bcc_ranch SET is_any_animals_out='true' WHERE ranchid = ?", { ranchId })
                    v.doesRancherHaveAnimalsOut = true
                else
                    devPrint("Setting is_any_animals_out to false for ranchId: " .. ranchId)
                    MySQL.update.await("UPDATE bcc_ranch SET is_any_animals_out='false' WHERE ranchid = ?", { ranchId })
                    v.doesRancherHaveAnimalsOut = false
                end
                UpdateAllRanchersRanchData(ranchId)
                devPrint("Successfully updated animals out for rancher source: " .. tostring(v.rancherSource))
                cb(true)
                return
            end
        end
    else
        devPrint("No RanchersOnline entry for ranchId: " .. ranchId)
    end
    devPrint("Failed to update animals out for ranchId: " .. ranchId .. ". Rancher source not found.")
    cb(false)
end)

BccUtils.RPC:Register("bcc-ranch:IncreaseAnimalsCond", function(params, cb, recSource)
    local ranchId = params.ranchId
    local animalType = params.animalType
    local incAmount = params.incAmount
    -- Debugging logs
    devPrint("Increasing animal condition for ranchId: " .. ranchId .. " with animalType: " .. animalType .. " and incAmount: " .. incAmount)
    -- Animal condition update logic
    local animalOptionsTable = {
        ['cows'] = function()
            MySQL.update("UPDATE bcc_ranch SET cows_cond = cows_cond + ? WHERE ranchid = ?", { incAmount, ranchId })
        end,
        ['pigs'] = function()
            MySQL.update("UPDATE bcc_ranch SET pigs_cond = pigs_cond + ? WHERE ranchid = ?", { incAmount, ranchId })
        end,
        ['sheeps'] = function()
            MySQL.update("UPDATE bcc_ranch SET sheeps_cond = sheeps_cond + ? WHERE ranchid = ?", { incAmount, ranchId })
        end,
        ['goats'] = function()
            MySQL.update("UPDATE bcc_ranch SET goats_cond = goats_cond + ? WHERE ranchid = ?", { incAmount, ranchId })
        end,
        ['chickens'] = function()
            MySQL.update("UPDATE bcc_ranch SET chickens_cond = chickens_cond + ? WHERE ranchid = ?", { incAmount, ranchId })
        end
    }
    -- Check if the animal type is valid
    if animalOptionsTable[animalType] then
        animalOptionsTable[animalType]()
        UpdateAllRanchersRanchData(ranchId)
        if cb then cb(true) end
    else
        devPrint("Invalid animal type provided: " .. tostring(animalType))
        if cb then cb(false) end
    end
end)

BccUtils.RPC:Register("bcc-ranch:IncreaseAnimalAge", function(params, cb, source)
    local ranchId = params.ranchId
    local animalType = params.animalType
    local incAmount = params.incAmount
    devPrint("IncreaseAnimalAge RPC received from source: " .. tostring(source) .. " with ranchId: " .. tostring(ranchId) .. ", animalType: " .. tostring(animalType) .. ", incAmount: " .. tostring(incAmount))
    -- Define the animal types and their respective columns, max age, and max condition
    local animalTypes = {
        ['cows'] = {column = "cows_age", conditionColumn = "cows_cond", maxAge = ConfigAnimals.animalSetup.cows.maxAge, maxCondition = ConfigAnimals.animalSetup.cows.maxCondition},
        ['pigs'] = {column = "pigs_age", conditionColumn = "pigs_cond", maxAge = ConfigAnimals.animalSetup.pigs.maxAge, maxCondition = ConfigAnimals.animalSetup.pigs.maxCondition},
        ['sheeps'] = {column = "sheeps_age", conditionColumn = "sheeps_cond", maxAge = ConfigAnimals.animalSetup.sheeps.maxAge, maxCondition = ConfigAnimals.animalSetup.sheeps.maxCondition},
        ['goats'] = {column = "goats_age", conditionColumn = "goats_cond", maxAge = ConfigAnimals.animalSetup.goats.maxAge, maxCondition = ConfigAnimals.animalSetup.goats.maxCondition},
        ['chickens'] = {column = "chickens_age", conditionColumn = "chickens_cond", maxAge = ConfigAnimals.animalSetup.chickens.maxAge, maxCondition = ConfigAnimals.animalSetup.chickens.maxCondition}
    }
    -- Check if animalType exists in the animalTypes table
    local animal = animalTypes[animalType]
    if not animal then
        devPrint("Error: Invalid animal type provided: " .. tostring(animalType))
        cb(false) -- Return failure callback for invalid animal type
        return
    end
    -- Query the current age and condition for the specific animal
    MySQL.query("SELECT " .. animal.column .. ", " .. animal.conditionColumn .. " FROM bcc_ranch WHERE ranchid = ?", { ranchId }, function(results)
        if results and #results > 0 then
            local result = results[1] -- Get the first result row
            local currentAge = result[animal.column]
            local currentCondition = result[animal.conditionColumn]
            -- Check if the result contains valid data
            if currentAge == nil or currentCondition == nil then
                devPrint("Error: Unable to fetch valid age or condition data for " .. animalType .. " at ranchId: " .. ranchId)
                cb(false) -- Return failure callback if data is missing
                return
            end
            -- Debug print the fetched values
            devPrint("Fetched currentAge: " .. tostring(currentAge) .. ", currentCondition: " .. tostring(currentCondition))
            -- Check if the current age has reached or exceeded the max age
            if currentAge >= animal.maxAge then
                devPrint("Error: Animal age has reached or exceeded max age (" .. animal.maxAge .. "). Age will not be increased.")
                -- Notify the player that the animal has reached its maximum age
                NotifyClient(source, "Your " .. animalType .. " has reached the maximum age of " .. animal.maxAge .. " and will not age further.", "error", 4000)
                cb(false) -- Return failure callback if the animal has reached max age
                return
            end
            if currentCondition >= animal.maxCondition then
                -- Update the animal's age in the database
                MySQL.update("UPDATE bcc_ranch SET " .. animal.column .. " = " .. animal.column .. " + ? WHERE ranchid = ?", { incAmount, ranchId })
                UpdateAllRanchersRanchData(ranchId)
                devPrint("Successfully increased age for " .. animalType .. " at ranchId: " .. ranchId)
                cb(true) -- Return success callback
            else
                devPrint("Error: Animal condition (" .. currentCondition .. ") does not match max condition (" .. animal.maxCondition .. ") and cannot be increased.")
                cb(false)
            end
        else
            devPrint("Error: Unable to fetch current age and condition for " .. animalType .. " at ranchId: " .. ranchId)
            cb(false) -- Return failure callback if data fetch fails
        end
    end)
end)

BccUtils.RPC:Register("bcc-ranch:ButcherAnimalHandler", function(params, cb, recSource)
    local animalType = params.animalType
    local ranchId = params.ranchId
    local table = params.table
    devPrint("Butchering animal for ranchId: " .. ranchId .. " with animalType: " .. animalType)
    local butcherFuncts = {
        ['cows'] = function()
            MySQL.update.await('UPDATE bcc_ranch SET cows = "false", cows_cond = 0, cows_age = 0, cow_coords = "none" WHERE ranchid = ?', { ranchId })
        end,
        ['chickens'] = function()
            MySQL.update.await('UPDATE bcc_ranch SET chickens = "false", chickens_cond = 0, chickens_age = 0, chicken_coords = "none", chicken_coop = "false", chicken_coop_coords = "none" WHERE ranchid = ?', { ranchId })
        end,
        ['pigs'] = function()
            MySQL.update.await('UPDATE bcc_ranch SET pigs = "false", pigs_cond = 0, pigs_age = 0, pig_coords = "none" WHERE ranchid = ?', { ranchId })
        end,
        ['sheeps'] = function()
            MySQL.update.await('UPDATE bcc_ranch SET sheeps = "false", sheeps_cond = 0, sheeps_age = 0, sheep_coords = "none" WHERE ranchid = ?', { ranchId })
        end,
        ['goats'] = function()
            MySQL.update.await('UPDATE bcc_ranch SET goats = "false", goats_cond = 0, goats_age = 0, goat_coords = "none" WHERE ranchid = ?', { ranchId })
        end
    }

    if butcherFuncts[animalType] then
        butcherFuncts[animalType]()
        UpdateAllRanchersRanchData(ranchId)  -- Update ranch data for all ranchers
    end
    -- Adding butcher items to the player's inventory
    for k, v in pairs(table.butcherItems) do
        exports.vorp_inventory:addItem(recSource, v.name, v.count, {})
        NotifyClient(recSource, "You have received " .. v.name .. " x " .. v.count, "success", 4000)
    end
    cb(true)
end)

BccUtils.RPC:Register("bcc-ranch:AnimalSold", function(params, cb, recSource)
    local ranchId = params.ranchId
    local animalType = params.animalType
    -- Fetch the ranch data from the database
    local ranch = MySQL.query.await("SELECT * FROM bcc_ranch WHERE ranchid = ?", { ranchId })
    if #ranch > 0 then
        local config = ConfigAnimals.animalSetup[animalType]
        if not config then
            devPrint("Error: Invalid animal type in AnimalSold: " .. tostring(animalType))
            if cb then cb(false) end
            return
        end
        local payAmount = config.basePay or 0
        -- If the animal's condition is at max, add maxConditionPay
        local conditionColumn = animalType .. "_cond"
        local currentCondition = ranch[1][conditionColumn]
        if currentCondition and currentCondition >= config.maxCondition then
            payAmount = payAmount + (config.maxConditionPay or 0)
        end
        devPrint("Animal sold for ranchId: " .. ranchId .. " with animalType: " .. animalType .. " and payAmount: " .. payAmount)
        -- Update ledger with the sale amount
        MySQL.update.await("UPDATE bcc_ranch SET ledger = ledger + ? WHERE ranchid = ?", { payAmount, ranchId })
        -- Define functions for each animal type that resets animal data
        local soldFuncts = {
            ['cows'] = function()
                MySQL.update.await('UPDATE bcc_ranch SET cows = "false", cows_cond = 0, cows_age = 0, cow_coords = "none" WHERE ranchid = ?', { ranchId })
            end,
            ['chickens'] = function()
                MySQL.update.await('UPDATE bcc_ranch SET chickens = "false", chickens_cond = 0, chickens_age = 0, chicken_coords = "none", chicken_coop = "false", chicken_coop_coords = "none" WHERE ranchid = ?', { ranchId })
            end,
            ['pigs'] = function()
                MySQL.update.await('UPDATE bcc_ranch SET pigs = "false", pigs_cond = 0, pigs_age = 0, pig_coords = "none" WHERE ranchid = ?', { ranchId })
            end,
            ['sheeps'] = function()
                MySQL.update.await('UPDATE bcc_ranch SET sheeps = "false", sheeps_cond = 0, sheeps_age = 0, sheep_coords = "none" WHERE ranchid = ?', { ranchId })
            end,
            ['goats'] = function()
                MySQL.update.await('UPDATE bcc_ranch SET goats = "false", goats_cond = 0, goats_age = 0, goat_coords = "none" WHERE ranchid = ?', { ranchId })
            end
        }
        -- Execute the corresponding function for the given animal type
        if soldFuncts[animalType] then
            soldFuncts[animalType]()
            UpdateAllRanchersRanchData(ranchId)
        end
        -- Notify success back to the client
        devPrint("Successfully sold animal for ranchId: " .. ranchId .. " with animalType: " .. animalType)
        NotifyClient(recSource, "You have received " .. payAmount .. " on to ranch ledger", "success", 4000)
        if cb then cb(true) end
    else
        -- Ranch not found or invalid data
        devPrint("Ranch not found or invalid ranchId: " .. ranchId)
        if cb then cb(false) end
    end
end)

-- Cleanup --
AddEventHandler('onResourceStop', function(resourceName)
    if (GetCurrentResourceName() == resourceName) then
        MySQL.update.await("UPDATE bcc_ranch SET is_any_animals_out = 'false'")
    end
end)
