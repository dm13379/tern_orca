local ui = tern.ui
local repository = require("./repository")

local REFRESH_MS = 15000

local function encodedLink(action, data)
	local json = tern.json.encode(data)
	local encoded = string.gsub(json, "([^%w%-%._~])", function(byte)
		return string.format("%%%02X", string.byte(byte))
	end)
	return "workspace-rail://" .. action .. "?data=" .. encoded
end

local function paneExists(pane)
	for _, item in ipairs(tern.pane.list()) do
		if item.pane == pane then
			return true
		end
	end
	return false
end

local function stableKey(state, identity, prefix)
	local key = state.keys[identity]
	if not key then
		state.nextKey += 1
		key = prefix .. tostring(state.nextKey)
		state.keys[identity] = key
	end
	return key
end

local function rowIdentity(hostKey, projectId, path)
	return hostKey .. "\0" .. projectId .. "\0" .. path
end

local function normalizePath(path)
	local value = path
	if path:match("^%a:[/\\]") or path:sub(1, 2) == "\\\\" or path:sub(1, 2) == "//" then
		value = string.lower((string.gsub(path, "\\", "/")))
	end
	if value ~= "/" then
		value = string.gsub(value, "/+$", "")
	end
	return value
end

local function containsPath(root, path)
	if root == "/" then
		return path:sub(1, 1) == "/"
	end
	return path == root or path:sub(1, #root + 1) == root .. "/"
end

local function ownCatalog(state)
	local host = state.host
	local snapshot = state.snapshot
	if snapshot then
		local found = false
		for _, catalog in ipairs(snapshot.catalogs or {}) do
			if catalog.host.key == host.key then
				host = catalog.host
				found = true
				break
			end
		end
		if snapshot.host and snapshot.host.key == host.key then
			host = snapshot.host
			found = true
		end
		if not found then
			host = { key = host.key, name = host.name, state = "offline" }
		end
	end
	return { host = host, projects = state.entries }
end

local function catalogs(state)
	local result = { ownCatalog(state) }
	if state.snapshot then
		for _, catalog in ipairs(state.snapshot.catalogs or {}) do
			if catalog.host.key ~= state.host.key then
				table.insert(result, catalog)
			end
		end
	end
	return result
end

local function model(state)
	local hosts = catalogs(state)
	local allRows = {}
	local online = {}
	for _, catalog in ipairs(hosts) do
		online[catalog.host.key] = catalog.host.state == "connected"
		for _, entry in ipairs(catalog.projects) do
			for _, worktree in ipairs(entry.worktrees) do
				table.insert(allRows, {
					host = catalog.host,
					project = entry.project,
					worktree = worktree,
					identity = rowIdentity(catalog.host.key, entry.project.id, worktree.path),
					root = normalizePath(worktree.path),
					working = 0,
					waiting = 0,
					idle = 0,
					sessions = 0,
				})
			end
		end
	end
	local snapshot = state.snapshot
	if snapshot and snapshot.host then
		online[snapshot.host.key] = snapshot.host.state == "connected"
	end
	local function owner(hostKey, cwd)
		if type(cwd) ~= "string" or cwd == "" then
			return nil
		end
		local path = normalizePath(cwd)
		local best = nil
		for _, row in ipairs(allRows) do
			if row.host.key == hostKey and containsPath(row.root, path)
				and (not best or #row.root > #best.root) then
				best = row
			end
		end
		return best
	end
	local working, waiting = 0, 0
	if snapshot then
		for _, agent in ipairs(snapshot.agents or {}) do
			if online[agent.hostKey] then
				local row = owner(agent.hostKey, agent.cwd)
				if agent.state == "working" then
					working += 1
					if row then row.working += 1 end
				elseif agent.state == "waiting_input" then
					waiting += 1
					if row then row.waiting += 1 end
				elseif agent.state == "idle" and row then
					row.idle += 1
				end
			end
		end
		for _, session in ipairs(snapshot.sessions or {}) do
			if online[session.hostKey] then
				local row = owner(session.hostKey, session.cwd)
				if row then row.sessions += 1 end
			end
		end
		if snapshot.host and snapshot.activePath then
			local active = owner(snapshot.host.key, snapshot.activePath)
			if active then active.active = true end
		end
	end

	local rowsById = {}
	for _, row in ipairs(allRows) do
		rowsById[row.identity] = row
	end
	local query = string.lower(state.filter:match("^%s*(.-)%s*$"))
	local shownHosts, shownRows = {}, {}
	for _, catalog in ipairs(hosts) do
		local hostMatch = query ~= "" and string.find(string.lower(catalog.host.name), query, 1, true) ~= nil
		local shownProjects = {}
		for _, entry in ipairs(catalog.projects) do
			local project = entry.project
			local projectMatch = query == "" or hostMatch
				or string.find(string.lower(project.name), query, 1, true) ~= nil
				or string.find(string.lower(project.path), query, 1, true) ~= nil
			local rows = {}
			for _, worktree in ipairs(entry.worktrees) do
				local matches = projectMatch
					or string.find(string.lower(worktree.name), query, 1, true) ~= nil
					or string.find(string.lower(worktree.path), query, 1, true) ~= nil
					or (worktree.branch and string.find(string.lower(worktree.branch), query, 1, true) ~= nil)
				if matches then
					local row = rowsById[rowIdentity(catalog.host.key, project.id, worktree.path)]
					table.insert(rows, row)
					table.insert(shownRows, row)
				end
			end
			if projectMatch or #rows > 0 then
				table.insert(shownProjects, { entry = entry, rows = rows })
			end
		end
		if query == "" or hostMatch or #shownProjects > 0 then
			table.insert(shownHosts, { host = catalog.host, projects = shownProjects })
		end
	end
	return { hosts = shownHosts, rows = shownRows, working = working, waiting = waiting }
end

local function publish(state, cx, reconcile)
	if reconcile then state.reconcile = true end
	local snapshot = state.snapshot
	if not snapshot or type(snapshot.sourceToken) ~= "string" or type(snapshot.windowKey) ~= "string" then
		return
	end
	if not state.loaded or state.fetching or not paneExists(cx.pane) then
		return
	end
	local projects = tern.json.array()
	for _, entry in ipairs(state.entries) do
		local worktrees = tern.json.array()
		for _, worktree in ipairs(entry.worktrees) do
			table.insert(worktrees, worktree)
		end
		table.insert(projects, { project = entry.project, worktrees = worktrees })
	end
	local catalog = tern.json.encode(projects)
	local fingerprint = tern.json.encode(tern.json.array({ catalog, cx.cols }))
	local missing = false
	if state.reconcile and state.snapshot then
		missing = true
		for _, cached in ipairs(state.snapshot.catalogs or {}) do
			if cached.host.key == state.host.key then
				missing = not cached.cached or tern.json.encode(cached.projects) ~= catalog
				break
			end
		end
	end
	state.reconcile = false
	if fingerprint ~= state.published or missing or state.pendingResize then
		state.published = fingerprint
		local resized = state.pendingResize == true
		state.pendingResize = false
		cx:open(encodedLink("catalog", {
			projects = projects, width = cx.cols, resized = resized,
			windowKey = snapshot.windowKey, sourceToken = snapshot.sourceToken,
		}))
	end
end

local function refresh(state, cx)
	if state.fetching then
		state.refreshAgain = true
		return
	end
	state.fetching = true
	state.loadError = nil
	local ok, projects = pcall(repository.projects)
	if not ok then
		state.fetching = false
		state.loadError = tostring(projects)
		cx:render()
		return
	end
	local previous = {}
	for _, entry in ipairs(state.entries) do
		previous[entry.project.id] = entry
	end
	local entries = {}
	for _, project in ipairs(projects) do
		local old = previous[project.id]
		table.insert(entries, {
			project = project,
			worktrees = if old then old.worktrees else tern.json.array(),
			loading = true,
		})
	end
	state.entries = entries
	cx:render()
	local index = 0
	local function nextProject()
		if not paneExists(cx.pane) then
			return
		end
		index += 1
		local entry = entries[index]
		if not entry then
			state.fetching = false
			state.loaded = true
			publish(state, cx)
			cx:render()
			if state.refreshAgain then
				state.refreshAgain = false
				refresh(state, cx)
			end
			return
		end
		local completed = false
		local function done(worktrees, err)
			if completed then return end
			completed = true
			if not paneExists(cx.pane) then return end
			entry.loading = false
			if err then
				entry.loadError = tostring(err)
			else
				entry.worktrees = tern.json.array(worktrees or {})
			end
			cx:render()
			nextProject()
		end
		local started, err = pcall(repository.worktrees, entry.project, done)
		if not started then
			done(nil, tostring(err))
		end
	end
	nextProject()
end

local function button(key, class, label, title, href)
	return ui.el("button", {
		key = key, class = class, text = label, title = title, aria = title,
		href = href, actions = { click = "open" },
	})
end

local function rowStatus(row, observed)
	if row.host.state ~= "connected" then
		return "主机离线 · 状态未知", "offline"
	elseif not observed then
		return "Agent 状态未知", "unknown"
	end
	local details = {}
	if row.working > 0 then table.insert(details, tostring(row.working) .. " 个 Agent 工作中") end
	if row.waiting > 0 then table.insert(details, tostring(row.waiting) .. " 个 Agent 等待输入") end
	if row.idle > 0 then table.insert(details, tostring(row.idle) .. " 个 Agent 休眠") end
	if row.sessions > 0 then table.insert(details, tostring(row.sessions) .. " 个会话已打开") end
	if #details == 0 then
		return "未检测到 Agent 或打开的会话", "none"
	end
	local class = if row.working > 0 then "working" elseif row.waiting > 0 then "waiting"
		elseif row.idle > 0 then "idle" else "session"
	return table.concat(details, " · "), class
end

local function projectMark(project, iconOnly)
	local children = {
		ui.el("span", { key = "folder", class = "wr-project-folder" }),
	}
	if not iconOnly then
		table.insert(children, ui.el("span", { key = "name", class = "wr-project-name", text = project.name }))
	end
	return ui.el("span", { key = "project", class = "wr-project-mark", title = project.path }, children)
end

local function projectActions(host, project)
	local controls = {}
	if project.kind == "git" then
		table.insert(controls, button("new", "wr-project-action", "+", "为 " .. project.name .. " 新建工作树",
			encodedLink("wizard", { hostKey = host.key, mode = "worktree", project = project })))
	end
	table.insert(controls, button("remove", "wr-project-action", "−", "移除项目记录 " .. project.name,
		encodedLink("wizard", { hostKey = host.key, mode = "delete", project = project })))
	return controls
end

local function renderRow(state, row, showProjectActions)
	local project, worktree, host = row.project, row.worktree, row.host
	local rowNode = stableKey(state, "row\0" .. row.identity, "w")
	local status, statusClass = rowStatus(row, state.snapshot ~= nil)
	local branch = if worktree.branch and worktree.branch ~= "" then worktree.branch else worktree.name
	local title = host.name .. " · " .. project.name .. "\n" .. worktree.path .. "\n" .. status
	if worktree.branch and worktree.branch ~= "" then title ..= "\n分支: " .. worktree.branch end
	if worktree.name ~= branch then title ..= "\n工作树: " .. worktree.name end
	if worktree.locked then title ..= "\n工作树已锁定" end
	if worktree.missing then title ..= "\n目录不存在" end
	if worktree.unregistered then title ..= "\n工作树已注销，目录仍存在" end
	local statusNode
	if statusClass == "none" and project.kind == "git" then
		statusNode = ui.el("span", { key = "status", class = "wr-status wr-status-none", title = status }, {
			ui.el("span", { key = "branch", class = "wr-branch" }, {
				ui.el("span", { key = "fork", class = "wr-branch-fork" }),
			}),
		})
	else
		local symbol = if statusClass == "working" then "●" elseif statusClass == "waiting" then "!"
			elseif statusClass == "idle" then "☾" elseif statusClass == "session" then "◉"
			elseif statusClass == "offline" then "⊘" elseif statusClass == "unknown" then "?" else "○"
		statusNode = ui.el("span", { key = "status", class = "wr-status wr-status-" .. statusClass,
			text = symbol, title = status })
	end
	local labels = {
		statusNode,
		projectMark(project, branch == project.name),
		ui.el("span", { key = "name", class = "wr-worktree-name", text = branch }),
	}
	if worktree.main then
		table.insert(labels, ui.el("span", {
			key = "primary", class = "wr-primary", text = if project.kind == "git" then "主要" else "主目录",
		}))
	end
	if worktree.locked then
		table.insert(labels, ui.el("span", { key = "locked", class = "wr-tag", text = "已锁定" }))
	end
	if worktree.missing then
		table.insert(labels, ui.el("span", { key = "missing", class = "wr-tag wr-warning", text = "目录缺失" }))
	end
	if worktree.unregistered then
		table.insert(labels, ui.el("span", { key = "unregistered", class = "wr-tag wr-warning", text = "已注销" }))
	end
	local children = {
		ui.el("button", {
			key = "open", class = "wr-worktree", title = title, aria = title,
			href = encodedLink("open", { hostKey = host.key, path = worktree.path, name = worktree.name }),
			actions = { click = "open" },
		}, labels),
	}
	local controls = if showProjectActions then projectActions(host, project) else {}
	if project.kind == "git" and not worktree.main then
		local removeLink = encodedLink("wizard", { hostKey = host.key, mode = "delete", project = project, worktree = worktree })
		table.insert(controls, button("delete", "wr-row-action", "×", "删除工作树 " .. worktree.name, removeLink))
	end
	if #controls > 0 then
		table.insert(children, ui.el("div", { key = "actions", class = "wr-row-actions" }, controls))
	end
	local outer = {
		ui.el("div", { key = "line", class = "wr-worktree-line" }, children),
	}
	if worktree.error then
		local retryLink = encodedLink("wizard", { hostKey = host.key, mode = "delete", project = project, worktree = worktree })
		table.insert(outer, ui.el("div", { key = "failure", class = "wr-failure" }, {
			ui.el("div", { key = "heading", class = "wr-failure-heading" }, {
				ui.el("span", { key = "label", class = "wr-failure-title", text = "⚠︎ 删除失败" }),
				if project.kind == "git" and not worktree.main
					then button("retry", "wr-retry", "重试删除", "重试删除工作树 " .. worktree.name, retryLink)
					else ui.el("span", { key = "retry-placeholder", class = "wr-error-note", text = "请检查 Git 工作树状态" }),
			}),
			ui.el("div", { key = "message", class = "wr-failure-message", text = worktree.error }),
		}))
	end
	local class = "wr-row"
	if row.active then class ..= " wr-active" end
	if state.nav == row.identity then class ..= " wr-keyboard" end
	return ui.el("div", { key = rowNode, class = class }, outer)
end

local function renderProject(state, host, shown)
	local entry, rows = shown.entry, shown.rows
	local project = entry.project
	local projectNode = stableKey(state, "project\0" .. host.key .. "\0" .. project.id, "p")
	local actionRow = rows[1]
	for _, row in ipairs(rows) do
		if row.worktree.main then
			actionRow = row
			break
		end
	end
	local children = {}
	for _, row in ipairs(rows) do
		table.insert(children, renderRow(state, row, row == actionRow))
	end
	if #rows == 0 then
		local note = if entry.loading then "正在读取…" elseif entry.loadError then "读取失败" else "没有工作树"
		table.insert(children, ui.el("div", { key = "placeholder", class = "wr-project-placeholder" }, {
			projectMark(project, false),
			ui.el("span", { key = "note", class = "wr-placeholder-note", text = note }),
			ui.el("div", { key = "actions", class = "wr-placeholder-actions" }, projectActions(host, project)),
		}))
	end
	if not entry.loading and entry.loadError then
		table.insert(children, ui.el("div", { key = "load-error", class = "wr-load-error" }, {
			ui.el("div", { key = "label", class = "wr-failure-title", text = "无法读取工作树" }),
			ui.el("div", { key = "message", class = "wr-failure-message", text = entry.loadError }),
			ui.el("button", { key = "retry", class = "wr-retry", text = "重新读取", actions = { click = "refresh" } }),
		}))
	end
	return ui.el("section", { key = projectNode, class = "wr-project" }, children)
end

local function utf16Length(value)
	local length = 0
	for _, codepoint in utf8.codes(value) do
		length += if codepoint > 0xFFFF then 2 else 1
	end
	return length
end

local function byteOffsetAtUtf16(value, position)
	local units = 0
	for index, codepoint in utf8.codes(value) do
		local nextUnits = units + (if codepoint > 0xFFFF then 2 else 1)
		if nextUnits > position then
			return index - 1
		end
		units = nextUnits
	end
	return #value
end

local function focusFilter(state, cx)
	state.filtering = true
	cx:frame({ { "focus", "main.filter" } })
end

local function focusRows(state, cx)
	state.filtering = false
	cx:frame({ { "focus", tern.json.null } })
end

local function replaceSelection(state, value)
	local first = math.min(state.cursor, state.anchor or state.cursor)
	local last = math.max(state.cursor, state.anchor or state.cursor)
	state.filter = state.filter:sub(1, first) .. value .. state.filter:sub(last + 1)
	state.cursor = first + #value
	state.anchor = nil
	if first ~= last or value ~= "" then
		state.nav = nil
	end
end

local function selectedRow(state, view)
	for index, row in ipairs(view.rows) do
		if row.identity == state.nav then
			return row, index
		end
	end
	return nil, 0
end

return {
	features = { "edit" },
	init = function(cx, args, saved)
		local launch: { hostKey: string?, hostName: string? } = {}
		if args[1] then
			local ok, value = pcall(tern.json.decode, args[1])
			if ok and type(value) == "table" then
				if type(value.hostKey) == "string" then launch.hostKey = value.hostKey end
				if type(value.hostName) == "string" then launch.hostName = value.hostName end
			end
		end
		local savedState = if type(saved) == "table" then saved else {}
		local hostKey = launch.hostKey or (if type(savedState.hostKey) == "string" then savedState.hostKey else "local")
		local hostName = launch.hostName or (if type(savedState.hostName) == "string" then savedState.hostName
			elseif hostKey == "local" then "本机" else hostKey)
		local filter = if type(savedState.filter) == "string" then savedState.filter else ""
		local state = {
			host = { key = hostKey, name = hostName, state = "connected" },
			entries = {}, snapshot = nil, loaded = false, fetching = false, refreshAgain = false,
			published = nil, loadError = nil, keys = {}, nextKey = 0,
			filter = filter, cursor = #filter, anchor = nil, filtering = false, nav = nil,
		}
		local function tick()
			if not paneExists(cx.pane) then return end
			refresh(state, cx)
			tern.timer(REFRESH_MS, tick)
		end
		tern.timer(0, tick)
		return state
	end,

	title = function()
		return "工作区"
	end,

	view = function(state, _cx)
		local view = model(state)
		local host = ownCatalog(state).host
		local activity = if state.snapshot then "在线 " .. tostring(view.working) .. " 活跃" else "Agent 状态未知"
		if state.snapshot and view.waiting > 0 then activity ..= " · " .. tostring(view.waiting) .. " 等待" end
		local header = ui.el("header", { key = "header", class = "wr-header" }, {
			ui.el("div", { key = "top", class = "wr-heading-line" }, {
				ui.el("div", { key = "title", class = "wr-title", text = "工作区" }),
				button("add", "wr-add", "+", "添加项目", encodedLink("wizard", { hostKey = host.key, mode = "add" })),
				ui.el("button", { key = "refresh", class = "wr-icon-button", text = "↻", title = "刷新项目和工作树",
					aria = "刷新项目和工作树", actions = { click = "refresh" } }),
			}),
			ui.el("div", { key = "sub", class = "wr-heading-sub" }, {
				button("host", "wr-host-picker", host.name .. " ▾", "选择主机", encodedLink("hosts", {})),
				button("activity", "wr-activity", activity, "查看 Agent 活动", encodedLink("activity", {})),
			}),
		})
		local input = ui.node("input", {
			key = "filter", role = "workspace-rail.filter", text = state.filter,
			cursor = utf16Length(state.filter:sub(1, state.cursor)),
			anchor = if state.anchor then utf16Length(state.filter:sub(1, state.anchor)) else nil,
			placeholder = "搜索项目或工作树", aria = "搜索项目或工作树",
			prompt = { ui.span("⌕ ", "muted") },
		})
		local hostNodes, hostNames = {}, {}
		for _, shown in ipairs(view.hosts) do
			local name = shown.host.name
			hostNames[name] = (hostNames[name] or 0) + 1
		end
		for _, shown in ipairs(view.hosts) do
			local itemHost = shown.host
			local hostNode = stableKey(state, "host\0" .. itemHost.key, "h")
			local children = {}
			if #view.hosts > 1 or itemHost.key ~= host.key or itemHost.state ~= "connected" then
				local heading = if itemHost.state == "connected" then "已连接" else "离线 · 状态未知"
				local name = if hostNames[itemHost.name] > 1 then itemHost.key else itemHost.name
				table.insert(children, ui.el("div", { key = "header", class = "wr-host-heading" }, {
					ui.el("span", { key = "name", class = "wr-host-name", text = name, title = itemHost.name .. " · " .. itemHost.key }),
					ui.el("span", { key = "state", class = if itemHost.state == "connected" then "wr-host-state" else "wr-host-state wr-offline", text = heading }),
				}))
			end
			for _, project in ipairs(shown.projects) do
				table.insert(children, renderProject(state, itemHost, project))
			end
			if #shown.projects == 0 and state.filter == "" then
				local empty = if itemHost.key == state.host.key and state.fetching then "正在读取项目…" else "尚无项目"
				table.insert(children, ui.el("div", { key = "empty", class = "wr-empty-host", text = empty }))
			end
			table.insert(hostNodes, ui.el("section", { key = hostNode, class = "wr-host" }, children))
		end
		if state.loadError then
			table.insert(hostNodes, ui.el("div", { key = "catalog-error", class = "wr-load-error" }, {
				ui.el("div", { key = "title", class = "wr-failure-title", text = "无法读取项目" }),
				ui.el("div", { key = "message", class = "wr-failure-message", text = state.loadError }),
				ui.el("button", { key = "retry", class = "wr-retry", text = "重新读取", actions = { click = "refresh" } }),
			}))
		end
		if #view.hosts == 0 then
			table.insert(hostNodes, ui.el("div", { key = "no-matches", class = "wr-empty", text = "没有匹配的项目或工作树" }))
		end
		return { main = ui.node("col", { role = "workspace-rail.main" }, {
			header,
			input,
			ui.el("div", { key = "all", class = "wr-section-heading" }, {
				ui.el("span", { key = "icon", class = "wr-section-icon", text = "≡" }),
				ui.el("span", { key = "label", text = "全部" }),
			}),
			ui.el("div", { key = "bridge", hidden = true }),
			ui.el("div", { key = "list", class = "wr-list" }, hostNodes),
		}) }
	end,

	event = function(state, ev, cx)
		if ev.ev == "focus" and ev.id == "main.filter" then
			focusFilter(state, cx)
		elseif ev.ev == "edit" and ev.id == "main.filter" then
			if type(ev.from) ~= "number" or type(ev.to) ~= "number"
				or type(ev.cursor) ~= "number" or type(ev.text) ~= "string"
				or ev.len ~= utf16Length(state.filter) then
				return
			end
			state.anchor = byteOffsetAtUtf16(state.filter, ev.from)
			state.cursor = byteOffsetAtUtf16(state.filter, ev.to)
			replaceSelection(state, (string.gsub(ev.text, "[\r\n]", " ")))
			state.cursor = byteOffsetAtUtf16(state.filter, ev.cursor)
		elseif ev.ev == "action" and ev.act == "sync" and (ev.id == "main.bridge" or ev.id == "main") then
			local ok, snapshot = pcall(tern.json.decode, ev.value or "")
			if ok and type(snapshot) == "table" then
				state.snapshot = snapshot
				publish(state, cx, true)
			end
		elseif ev.ev == "action" and ev.act == "refresh" then
			refresh(state, cx)
		end
	end,

	key = function(state, key, cx)
		if key.ctrl and key.name == "r" then
			refresh(state, cx)
			return true
		end
		if state.filtering then
			if key.name == "escape" or key.name == "tab" then
				focusRows(state, cx)
				return true
			elseif (key.ctrl or key.meta) and key.name == "a" then
				state.anchor, state.cursor = 0, #state.filter
				return true
			elseif (key.ctrl or key.meta) and (key.name == "c" or key.name == "x") then
				local first = math.min(state.cursor, state.anchor or state.cursor)
				local last = math.max(state.cursor, state.anchor or state.cursor)
				if first == last then return false end
				cx:copy(state.filter:sub(first + 1, last))
				if key.name == "x" then replaceSelection(state, "") end
				return true
			elseif key.name == "left" or key.name == "right" or key.name == "home" or key.name == "end" then
				local old = state.cursor
				if key.shift then
					if state.anchor == nil then state.anchor = old end
				elseif state.anchor and state.anchor ~= old and not key.meta and key.name == "left" then
					state.cursor = math.min(old, state.anchor)
					state.anchor = nil
					return true
				elseif state.anchor and state.anchor ~= old and not key.meta and key.name == "right" then
					state.cursor = math.max(old, state.anchor)
					state.anchor = nil
					return true
				else
					state.anchor = nil
				end
				if key.name == "home" or (key.meta and key.name == "left") then
					state.cursor = 0
				elseif key.name == "end" or (key.meta and key.name == "right") then
					state.cursor = #state.filter
				elseif key.name == "left" and old > 0 then
					state.cursor = (utf8.offset(state.filter, -1, old + 1) or 1) - 1
				elseif key.name == "right" and old < #state.filter then
					state.cursor = (utf8.offset(state.filter, 2, old + 1) or (#state.filter + 1)) - 1
				end
				return true
			elseif key.name == "backspace" or key.name == "delete" then
				if state.anchor == nil or state.anchor == state.cursor then
					if key.name == "backspace" and state.cursor > 0 then
						state.anchor = (utf8.offset(state.filter, -1, state.cursor + 1) or 1) - 1
					elseif key.name == "delete" and state.cursor < #state.filter then
						state.anchor = (utf8.offset(state.filter, 2, state.cursor + 1) or (#state.filter + 1)) - 1
					else
						return false
					end
				end
				replaceSelection(state, "")
				return true
			elseif key.text and (key.name == "paste" or not (key.ctrl or key.meta or key.alt)) then
				if key.name ~= "enter" then
					replaceSelection(state, (string.gsub(key.text, "[\r\n]", " ")))
					return true
				end
			elseif key.name ~= "up" and key.name ~= "down" and key.name ~= "enter" then
				return false
			end
			focusRows(state, cx)
		elseif key.name == "/" or key.name == "tab" then
			focusFilter(state, cx)
			return true
		elseif key.name == "escape" and state.nav then
			state.nav = nil
			return true
		end
		local view = model(state)
		local row, index = selectedRow(state, view)
		if key.name == "up" or key.name == "down" then
			if #view.rows == 0 then return true end
			if index == 0 then
				index = if key.name == "up" then #view.rows else 1
			else
				index = math.clamp(index + (if key.name == "up" then -1 else 1), 1, #view.rows)
			end
			row = view.rows[index]
			state.nav = row.identity
			local hostNode = stableKey(state, "host\0" .. row.host.key, "h")
			local projectNode = stableKey(state, "project\0" .. row.host.key .. "\0" .. row.project.id, "p")
			local rowNode = stableKey(state, "row\0" .. row.identity, "w")
			cx:frame({ { "reveal", "main.list." .. hostNode .. "." .. projectNode .. "." .. rowNode .. ".line.open", "nearest" } })
			return true
		elseif key.name == "enter" then
			row = row or view.rows[1]
			if row and state.snapshot and type(state.snapshot.windowKey) == "string"
				and type(state.snapshot.sourceToken) == "string" then
				state.nav = row.identity
				cx:open(encodedLink("open", {
					hostKey = row.host.key, path = row.worktree.path, name = row.worktree.name,
					windowKey = state.snapshot.windowKey, sourceToken = state.snapshot.sourceToken,
				}))
				return true
			end
		end
		return false
	end,

	resize = function(state, _cols, _rows, cx)
		state.pendingResize = true
		publish(state, cx)
	end,

	save = function(state)
		return { hostKey = state.host.key, hostName = state.host.name, filter = state.filter }
	end,
}
