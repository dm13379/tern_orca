local SIDEBAR = "workspace-rail.sidebar"
local WIZARD = "workspace-rail.wizard"
local BRIDGE = "main.bridge"

local enabledSetting = tern.kv.get("window.sidebar-enabled")
local enabled = enabledSetting ~= false
local columns = tonumber(tern.kv.get("window.sidebar-columns")) or 36
columns = math.clamp(columns, 20, 120)
local catalogs = tern.kv.get("window.catalogs") or {}
local bindings = tern.kv.get("window.session-bindings") or {}
local recentSessions = {}
local panels = {}
local sent = {}
local sentAt = {}
local sources = {}
local sourceByPane = {}
local activeHost
local lastPaths = {}
local missingReported = {}
local widthSavePending = false
local refreshPending = false

local function hostKey(host)
	if host.kind == "local" then return "local" end
	if host.address and host.address ~= "" then return host.address end
	return host.name
end

local function hostInfo(host)
	return { key = hostKey(host), name = host.name, state = host.state }
end

local function newSourceToken()
	local token
	repeat
		token = string.format("%08x%08x%08x%08x", math.random(0, 0x7fffffff), math.random(0, 0x7fffffff),
			math.random(0, 0x7fffffff), math.random(0, 0x7fffffff))
	until not sources[token]
	return token
end

local function registerSource(pane, block, key, token)
	local old = sourceByPane[pane]
	if old then sources[old] = nil end
	token = token or newSourceToken()
	sources[token] = { pane = pane, block = block, hostKey = key }
	sourceByPane[pane] = token
	return token
end

local function sourceFor(pane, block, host)
	local token = sourceByPane[pane]
	local source = token and sources[token]
	local key = hostKey(host)
	if source and source.block == block and source.hostKey == key then return token, false end
	return registerSource(pane, block, key), true
end

local function pathKey(path)
	local value = path:gsub("\\", "/")
	if value ~= "/" then value = value:gsub("/+$", "") end
	if value:match("^%a:") or value:sub(1, 2) == "//" then
		value = value:lower()
	end
	return value
end

local function absolutePath(path)
	return type(path) == "string" and (path:sub(1, 1) == "/"
		or path:match("^%a:[/\\]") ~= nil or path:match("^\\\\") ~= nil)
end

