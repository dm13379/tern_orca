local windows = tern.runtime.os == "windows"

local paths = {}

function paths.normalize(path)
	if windows then
		path = path:gsub("\\", "/")
	end

	local root = ""
	local rest = path
	if windows then
		local server, share, suffix = path:match("^//([^/]+)/([^/]+)/*(.*)$")
		local drive, driveSuffix = path:match("^([A-Za-z]):/*(.*)$")
		if server and share then
			root = "//" .. server .. "/" .. share
			rest = suffix
		elseif drive and path:sub(3, 3) == "/" then
			root = drive:upper() .. ":/"
			rest = driveSuffix
		elseif path:sub(1, 1) == "/" then
			root = "/"
			rest = path:sub(2)
		end
	elseif path:sub(1, 1) == "/" then
		root = "/"
		rest = path:sub(2)
	end

	local segments = {}
	for part in rest:gmatch("[^/]+") do
		if part == ".." then
			if #segments > 0 and segments[#segments] ~= ".." then
				table.remove(segments)
			elseif root == "" then
				table.insert(segments, part)
			end
		elseif part ~= "." and part ~= "" then
			table.insert(segments, part)
		end
	end

	local suffix = table.concat(segments, "/")
	if root == "" then
		return suffix == "" and "." or suffix
	elseif suffix == "" then
		return root
	elseif root:sub(-1) == "/" then
		return root .. suffix
	end
	return root .. "/" .. suffix
end

function paths.isAbsolute(path)
	if windows then
		path = path:gsub("\\", "/")
		return path:match("^[A-Za-z]:/") ~= nil or path:match("^//[^/]+/[^/]+") ~= nil
	end
	return path:sub(1, 1) == "/"
end

function paths.absolute(path)
	if type(path) ~= "string" or path == "" then
		return nil, "A path is required."
	end
	if path:find("\0", 1, true) then
		return nil, "A path cannot contain a NUL character."
	end

	if windows then
		path = path:gsub("\\", "/")
		if path:match("^[A-Za-z]:") and path:sub(3, 3) ~= "/" then
			return nil, "Drive-relative paths are ambiguous; use an absolute path such as C:/folder."
		end
		if path:sub(1, 2) == "//" and not path:match("^//[^/]+/[^/]+") then
			return nil, "A UNC path must include both a server and a share."
		end
	end

	if paths.isAbsolute(path) then
		return paths.normalize(path)
	end
	if windows and path:sub(1, 1) == "/" then
		local pluginDir = paths.normalize(tern.plugin.dir)
		local drive = pluginDir:match("^([A-Za-z]:)/")
		local server, share = pluginDir:match("^//([^/]+)/([^/]+)")
		if drive then
			return paths.normalize(drive .. path)
		elseif server and share then
			return paths.normalize("//" .. server .. "/" .. share .. path)
		end
		return nil, "Cannot resolve the path without a Windows drive or UNC share."
	end
	return paths.normalize(tern.plugin.dir .. "/" .. path)
end

function paths.join(parent, child)
	return paths.normalize(parent .. "/" .. child)
end

function paths.basename(path)
	path = paths.normalize(path)
	if path == "/" then
		return path
	end
	local drive = path:match("^([A-Za-z]:)/$")
	if drive then
		return drive
	end
	return path:match("([^/]+)$") or path
end

function paths.parent(path)
	path = paths.normalize(path)
	if path == "/" or path:match("^[A-Za-z]:/$") or (windows and path:match("^//[^/]+/[^/]+$")) then
		return path
	end
	local parent = path:match("^(.*)/[^/]+$")
	if not parent then
		return "."
	elseif parent == "" then
		return "/"
	elseif windows and parent:match("^[A-Za-z]:$") then
		return parent .. "/"
	end
	return parent
end

function paths.same(a, b)
	a = paths.normalize(a)
	b = paths.normalize(b)
	if windows then
		a = a:lower()
		b = b:lower()
	end
	return a == b
end

return paths
