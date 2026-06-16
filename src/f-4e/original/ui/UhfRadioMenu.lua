---// Copyright (c) 2023 Heatblur Simulations. All rights reserved.

local Interactions = require('base.Interactions')

local radio_mode = {
    off = "OFF",
    tr_adf = "TR_ADF",
    trg_adf = "TR_G_ADF",
    adfg_cmd = "ADF_G_CMD",
    adf_g = "ADF_G",
    g_adf = "GUARD_ADF",
}

local radio_freq_mode = {
    preset = "PRESET",
    manual = "MANUAL",
}

local radio_freq_hundreds = {
    t = "T",
    ["2"] = "TWO",
    ["3"] = "THREE",
    a = "A",
}

local radio_freq_decimal = {
    ["00"] = "ZERO",
    ["25"] = "TWENTY_FIVE",
    ["50"] = "FIFTY",
    ["75"] = "SEVENTY_FIVE",
}

local radio_freq_decimal_msfs = {
    ["00"] = "ZERO",
    ["05"] = "ZERO_FIVE",
    ["10"] = "ONE_ZERO",
    ["15"] = "ONE_FIVE",
    ["20"] = "TWO_ZERO",
    ["25"] = "TWO_FIVE",
    ["30"] = "THREE_ZERO",
    ["35"] = "THREE_FIVE",
    ["40"] = "FOUR_ZERO",
    ["45"] = "FOUR_FIVE",
    ["50"] = "FIVE_ZERO",
    ["55"] = "FIVE_FIVE",
    ["60"] = "SIX_ZERO",
    ["65"] = "SIX_FIVE",
    ["70"] = "SEVEN_ZERO",
    ["75"] = "SEVEN_FIVE",
    ["80"] = "EIGHT_ZERO",
    ["85"] = "EIGHT_FIVE",
    ["90"] = "NINE_ZERO",
    ["95"] = "NINE_FIVE",
}

local ToggleCommand = function(task)
    return task:ClickShort("Comm Command", "ON")
end

local function round_decimal_ones(value)
    local value_int = tonumber(value)
    if value_int < 12.5 then
        return "00"
    elseif value_int < 37.5 then
        return "25"
    elseif value_int < 62.5 then
        return "50"
    else
        return "75"
    end
end

local function round_decimal_ones_msfs(value)
    local n = tonumber(value) or 0
    -- clamp to 0..99.999 so we don't spill to 100
    if n < 0 then n = 0 elseif n > 99.999 then n = 99.999 end
    -- round to nearest 5 (0,5,10,...,95); midpoint (.5) rounds up
    local r = math.floor((n + 2.5) / 5) * 5
    if r >= 100 then r = 95 end
    return string.format("%02d", r)
end

local UpdateRadioWheelInfo = function()
    local update_wheel_behaviour = GetJester().behaviors[UpdateJesterWheel]
    if update_wheel_behaviour ~= nil then
        update_wheel_behaviour:UpdateRadioWheelInfo()
    end
end

local SetUhfFrequency = function(task, frequency_text)
    -- e.g. 227875 (kHz)
    local hundreds = frequency_text:sub(1, 1) -- 2
    local tens = frequency_text:sub(2, 2) -- 2
    local ones = frequency_text:sub(3, 3) -- 7
    local decimalsHundreds = frequency_text:sub(4, 4) -- 8
    local decimalsOnes = frequency_text:sub(5, 6) -- 75
    decimalsOnes = round_decimal_ones(decimalsOnes)

    return task:Click("Radio Freq 1xx.xxx", radio_freq_hundreds[hundreds], s(0.2), true)
               :Click("Radio Freq x1x.xxx", tens, s(0.2), true)
               :Click("Radio Freq xx1.xxx", ones, s(0.2), true)
               :Click("Radio Freq xxx.1xx", decimalsHundreds, s(0.2), true)
               :Click("Radio Freq xxx.x11", radio_freq_decimal[decimalsOnes], s(0.2), true)
end

