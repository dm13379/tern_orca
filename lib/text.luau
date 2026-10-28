local Text = {}

local function valid(text)
	local ok, count = pcall(utf8.len, text)
	if not ok or count == nil then
		return false
	end
	for _, code in utf8.codes(text) do
		if code < 32 or (code >= 127 and code <= 159) or code == 0x2028 or code == 0x2029 then
			return false
		end
	end
	return true
end

local function byteAt(text, position)
	return utf8.offset(text, position + 1) or #text + 1
end

local function utf16At(text, position)
	local units, count = 0, 0
	for _, code in utf8.codes(text) do
		if count >= position then
			break
		end
		units += if code > 0xffff then 2 else 1
		count += 1
	end
	return units
end

local function positionAt(text, offset)
	local units, count = 0, 0
	for _, code in utf8.codes(text) do
		local nextUnits = units + (if code > 0xffff then 2 else 1)
		if nextUnits > offset then
			break
		end
		units = nextUnits
		count += 1
	end
	return count
end

local function bounds(field)
	local anchor = field.anchor or field.cursor
	return math.min(anchor, field.cursor), math.max(anchor, field.cursor)
end

local function replace(field, value)
	local first, last = bounds(field)
	field.text = field.text:sub(1, byteAt(field.text, first) - 1)
		.. value .. field.text:sub(byteAt(field.text, last))
	field.cursor = first + utf8.len(value)
	field.anchor = nil
end

local function move(field, position, shift)
	field.anchor = if shift then field.anchor or field.cursor else nil
	field.cursor = position
end

function Text.new(value)
	value = if type(value) == "string" and valid(value) then value else ""
	return { text = value, cursor = utf8.len(value), anchor = nil }
end

function Text.props(field)
	return {
		text = field.text,
		cursor = utf16At(field.text, field.cursor),
		anchor = if field.anchor ~= nil then utf16At(field.text, field.anchor) else nil,
	}
end

function Text.selection(field)
	local first, last = bounds(field)
	return field.text:sub(byteAt(field.text, first), byteAt(field.text, last) - 1)
end

function Text.key(field, key)
	local length = utf8.len(field.text)
	local name = string.lower(key.name)
	local command = key.ctrl or key.meta
	if command and name == "a" then
		field.anchor, field.cursor = 0, length
	elseif name == "home" or (key.meta and name == "left") then
		move(field, 0, key.shift)
	elseif name == "end" or (key.meta and name == "right") then
		move(field, length, key.shift)
	elseif name == "left" or name == "right" then
		local first, last = bounds(field)
		local position
		if not key.shift and first ~= last then
			position = if name == "left" then first else last
		else
			position = math.clamp(field.cursor + (if name == "left" then -1 else 1), 0, length)
		end
		move(field, position, key.shift)
	elseif name == "backspace" or name == "delete" then
		local first, last = bounds(field)
		if first == last then
			field.anchor = if name == "backspace" then math.max(0, field.cursor - 1)
				else math.min(length, field.cursor + 1)
		end
		replace(field, "")
	elseif command and name == "x" then
		replace(field, "")
	elseif key.text and (name == "paste" or not (key.ctrl or key.meta)) then
		if not valid(key.text) then
			return true, "请输入单行文本，不能包含换行或控制字符。"
		end
		replace(field, key.text)
	else
		return false
	end
	return true
end

function Text.edit(field, event)
	local length = utf8.len(field.text)
	if event.len ~= utf16At(field.text, length) then
		return false
	end
	if type(event.from) ~= "number" or type(event.to) ~= "number"
		or type(event.cursor) ~= "number" or type(event.text) ~= "string" then
		return false
	end
	if not valid(event.text) then
		return false, "请输入单行文本，不能包含换行或控制字符。"
	end
	field.anchor = positionAt(field.text, event.from)
	field.cursor = positionAt(field.text, event.to)
	replace(field, event.text)
	field.cursor = positionAt(field.text, event.cursor)
	return true
end

return Text
