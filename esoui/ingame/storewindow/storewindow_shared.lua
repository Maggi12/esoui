-- Globals
ZO_MODE_STORE_BUY              = 1
ZO_MODE_STORE_BUY_BACK         = 2
ZO_MODE_STORE_SELL             = 3
ZO_MODE_STORE_REPAIR           = 4
ZO_MODE_STORE_SELL_STOLEN      = 5
ZO_MODE_STORE_LAUNDER          = 6
ZO_MODE_STORE_STABLE           = 7

ZO_STORE_WINDOW_MODE_NORMAL = 1
ZO_STORE_WINDOW_MODE_STABLE = 2

STORE_INTERACTION =
{
    type = "Store",
    interactTypes = { INTERACTION_VENDOR, INTERACTION_STABLE },
}

-- Shared object
ZO_SharedStoreManager = ZO_Object:Subclass()

function ZO_SharedStoreManager:New(...)
    local obj = ZO_Object.New(self)
    obj:Initialize(...)
    return obj
end

function ZO_SharedStoreManager:Initialize(control)
    self.control = control
end

function ZO_SharedStoreManager:InitializeStore()
    self.storeUsesMoney, self.storeUsesAP, self.storeUsesTelvarStones, self.storeUsesWritVouchers = GetStoreCurrencyTypes()
end

function ZO_SharedStoreManager:RefreshCurrency()
    self.currentMoney = GetCurrencyAmount(CURT_MONEY, CURRENCY_LOCATION_CHARACTER)
    self.currentAP = GetCurrencyAmount(CURT_ALLIANCE_POINTS, CURRENCY_LOCATION_CHARACTER)
    self.currentTelvarStones = GetCurrencyAmount(CURT_TELVAR_STONES, CURRENCY_LOCATION_CHARACTER)
    self.currentWritVouchers = GetCurrencyAmount(CURT_WRIT_VOUCHERS, CURRENCY_LOCATION_CHARACTER)
end

local INTERNAL_IMPORTANT_ITEMDATA_KEYS = { "entryType", "slotIndex", "name", "stack", "traitInformation",}
function ZO_StoreManager_InternalValidateItems(items, optionalExtraLines)
    for _, itemData in ipairs(items) do
        if not itemData.traitInformation then
            local lines = optionalExtraLines or {}
            table.insert(lines, ("interact name: %q"):format(tostring(GetUnitName("interact"))))
            table.insert(lines, ("Item Link: %q"):format(tostring(GetStoreItemLink(itemData.slotIndex))))
            for _, k in ipairs(INTERNAL_IMPORTANT_ITEMDATA_KEYS) do
                local v = itemData[k]
                local key = type(k) == "string" and string.format("%q", k) or tostring(k)
                local value = type(v) == "string" and string.format("%q", v) or tostring(v)
                table.insert(lines, ("  %s: %s"):format(key, value))
            end
            -- these will probably be cut off by the message limit
            table.insert(lines, "----")
            for k, v in pairs(itemData) do
                local key = type(k) == "string" and string.format("%q", k) or tostring(k)
                local value = type(v) == "string" and string.format("%q", v) or tostring(v)
                table.insert(lines, ("  %s: %s"):format(key, value))
            end

            table.insert(lines, 1, "Invalid vendor object state:")
            internalassert(false, table.concat(lines, "\n  "))
        end
    end
end