local function inside(path, root)
	local candidate = pathKey(path)
	local base = pathKey(root)
	if candidate == base then return true end
	if base == "/" then return candidate:sub(1, 1) == "/" end
	return candidate:sub(1, #base + 1) == base .. "/"
end

local function collect(cx)
	local view = {
		hosts = cx.hosts:list(),
		sessions = cx.sessions:list(),
		tabs = cx.session:tabs(),
		panes = cx.session:panes(),
		agents = cx.agents:list(),
		byHostId = {},
		byHostKey = {},
		bySession = {},
		byTab = {},
		byPane = {},
		hostByPane = {},
	}
	for _, host in view.hosts do
		view.byHostId[host.id] = host
		view.byHostKey[hostKey(host)] = host
		if host.current then view.currentHost = host end
		for _, pane in host.panes do view.hostByPane[pane] = host end
	end
	for _, session in view.sessions do view.bySession[session.id] = session end
	for _, tab in view.tabs do view.byTab[tab.id] = tab end
	for _, pane in view.panes do
		view.byPane[pane.pane] = pane
		if not view.hostByPane[pane.pane] and pane.tab then
			local tab = view.byTab[pane.tab]
			local session = tab and view.bySession[tab.session]
			if session then view.hostByPane[pane.pane] = view.byHostId[session.host] end
		end
	end
	if not view.currentHost then view.currentHost = cx.hosts:current() end
	return view
end

local function findFirst(tree, view, except)
	if not tree then return nil end
	if tree.pane then
		local pane = view.byPane[tree.pane]
		if tree.pane ~= except and pane and pane.block ~= SIDEBAR then return tree.pane end
		return nil
	end
	return findFirst(tree[1], view, except) or findFirst(tree[2], view, except)
end

local function firstLeaf(tree)
	if not tree then return nil end
	if tree.pane then return tree.pane end
	return firstLeaf(tree[1]) or firstLeaf(tree[2])
end

local function sidebarShare(tree, pane, extent)
	if not tree or tree.pane then return nil end
	extent = extent or 1
	if tree.split == "right" and tree[1] and tree[1].pane == pane then return tree.ratio, extent, firstLeaf(tree[2]) end
	local left = if tree.split == "right" then extent * tree.ratio else extent
	local right = if tree.split == "right" then extent * (1 - tree.ratio) else extent
	local ratio, parent, neighbor = sidebarShare(tree[1], pane, left)
	if ratio then return ratio, parent, neighbor end
	return sidebarShare(tree[2], pane, right)
end

local function resizeSidebar(cx, tab, pane)
	local layout = cx.session:layout(tab)
	if not layout then return false end
	local before, _, neighbor = sidebarShare(layout.root, pane)
	if not before or not neighbor then return false end
	local probe = 1
	if not cx.layout:resize(neighbor, "left", probe) then
		probe = -1
		if not cx.layout:resize(neighbor, "left", probe) then return false end
	end
	layout = cx.session:layout(tab)
	local current = layout and sidebarShare(layout.root, pane)
	if not current or current == before then return false end
	local perCell = (current - before) / probe
	local want = columns * math.abs(perCell)
	for _ = 1, 8 do
		local step = math.floor((want - current) / perCell + 0.5)
		if step == 0 then return true end
		if not cx.layout:resize(neighbor, "left", step) then return true end
		layout = cx.session:layout(tab)
		local after = layout and sidebarShare(layout.root, pane)
		if not after then return false end
		if after == current then return true end
		perCell = (after - current) / step
		current = after
	end
	return math.floor((want - current) / perCell + 0.5) == 0
end

local function rememberWidth(width)
	if type(width) ~= "number" or width < 1 or width > 500 then return end
	local value = math.clamp(math.floor(width + 0.5), 20, 120)
	if value == columns then return end
	columns = value
	if widthSavePending then return end
	widthSavePending = true
	tern.timer(400, function()
		widthSavePending = false
		tern.kv.set("window.sidebar-columns", columns)
	end)
end

local function observeWidth(cx, record, width)
	if not record.sizedTab or not record.pane or not record.widthShare
		or type(width) ~= "number" or width < 1 or width > 500 then return end
	local layout = cx.session:layout(record.sizedTab)
	if not layout then return end
	local ratio, parent = sidebarShare(layout.root, record.pane)
	if not ratio then return end
	local share = ratio * parent
	if math.abs(share - record.widthShare) > 0.0000001 then
		record.widthColumns = record.widthColumns * share / record.widthShare
		record.widthShare = share
		record.adjustingWidth = false
		rememberWidth(record.widthColumns)
	else
		record.widthColumns = width
	end
	if width < 20 and not record.adjustingWidth then
		record.adjustingWidth = true
		record.widthTarget = 20
		record.widthCorrections = 0
	end
	if record.adjustingWidth then
		local step = record.widthTarget - width
		if (math.abs(step) <= 1 and width >= 20) or record.widthCorrections >= 4
			or not cx.layout:resize(record.pane, "right", step) then
			record.adjustingWidth = false
			return
		end
		record.widthCorrections += 1
		layout = cx.session:layout(record.sizedTab)
		if layout then
			local updated, extent = sidebarShare(layout.root, record.pane)
			if updated then record.widthShare = updated * extent end
		end
	end
end

local function reportOnce(cx, key, message)
	if missingReported[key] == message then return end
	missingReported[key] = message
	cx:toast("error", "Workspace Rail", message)
end

local function availableBlock(cx, kind)
	for _, block in cx.session:block_types() do
		if block.kind == kind then return true end
	end
	return false
end

local function openSidebar(cx, host, key, target, tab, record)
	if not availableBlock(cx, SIDEBAR) then
		reportOnce(cx, key, "The Workspace Rail host block is unavailable on " .. host.name .. ". Install and enable the plugin on that host.")
		return
	end
	local args = tern.json.encode({ hostKey = key, hostName = host.name })
	local ok, pane = pcall(function()
		return cx.layout:split(target, "left", { block = SIDEBAR, args = { args } }, { focus = false })
	end)
	if not ok or not pane then
		reportOnce(cx, key, "Could not open the Workspace Rail host block on " .. host.name .. ": " .. tostring(if ok then "block unavailable" else pane))
		return
	end
	record.pane = pane
	record.lastTab = tab
	record.openedAt = tern.now()
	record.sizedTab = nil
	missingReported[key] = nil
end

local function follow(cx, view)
	if not enabled then return end
	local host = view.currentHost
	if not host then return end
	local key = hostKey(host)
	if host.state ~= "connected" then
		activeHost = nil
		reportOnce(cx, key, "Host " .. host.name .. " is not connected (" .. host.state .. ").")
		return
	end
	local focused = cx.session:focused()
	local tab = focused and cx.session:tab_of(focused)
	local layout = tab and cx.session:layout(tab)
	if not tab or not layout then return end

	local record = panels[key]
	if not record then
		record = {}
		panels[key] = record
	end
	if activeHost ~= key then
		activeHost = key
		record.sizedTab = nil
	end
	local present = record.pane and view.byPane[record.pane]
	if present then
		local owner = view.hostByPane[present.pane]
		if (present.block and present.block ~= SIDEBAR) or (owner and hostKey(owner) ~= key) then
			record.pane = nil
			record.sizedTab = nil
			present = nil
		end
	end
	local preferred
	for _, pane in view.panes do
		local owner = view.hostByPane[pane.pane]
		if pane.block == SIDEBAR and owner and hostKey(owner) == key then
			if not preferred or pane.tab == tab then preferred = pane end
			if pane.tab == tab then break end
		end
	end
	if preferred and (not present or preferred.tab == tab) then
		if record.pane ~= preferred.pane then record.sizedTab = nil end
		record.pane = preferred.pane
		present = preferred
	end
	if record.pane and not present and record.openedAt and tern.now() - record.openedAt < 2000 then return end
	if record.pane and not present then
		sent[record.pane] = nil
		sentAt[record.pane] = nil
		record.pane = nil
		record.sizedTab = nil
	end

	local target = findFirst(layout.root, view, record.pane)
	if not target then
		if present and present.tab == tab and not present.parked then
			local ok, parked, err = pcall(function() return cx.layout:park(record.pane) end)
			if not ok or not parked then reportOnce(cx, key, tostring(if ok then err else parked)) end
		end
		return
	end

	if not record.pane then
		openSidebar(cx, host, key, target, tab, record)
		return
	end

	local moved = false
	if present.parked then
		local ok, success = pcall(function() return cx.layout:unpark(record.pane, { focus = false }) end)
		if not ok or not success then
			if not availableBlock(cx, SIDEBAR) then
				reportOnce(cx, key, "The Workspace Rail host block is unavailable on " .. host.name .. ". Install and enable the plugin on that host.")
				return
			end
			local old = record.pane
			record.pane = nil
			record.lastTab = nil
			local closed, closeError = pcall(function() cx.layout:close(old) end)
			if not closed then
				record.pane = old
				reportOnce(cx, key, "Could not restore the sidebar: " .. tostring(closeError))
				return
			end
			sent[old] = nil
			sentAt[old] = nil
			openSidebar(cx, host, key, target, tab, record)
			return
		end
		moved = true
	elseif present.tab ~= tab then
		local ok, success, err = pcall(function() return cx.layout:move_to_tab(record.pane, tab, { focus = false }) end)
		if not ok or not success then
			reportOnce(cx, key, "Could not move the sidebar: " .. tostring(if ok then err else success))
			return
		end
		moved = true
	end
	if moved then
		layout = cx.session:layout(tab) or layout
		record.sizedTab = nil
	end
	if firstLeaf(layout.root) ~= record.pane then
		local ok, success = pcall(function() return cx.layout:move(record.pane, target, "left", { focus = false }) end)
		if not ok or not success then
			reportOnce(cx, key, "Could not place the sidebar on " .. host.name .. ".")
			return
		end
		record.sizedTab = nil
	end
	record.lastTab = tab
	missingReported[key] = nil
	if record.sizedTab ~= tab then
		if resizeSidebar(cx, tab, record.pane) then
			layout = cx.session:layout(tab)
			if layout then
				local ratio, parent = sidebarShare(layout.root, record.pane)
				if ratio then
					record.widthShare = ratio * parent
					record.sizedTab = tab
					record.adjustingWidth = true
					record.widthTarget = columns
					record.widthColumns = columns
					record.widthCorrections = 0
					record.openedAt = nil
				end
			end
		end
	end
end

local function makeSnapshot(cx, view)
	local current = view.currentHost
	local activePath
	local focused = cx.session:focused()
	local focusedPane = focused and view.byPane[focused]
	if focusedPane and focusedPane.tab and focusedPane.block ~= SIDEBAR and focusedPane.block ~= WIZARD
		and focusedPane.cwd and focusedPane.cwd ~= "" then
		lastPaths[focusedPane.tab] = focusedPane.cwd
		activePath = focusedPane.cwd
	elseif focusedPane and focusedPane.tab then
		activePath = lastPaths[focusedPane.tab]
	end

	local cwdBySession = {}
	for _, pane in view.panes do
		if pane.tab and pane.block ~= SIDEBAR and pane.block ~= WIZARD and pane.cwd and pane.cwd ~= "" then
			local tab = view.byTab[pane.tab]
			if tab and (not cwdBySession[tab.session] or pane.pane == focused) then
				cwdBySession[tab.session] = pane.cwd
			end
			if focusedPane and pane.tab == focusedPane.tab and not activePath then activePath = pane.cwd end
		end
	end

	local sessions = tern.json.array()
	for _, session in view.sessions do
		local host = view.byHostId[session.host]
		if host then
			table.insert(sessions, {
				id = session.id, name = session.name, hostKey = hostKey(host), cwd = cwdBySession[session.id] or "",
			})
		end
	end
	local agents = tern.json.array()
	for _, agent in view.agents do
		local host = view.hostByPane[agent.pane]
		if host then
			table.insert(agents, { hostKey = hostKey(host), cwd = agent.cwd, state = agent.state })
		end
	end
	local entries = tern.json.array()
	local seen = {}
	for _, host in view.hosts do
		local key = hostKey(host)
		seen[key] = true
		local cached = catalogs[key]
		table.insert(entries, { host = hostInfo(host), projects = if cached then cached.projects else tern.json.array(), cached = cached ~= nil })
	end
	for key, cached in catalogs do
		if not seen[key] then
			table.insert(entries, {
				host = { key = key, name = cached.name or key, state = "offline" },
				projects = cached.projects, cached = true,
			})
		end
	end
	table.sort(entries, function(a, b) return a.host.key < b.host.key end)
	return {
		host = hostInfo(current), activePath = activePath,
		sessions = sessions, agents = agents, catalogs = entries, windowKey = cx:window_key(),
	}
end

local function sync(cx, view)
	if not view.currentHost then return end
	local snapshot = makeSnapshot(cx, view)
	local encoded = tern.json.encode(snapshot)
	local focused = cx.session:focused()
	local activeTab = focused and cx.session:tab_of(focused)
	local now = tern.now()
	for _, pane in view.panes do
		local host = view.hostByPane[pane.pane]
		if host and host.state == "connected" and (pane.block == SIDEBAR or pane.block == WIZARD) then
			local token, fresh = sourceFor(pane.pane, pane.block, host)
			local retry = host.id == view.currentHost.id and pane.tab == activeTab
				and now - (sentAt[pane.pane] or 0) >= 5000
			if pane.block == SIDEBAR and (fresh or sent[pane.pane] ~= encoded or retry) then
				snapshot.sourceToken = token
				local payload = tern.json.encode(snapshot)
				snapshot.sourceToken = nil
				local ok = pcall(function()
					cx.session:event(pane.pane, { ev = "action", id = BRIDGE, act = "sync", value = payload })
				end)
				if ok then
					sent[pane.pane] = encoded
					sentAt[pane.pane] = now
				end
			elseif pane.block == WIZARD and (fresh or retry) then
				local payload = tern.json.encode({ windowKey = cx:window_key(), sourceToken = token })
				local ok = pcall(function()
					cx.session:event(pane.pane, { ev = "action", id = "main", act = "bind", value = payload })
				end)
				if ok then sentAt[pane.pane] = now end
			end
		end
	end
end

local function hideSidebars(cx, view)
	for _, pane in view.panes do
		if pane.block == SIDEBAR and not pane.parked then
			local ok, success, err = pcall(function() return cx.layout:park(pane.pane) end)
			if not ok or not success then
				reportOnce(cx, "hide:" .. tostring(pane.pane), "Could not hide the sidebar: " .. tostring(if ok then err else success))
			end
		end
	end
end

local function refresh(cx)
	enabled = tern.kv.get("window.sidebar-enabled") ~= false
	local view = collect(cx)
	if enabled then follow(cx, view) else hideSidebars(cx, view) end
	sync(cx, collect(cx))
end

local function scheduleRefresh()
	if refreshPending then return end
	refreshPending = true
	tern.timer(50, function(cx)
		refreshPending = false
		if cx then refresh(cx) end
	end)
end

local function refreshHost(cx, key)
	local view = collect(cx)
	for _, pane in view.panes do
		local host = view.hostByPane[pane.pane]
		if pane.block == SIDEBAR and host and hostKey(host) == key then
			pcall(function() cx.session:event(pane.pane, { ev = "action", id = BRIDGE, act = "refresh" }) end)
		end
	end
	scheduleRefresh()
end

local function switchHost(cx, key)
	local view = collect(cx)
	local host = view.byHostKey[key]
	if not host then
		cx:toast("error", "Workspace Rail", "Host " .. key .. " is offline or no longer attached.")
		return nil
	end
	if host.state ~= "connected" then
		cx:toast("error", "Workspace Rail", "Host " .. host.name .. " is not connected (" .. host.state .. ").")
		return nil
	end
	if not view.currentHost or view.currentHost.id ~= host.id then
		local ok, err = pcall(function() cx.hosts:switch(host.id) end)
		if not ok then
			cx:toast("error", "Workspace Rail", "Could not switch host: " .. tostring(err))
			return nil
		end
	end
	return host
end

local function requireBlock(cx, host, kind)
	if availableBlock(cx, kind) then return true end
	cx:toast("error", "Workspace Rail", "The " .. kind .. " host block is unavailable on " .. host.name .. ". Install and enable the plugin on that host.")
	return false
end

local function openWizard(cx, key, mode, project, worktree)
	if mode ~= "add" and mode ~= "worktree" and mode ~= "delete" then
		cx:toast("error", "Workspace Rail", "Invalid project wizard mode.")
		return
	end
	local host = switchHost(cx, key)
	if not host or not requireBlock(cx, host, WIZARD) then return end
	local token = newSourceToken()
	local args = tern.json.encode({
		mode = mode, hostKey = key, hostName = host.name, project = project, worktree = worktree,
		windowKey = cx:window_key(), sourceToken = token,
	})
	local ok, pane = pcall(function() return cx:new_block(WIZARD, { args }, "tab", { focus = true }) end)
	if not ok or not pane then
		cx:toast("error", "Workspace Rail", "Could not open the project wizard on " .. host.name .. ": " .. tostring(if ok then "host block unavailable" else pane))
	else
		registerSource(pane, WIZARD, key, token)
	end
	scheduleRefresh()
end

local function openPath(cx, key, path, name)
	if not absolutePath(path) then
		cx:toast("error", "Workspace Rail", "The workspace path is not absolute.")
		return
	end
	local host = switchHost(cx, key)
	if not host or not requireBlock(cx, host, SIDEBAR) then return end
	local view = collect(cx)
	local normalized = pathKey(path)
	local bindingKey = key .. "\n" .. normalized
	local bound = bindings[bindingKey]
	local match, nested
	for _, pane in view.panes do
		local owner = view.hostByPane[pane.pane]
		local tab = pane.tab and view.byTab[pane.tab]
		if owner and owner.id == host.id and tab and (pane.kind == "terminal" or pane.kind == "agent")
			and pane.cwd and pane.cwd ~= "" then
			if pathKey(pane.cwd) == normalized then
				match = { session = tab.session, pane = pane.pane }
				break
			elseif tab.session == bound and inside(pane.cwd, path) then
				nested = { session = tab.session, pane = pane.pane }
			end
		end
	end
	match = match or nested
	local recent = recentSessions[bindingKey]
	if not match and recent and tern.now() - recent.createdAt < 3000 then
		local session = view.bySession[recent.id]
		if session and session.host == host.id then
			local ok, err = pcall(function() cx.sessions:switch(session.id) end)
			if not ok then
				cx:toast("error", "Workspace Rail", "Could not switch to the workspace session: " .. tostring(err))
				return false
			end
			local current = cx.sessions:current()
			if not current or current.id ~= session.id then
				cx:toast("error", "Workspace Rail", "Could not show the workspace session.")
				return false
			end
			scheduleRefresh()
			return true
		end
	end
	local targetSession, targetPane
	if match then
		local ok, err = pcall(function()
			cx.sessions:switch(match.session)
			cx.layout:focus(match.pane)
		end)
		if not ok then
			cx:toast("error", "Workspace Rail", "Could not switch to the workspace session: " .. tostring(err))
			return
		end
		targetSession, targetPane = match.session, match.pane
	else
		local title = if type(name) == "string" and name ~= "" then name else path
		local ok, session = pcall(function() return cx.sessions:create({ name = title, cwd = path }) end)
		if not ok then
			cx:toast("error", "Workspace Rail", "Could not create a workspace session: " .. tostring(session))
			return
		end
		targetSession = session.id
		recentSessions[bindingKey] = { id = session.id, createdAt = tern.now() }
	end
	local current = cx.sessions:current()
	if not current or current.id ~= targetSession or (targetPane and cx.session:focused() ~= targetPane) then
		cx:toast("error", "Workspace Rail", "Could not show the workspace session or focus its pane.")
		scheduleRefresh()
		return false
	end
	bindings[bindingKey] = targetSession
	tern.kv.set("window.session-bindings", bindings)
	scheduleRefresh()
	return true
end

local function pickHost(cx, data, source)
	local view = collect(cx)
	local items = tern.json.array()
	for _, host in view.hosts do
		table.insert(items, {
			label = host.name, detail = (host.address or "local") .. " · " .. host.state,
			current = host.current, key = hostKey(host),
		})
	end
	if #items == 0 then
		cx:toast("error", "Workspace Rail", "No Tern hosts are available.")
		return
	end
	cx:pick({ items = items, placeholder = "Choose a Tern host", action = "select host" }):next(function(item, err, nextCx)
		if not nextCx then return end
		if err then
			nextCx:toast("error", "Workspace Rail", "Could not choose a host: " .. err)
			return
		end
		if not item then return end
		local key = item.key
		if not data.mode then
			if switchHost(nextCx, key) then scheduleRefresh() end
			return
		end
		local project, worktree = data.project, data.worktree
		if project and source and hostKey(source) ~= key then
			local selectedProject, selectedWorktree
			local cached = catalogs[key]
			if cached then
				for _, entry in cached.projects do
					if entry.project.id == project.id and entry.project.kind == project.kind then
						selectedProject = entry.project
						if worktree then
							for _, candidate in entry.worktrees do
								if candidate.path == worktree.path then
									selectedWorktree = candidate
									break
								end
							end
						end
						break
					end
				end
			end
			if not selectedProject or (worktree and not selectedWorktree) then
				nextCx:toast("error", "Workspace Rail", "That project or worktree is not registered on the selected host. Choose a project from that host's sidebar.")
				return
			end
			project, worktree = selectedProject, selectedWorktree
		end
		openWizard(nextCx, key, data.mode, project, worktree)
	end)
end

local function decodeLink(url)
	local action, encoded = url:match("^workspace%-rail://([%w%-]+)%?data=(.*)$")
	if not action then return nil, nil end
	local json = encoded:gsub("%%(%x%x)", function(hex) return string.char(assert(tonumber(hex, 16))) end)
	local ok, data = pcall(tern.json.decode, json)
	if not ok or type(data) ~= "table" then return action, nil end
	return action, data
end

tern.route.link(function(link, cx)
	if not link.url:match("^workspace%-rail://") then return nil end
	local action, data = decodeLink(link.url)
	if not action or not data then
		cx:toast("error", "Workspace Rail", "The workspace request is invalid.")
		return { handled = true }
	end
	if data.windowKey ~= nil and data.windowKey ~= cx:window_key() then return { handled = true } end
	local view = collect(cx)
	local source
	if data.sourceToken ~= nil then
		source = if type(data.sourceToken) == "string" then sources[data.sourceToken] else nil
		if not source or data.windowKey ~= cx:window_key() then return { handled = true } end
	elseif action == "catalog" or action == "opened" then
		return { handled = true }
	end
	local sourcePane = if source then source.pane else link.pane
	local pane = view.byPane[sourcePane]
	if not pane or (pane.block ~= SIDEBAR and pane.block ~= WIZARD) then return { handled = true } end
	local host = view.hostByPane[sourcePane]
	if not host then
		cx:toast("error", "Workspace Rail", "Could not identify the host of the requesting pane.")
		return { handled = true }
	end
	if source and (pane.block ~= source.block or hostKey(host) ~= source.hostKey or host.state ~= "connected") then
		return { handled = true }
	end
	if action == "catalog" and pane.block == SIDEBAR then
		if type(data.projects) == "table" then
			local key = hostKey(host)
			local entry = { name = host.name, projects = data.projects }
			if not catalogs[key] or tern.json.encode(catalogs[key]) ~= tern.json.encode(entry) then
				catalogs[key] = entry
				tern.kv.set("window.catalogs", catalogs)
			end
			local record = panels[key]
			local focused = cx.session:focused()
			local activeTab = focused and cx.session:tab_of(focused)
			if data.resized == true and record and record.pane == pane.pane
				and activeTab and pane.tab == activeTab and record.sizedTab == activeTab then
				observeWidth(cx, record, data.width)
			end
			sync(cx, view)
		end
	elseif action == "opened" and pane.block == WIZARD then
		if data.windowKey == cx:window_key() then
			refreshHost(cx, hostKey(host))
			if openPath(cx, hostKey(host), data.path, data.name) and data.keepWizard ~= true then
				local wizard = cx.session:pane(pane.pane)
				if wizard and wizard.block == WIZARD then
					local ok, err = pcall(function() cx.layout:close(pane.pane) end)
					if not ok then cx:toast("error", "Workspace Rail", "Could not close the project wizard: " .. tostring(err)) end
				end
			end
		end
	elseif action == "open" and pane.block == SIDEBAR then
		if type(data.hostKey) == "string" then openPath(cx, data.hostKey, data.path, data.name) end
	elseif action == "wizard" and pane.block == SIDEBAR then
		if type(data.hostKey) == "string" then openWizard(cx, data.hostKey, data.mode, data.project, data.worktree) end
	elseif action == "hosts" then
		pickHost(cx, data, host)
	elseif action == "activity" then
		if pane.block == WIZARD then
			refreshHost(cx, hostKey(host))
		else
			cx:command("inbox")
		end
	end
	return { handled = true }
end)

tern.command({
	id = "toggle_sidebar",
	title = "Workspace Rail: Toggle Sidebar",
	run = function(cx)
		enabled = tern.kv.get("window.sidebar-enabled") == false
		tern.kv.set("window.sidebar-enabled", enabled)
		missingReported = {}
		if not enabled then
			hideSidebars(cx, collect(cx))
		else
			refresh(cx)
		end
	end,
})

tern.command({
	id = "add_project",
	title = "Workspace Rail: Add Project",
	keys = { "ctrl+alt+shift+a" },
	run = function(cx)
		local host = cx.hosts:current()
		openWizard(cx, hostKey(host), "add")
	end,
})

tern.on("window_start", function(_cx) scheduleRefresh() end)
tern.on("focus", function(_ev, _cx) scheduleRefresh() end)
for _, event in { "pane_created", "tab_created", "tab_closed", "cwd", "title", "agent_state", "agent_finished", "command_started", "command_finished" } do
	tern.on(event, function(_ev, _cx) scheduleRefresh() end)
end
tern.on("pane_closed", function(ev, cx)
	sent[ev.pane] = nil
	sentAt[ev.pane] = nil
	local token = sourceByPane[ev.pane]
	if token then
		sources[token] = nil
		sourceByPane[ev.pane] = nil
	end
	if enabled then
		local view = collect(cx)
		for _, record in panels do
			if record.pane == ev.pane then
				if record.lastTab and view.byTab[record.lastTab] then
					enabled = false
					tern.kv.set("window.sidebar-enabled", false)
					hideSidebars(cx, view)
				end
				record.pane = nil
				record.sizedTab = nil
			end
		end
	end
	scheduleRefresh()
end)

local function tick(cx)
	if cx then refresh(cx) end
	tern.timer(1000, tick)
end
tern.timer(0, tick)