local SetUhfFrequencyMSFS = function(task, frequency_text)
    -- e.g. 227875 (kHz)
    local hundreds = frequency_text:sub(1, 1) -- 2
    local tens = frequency_text:sub(2, 2) -- 2
    local ones = frequency_text:sub(3, 3) -- 7
    local decimalsHundreds = frequency_text:sub(4, 4) -- 8
    local decimalsOnes = frequency_text:sub(5, 6) -- 75
    decimalsOnes = round_decimal_ones_msfs(decimalsOnes)
    local decEnum = radio_freq_decimal_msfs[decimalsOnes] or "ZERO"

    return task:Click("Radio Freq 1xx.xxx", radio_freq_hundreds[hundreds], s(0.2), true)
               :Click("Radio Freq x1x.xxx", tens, s(0.2), true)
               :Click("Radio Freq xx1.xxx", ones, s(0.2), true)
               :Click("Radio Freq xxx.1xx", decimalsHundreds, s(0.2), true)
               :Click("Radio Freq xxx.x11", decEnum, s(0.2), true)
end

local TuneManualFrequency = function(task, frequency_text)
    local frequency_num = tonumber(frequency_text)

    if frequency_num < 225000 or frequency_num > 399975 then
        Log("CantDo: Tune Manual FREQ - Out of supported range")
        task:CantDo()
        return
    end

    task:Roger()
    -- Knobs block for invalid frequencies, which can happen while setting from left to right.
    -- (e.g. 227000 can not be entered if currently at 250000, as an intermediate value would be 220000)
    -- So we first put it into a safe frequency that can reach anything if set like that.
    SetUhfFrequency(task, "255550")
    SetUhfFrequency(task, frequency_text)
            :Click("Radio Freq Mode", radio_freq_mode.manual)
            :Click("Radio Mode", radio_mode.trg_adf)
            :Then(function() UpdateRadioWheelInfo() end)
end

local TuneManualFrequencyMSFS = function(task, frequency_text)
    local frequency_num = tonumber(frequency_text)
    frequency_num = frequency_num + 200000 --Frequency shift
    if frequency_num < 225000 or frequency_num > 399975 then
        task:CantDo()
        return
    end

    local shifted_text = string.format("%06d", frequency_num)

    task:Roger()
    -- Knobs block for invalid frequencies, which can happen while setting from left to right.
    -- (e.g. 227000 can not be entered if currently at 250000, as an intermediate value would be 220000)
    -- So we first put it into a safe frequency that can reach anything if set like that.
    SetUhfFrequencyMSFS(task, "255550")
    SetUhfFrequencyMSFS(task, shifted_text)
            :Click("Radio Freq Mode", radio_freq_mode.manual)
            :Click("Radio Mode", radio_mode.trg_adf)
            :Then(function() UpdateRadioWheelInfo() end)
end

ListenTo("radio_mode", "UhfRadioMenu", function(task, mode)
    task:Roger():Click("Radio Mode", radio_mode[mode])
            :Then(function() UpdateRadioWheelInfo() end)
end)

ListenTo("radio_manual_freq_text", "UhfRadioMenu", function(task, freq)
    if freq == nil then
        Log("CantDo: Set Manual FREQ - No value given")
        task:CantDo()
        return
    end
    -- Removing any spaces from the input
    local cleanFreq = freq:gsub("%s+", "")
    if cleanFreq:match("%D") or #cleanFreq ~= 6 then
        Log("CantDo: Set Manual FREQ - Value invalid format")
        task:CantDo()
        return
    end
    -- Ensuring the frequency is in the correct format
    local MHzPart, kHzPart = cleanFreq:match("(%d%d%d)(%d%d%d)")
    if MHzPart == nil or kHzPart == nil then
        Log("CantDo: Set Manual FREQ - Value invalid format")
        task:CantDo()
        return
    end
    local frequencyInkHz = MHzPart .. kHzPart

    TuneManualFrequency(task, frequencyInkHz)
end)

ListenTo("radio_comm_chan", "UhfRadioMenu", function(task, chan)
    task:Roger()
            :Click("Radio Freq Mode", radio_freq_mode.preset)
            :Click("Radio Comm Chan", tostring(chan))
            :Then(function() UpdateRadioWheelInfo() end)
end)

ListenTo("radio_aux_chan", "UhfRadioMenu", function(task, chan)
    task:Roger():Click("Radio Aux Chan", tostring(chan))
            :Then(function() UpdateRadioWheelInfo() end)
end)

ListenTo("radio_tune_atc", "UhfRadioMenu", function(task, freq)
    TuneManualFrequency(task, freq)
end)

ListenTo("msfs_radio_tune_atc", "UhfRadioMenu", function(task, freq)
    TuneManualFrequencyMSFS(task, freq)
end)