-- Shared global functions
function ZO_StoreManager_GetStoreItems()
    local items = {}
    local usedFilterTypes = {}

    for entryIndex = 1, GetNumStoreItems() do
        local icon, name, stack, price, sellPrice, meetsRequirementsToBuy, meetsRequirementsToEquip, quality, questNameColor, currencyType1, currencyQuantity1,
            currencyType2, currencyQuantity2, entryType = GetStoreEntryInfo(entryIndex)

        if stack > 0 then
            local itemLink = GetStoreItemLink(entryIndex)
            local traitInformation = GetItemTraitInformationFromItemLink(itemLink)
            local itemData =
            {
                entryType = entryType,
                slotIndex = entryIndex,
                icon = icon,
                name = name,
                stack = stack,
                price = price,
                sellPrice = sellPrice,
                meetsRequirementsToBuy = meetsRequirementsToBuy,
                meetsRequirementsToEquip = meetsRequirementsToEquip,
                quality = quality,
                questNameColor = questNameColor,
                currencyType1 = currencyType1,
                currencyQuantity1 = currencyQuantity1,
                currencyType2 = currencyType2,
                currencyQuantity2 = currencyQuantity2,
                stackBuyPrice = stack * price,
                stackBuyPriceCurrency1 = stack * currencyQuantity1,
                stackBuyPriceCurrency2 = stack * currencyQuantity2,
                filterData = { GetStoreEntryTypeInfo(entryIndex) },
                statValue = GetStoreEntryStatValue(entryIndex),
                isUnique = IsItemLinkUnique(itemLink),
                traitInformation = traitInformation,
                traitInformationSortOrder = ZO_GetItemTraitInformation_SortOrder(traitInformation),
            }

            if entryType == STORE_ENTRY_TYPE_QUEST_ITEM then
                itemData.questItemId = GetStoreEntryQuestItemId(entryIndex)
            end

            items[#items + 1] = itemData
            for i = 1, #itemData.filterData do
                usedFilterTypes[itemData.filterData[i]] = true
            end
        end
    end

    ZO_StoreManager_InternalValidateItems(items)
    return items, usedFilterTypes
end

function ZO_StoreManager_GetStoreFilterTypes()
    local usedFilterTypes = {}
    for entryIndex = 1, GetNumStoreItems() do
        local filterData = { GetStoreEntryTypeInfo(entryIndex) }
        for i = 1, #filterData do
            usedFilterTypes[filterData[i]] = true
        end
    end
    return usedFilterTypes
end

local DOES_STORE_MODE_REPRESENT_INVENTORY =
{
    [ZO_MODE_STORE_BUY]              = false,
    [ZO_MODE_STORE_BUY_BACK]         = true,
    [ZO_MODE_STORE_SELL]             = true,
    [ZO_MODE_STORE_REPAIR]           = true,
    [ZO_MODE_STORE_SELL_STOLEN]      = true,
    [ZO_MODE_STORE_LAUNDER]          = true,
    [ZO_MODE_STORE_STABLE]           = false,
}

function ZO_StoreManager_IsInventoryStoreMode(mode)
    return DOES_STORE_MODE_REPRESENT_INVENTORY[mode]
end

local CURRENCY_TYPE_TO_SOUND_ID =
{
    [CURT_TELVAR_STONES] = SOUNDS.TELVAR_TRANSACT,
    [CURT_ALLIANCE_POINTS] = SOUNDS.ALLIANCE_POINT_TRANSACT,
    [CURT_WRIT_VOUCHERS] = SOUNDS.WRIT_VOUCHER_TRANSACT,
}

local function PlayItemAcquisitionSound(eventId, itemSoundCategory, specialCurrencyType1, specialCurrencyType2)
    --As of right now there are no stores that use both special currency types and it doesn't make sense
    --to play two currency transact sounds at once, so we only only keying off type1 for now.
    local soundId = CURRENCY_TYPE_TO_SOUND_ID[specialCurrencyType1]
    if soundId then
        PlaySound(soundId)
    else
        PlaySound(SOUNDS.ITEM_MONEY_CHANGED)
    end
end

function ZO_StoreManager_OnPurchased(eventId, entryName, entryType, entryQuantity, money, specialCurrencyType1, specialCurrencyInfo1, specialCurrencyQuantity1, specialCurrencyType2, specialCurrencyInfo2, specialCurrencyQuantity2, itemSoundCategory)
    PlayItemAcquisitionSound(eventId, itemSoundCategory, specialCurrencyType1, specialCurrencyType2)
end
