local ui = tern.ui
local text = require("./text")
local paths = require("./paths")
local repository = require("./repository")

local function link(action, data)
	local encoded = tern.json.encode(data):gsub("([^A-Za-z0-9%-%._~])", function(char)
		return string.format("%%%02X", string.byte(char))
	end)
	return "workspace-rail://" .. action .. "?data=" .. encoded
end

local function alive(state, cx)
	if state.closed then
		return false
	end
	for _, pane in tern.pane.list() do
		if pane.pane == cx.pane then
			return true
		end
	end
	return false
end

local function send(state, cx, action, data)
	if alive(state, cx) then
		data.sourceToken = state.sourceToken
		data.windowKey = state.windowKey
		cx:open(link(action, data))
	end
end

local function hostsLink(state, scoped)
	return link("hosts", {
		mode = state.mode,
		project = state.project,
		worktree = state.worktree,
		windowKey = if scoped then state.windowKey else nil,
		sourceToken = if scoped then state.sourceToken else nil,
	})
end

local function fieldOrder(state)
	if state.busy then
		return {}
	elseif state.page == "home" then
		return { "host", "browse", "clone", "create", "close" }
	elseif state.page == "browser" then
		local order = { "browsePath", "go", "up" }
		for index in ipairs(state.entries) do
			table.insert(order, "dir=" .. index)
		end
		table.insert(order, "use")
		table.insert(order, "back")
		return order
	elseif state.page == "found" then
		local order = {}
		for index in ipairs(state.repos) do
			table.insert(order, "repo=" .. index)
		end
		table.insert(order, "folder")
		table.insert(order, "add")
		table.insert(order, "back")
		return order
	elseif state.page == "create" then
		return { "name", "parent", "browseParent", "submit", "back" }
	elseif state.page == "clone" then
		return { "url", "name", "parent", "browseParent", "submit", "back" }
	elseif state.page == "worktree" then
		return { "branch", "base", "worktreePath", "submit", "close" }
	elseif state.page == "delete" then
		return { "close", "submit" }
	elseif state.page == "success" then
		return { "close" }
	end
	return { "close" }
end

local function focus(state, cx)
	if state.fields[state.focus] then
		cx:frame({ { "focus", "main." .. state.focus } })
	else
		cx:frame({ { "focus", tern.json.null } })
	end
end

local function setPage(state, page, target, cx)
	state.page, state.focus, state.error = page, target, nil
	tern.timer(30, function()
		if not state.closed and state.page == page and state.focus == target then
			focus(state, cx)
		end
	end)
end

local function caption(key, value, role)
	return ui.node("text", { key = key, role = role, text = value })
end

local function button(state, action, label, role, extra)
	local props = {
		key = action:gsub("=", "-"),
		role = role or "wr.button",
		class = if state.focus == action then "wr-key-focus" else nil,
		text = label,
		actions = { click = action },
	}
	if extra then
		for key, value in pairs(extra) do
			props[key] = value
		end
	end
	return ui.el("button", props)
end

local function choice(state, action, icon, label, detail, role)
	return ui.el("button", {
		key = action, role = role or "wr.choice", class = if state.focus == action then "wr-key-focus" else nil,
		actions = { click = action },
	}, {
		caption("icon", icon, "wr.choiceIcon"),
		ui.node("col", { key = "content", role = "wr.choiceText" }, {
			caption("title", label, "wr.choiceTitle"),
			caption("detail", detail, "wr.choiceDetail"),
		}),
	})
end

local function field(state, name, label, placeholder)
	local props = text.props(state.fields[name])
	props.key = name
	props.role = "wr.field"
	props.aria = label
	props.placeholder = placeholder
	return ui.node("input", props)
end

local function appendField(children, state, name, label, placeholder)
	table.insert(children, caption(name .. "Label", label, "wr.fieldLabel"))
	table.insert(children, field(state, name, label, placeholder))
end

local function nav(state, back)
	local children = {}
	if back then
		table.insert(children, button(state, "back", "← 返回", "wr.back"))
	end
	table.insert(children, button(state, "close", "×", "wr.close", { title = "关闭" }))
	return ui.node("row", { key = "nav", role = "wr.nav" }, children)
end

local function preview(parent, name)
	if parent == "" then
		return "请选择父目录"
	end
	return paths.join(parent, if name ~= "" then name else "项目名称")
end

local function autoWorktreePath(state)
	local branch = state.fields.branch.text:gsub("[/\\]", "-")
	if branch == "" then
		branch = "branch"
	end
	return (state.project and state.project.path or "") .. "-" .. branch
end

local function changedField(state, name)
	if name == "branch" and not state.pathEdited then
		state.fields.worktreePath = text.new(autoWorktreePath(state))
	elseif name == "worktreePath" then
		state.pathEdited = true
	elseif name == "name" then
		state.nameEdited = true
	elseif name == "url" and not state.nameEdited then
		local url = state.fields.url.text:gsub("[/\\]+$", "")
		local suggested = url:match("([^/\\:]+)$") or ""
		suggested = suggested:gsub("%.git$", "")
		state.fields.name = text.new(suggested)
	end
end

local function navigate(state, value)
	local path, pathError = paths.absolute(value)
	if not path then
		state.error = pathError
		return false
	end
	local ok, entries = pcall(tern.fs.list, path)
	if not ok then
		state.error = "无法打开目录：" .. tostring(entries)
		return false
	end
	state.browserPath = path
	state.fields.browsePath = text.new(path)
	state.entries = entries
	state.error = nil
	return true
end

local function startBrowser(state, purpose, cx)
	state.browserFor = purpose
	state.returnPage = state.page
	local start = if purpose == "parent" then state.fields.parent.text else state.home
	if start == "" then
		start = state.home
	end
	local current = start
	local opened = false
	while current ~= "" do
		if navigate(state, current) then
			opened = true
			break
		end
		local parent = paths.parent(current)
		if not parent or parent == current then
			break
		end
		current = parent
	end
	setPage(state, "browser", "browsePath", cx)
	if not opened then
		state.fields.browsePath = text.new(start)
		state.browserPath, state.entries = "", {}
		state.error = "无法打开初始目录，请输入目标主机上的现有目录。"
	end
end

local function endOperation(state, cx, result, err, successMessage, shouldOpen)
	if not alive(state, cx) then
		return
	end
	state.busy = nil
	if not result then
		state.error = tostring(err or "操作失败。")
		cx:render()
		return
	end
	state.success = successMessage
	state.page, state.focus, state.error = "success", "close", nil
	cx:render()
	if shouldOpen then
		send(state, cx, "opened", { path = result.path, name = result.name })
	else
		send(state, cx, "activity", {})
	end
end

local function runAsync(state, cx, message, start, finish)
	state.busy, state.error = message, nil
	local ok, err = pcall(start, finish)
	if not ok then
		state.busy = nil
		state.error = tostring(err)
	end
end

local function startDiscovery(state, cx)
	local path = state.browserPath
	if path == "" then
		state.error = "请选择一个现有目录。"
		return
	end
	runAsync(state, cx, "正在查找 Git 仓库…", function(done)
		repository.discover(path, done)
	end, function(result, err)
		if not alive(state, cx) then
			return
		end
		state.busy = nil
		if not result then
			state.error = tostring(err or "查找仓库失败。")
		else
			state.repos = result.repos
			state.selected = {}
			state.asFolder = #state.repos == 0
			if #state.repos == 1 then
				state.selected[1] = true
			end
			setPage(state, "found", if #state.repos > 0 then "repo=1" else "folder", cx)
		end
		cx:render()
	end)
end

local function addSelected(state, cx)
	local chosen = {}
	if state.asFolder then
		table.insert(chosen, {
			id = state.browserPath, path = state.browserPath,
			name = paths.basename(state.browserPath), kind = "folder",
		})
	else
		for index, project in ipairs(state.repos) do
			if state.selected[index] then
				table.insert(chosen, project)
			end
		end
	end
	if #chosen == 0 then
		state.error = "请至少选择一个仓库，或选择作为普通文件夹添加。"
		return
	end
	local first, failures, count = nil, {}, 0
	for _, project in ipairs(chosen) do
		local ok, added, err = pcall(repository.addProject, project)
		if ok and added then
			first = first or added
			count += 1
		else
			table.insert(failures, project.path .. "：" .. tostring(if ok then err or "添加失败" else added))
		end
	end
	if first then
		send(state, cx, "opened", { path = first.path, name = first.name, keepWizard = #failures > 0 })
		send(state, cx, "activity", {})
	end
	if #failures > 0 then
		state.error = (if count > 0 then "已添加 " .. count .. " 个项目。其他项目未添加：\n" else "添加失败：\n")
			.. table.concat(failures, "\n")
	else
		state.success = "已添加 " .. count .. " 个项目，正在打开 " .. first.name .. "。"
		state.page, state.focus, state.error = "success", "close", nil
	end
end

local function parentForSubmit(state)
	local value = state.fields.parent.text
	if value == "" then
		return nil, "请选择项目的父目录。"
	end
	local parent, err = paths.absolute(value)
	if not parent then
		return nil, tostring(err)
	end
	local existsOk, exists = pcall(tern.fs.exists, parent)
	if not existsOk then
		return nil, tostring(exists)
	end
	if not exists and state.defaultParent ~= "" and paths.same(parent, state.defaultParent) then
		local made, makeError = pcall(tern.fs.mkdir, parent)
		if not made then
			return nil, "无法创建默认项目目录：" .. tostring(makeError)
		end
	end
	local ok, listError = pcall(tern.fs.list, parent)
	if not ok then
		return nil, "无法访问父目录：" .. tostring(listError)
	end
	return parent
end

local function submit(state, cx)
	if state.page == "create" or state.page == "clone" then
		local name = state.fields.name.text
		if not name:find("%S") then
			state.error = "请输入项目名称。"
			return
		end
		local parent, err = parentForSubmit(state)
		if not parent then
			state.error = err
			return
		end
		local page = state.page
		local url = state.fields.url.text
		if page == "clone" and not url:find("%S") then
			state.error = "请输入 Git 仓库 URL。"
			return
		end
		runAsync(state, cx, if page == "clone" then "正在克隆仓库…" else "正在创建项目…", function(done)
			if page == "clone" then
				repository.cloneProject(parent, url, name, done)
			else
				repository.createProject(parent, name, done)
			end
		end, function(project, failure)
			endOperation(state, cx, project, failure, if page == "clone" then "仓库已克隆，正在打开项目。" else "项目已创建，正在打开项目。", true)
		end)
	elseif state.page == "worktree" then
		if not state.project or state.project.kind ~= "git" then
			state.error = "只有 Git 项目可以创建工作树。"
			return
		end
		local branch, path, base = state.fields.branch.text, state.fields.worktreePath.text, state.fields.base.text
		if not branch:find("%S") or not path:find("%S") then
			state.error = "请输入分支名称和工作树路径。"
			return
		end
		runAsync(state, cx, "正在创建工作树…", function(done)
			repository.createWorktree(state.project, { branch = branch, path = path, base = if base ~= "" then base else nil }, done)
		end, function(worktree, err)
			endOperation(state, cx, worktree, err, "工作树已创建，正在打开。", true)
		end)
	elseif state.page == "delete" then
		if not state.project then
			state.error = "未指定项目。"
			return
		end
		if state.worktree then
			if state.worktree.main then
				state.error = "不能删除主要工作树。"
				return
			end
			runAsync(state, cx, "正在删除工作树…", function(done)
				repository.removeWorktree(state.project, state.worktree, done)
			end, function(result, err)
				if alive(state, cx) and not result then
					send(state, cx, "activity", {})
				end
				endOperation(state, cx, result, err, "工作树已删除。", false)
			end)
		else
			local ok, err = pcall(repository.removeProject, state.project.id)
			if not ok then
				state.error = tostring(err)
				return
			end
			state.success, state.page, state.focus = "项目已从工作区移除，磁盘文件未删除。", "success", "close"
			send(state, cx, "activity", {})
		end
	end
end

local function activate(state, action, cx)
	if state.busy then
		return
	end
	local verb, value = action:match("^([^=]+)=(.*)$")
	verb = verb or action
	if verb == "close" then
		state.closed = true
		cx:exit(0)
	elseif verb == "host" then
		cx:open(hostsLink(state, true))
	elseif verb == "browse" then
		startBrowser(state, "add", cx)
	elseif verb == "browseParent" then
		startBrowser(state, "parent", cx)
	elseif verb == "clone" or verb == "create" then
		setPage(state, verb, if verb == "clone" then "url" else "name", cx)
	elseif verb == "back" then
		if state.page == "browser" then
			setPage(state, state.returnPage, if state.returnPage == "home" then "browse" else "parent", cx)
		elseif state.page == "found" then
			setPage(state, "browser", "browsePath", cx)
		else
			setPage(state, "home", "browse", cx)
		end
	elseif verb == "go" then
		navigate(state, state.fields.browsePath.text)
	elseif verb == "up" then
		if state.browserPath ~= "" then
			navigate(state, paths.parent(state.browserPath))
		end
	elseif verb == "dir" then
		local entry = state.entries[tonumber(value)]
		if entry then
			navigate(state, paths.join(state.browserPath, entry))
		end
	elseif verb == "use" then
		if navigate(state, state.fields.browsePath.text) then
			if state.browserFor == "parent" then
				state.fields.parent = text.new(state.browserPath)
				setPage(state, state.returnPage, "parent", cx)
			else
				startDiscovery(state, cx)
			end
		end
	elseif verb == "repo" then
		local index = tonumber(value)
		if index and state.repos[index] then
			state.asFolder = false
			state.selected[index] = not state.selected[index]
		end
	elseif verb == "folder" then
		state.asFolder = not state.asFolder
		if state.asFolder then
			state.selected = {}
		end
	elseif verb == "add" then
		addSelected(state, cx)
	elseif verb == "submit" then
		submit(state, cx)
	end
end

local function render(state): BlockView
	local children = { nav(state, state.page == "browser" or state.page == "found" or state.page == "create" or state.page == "clone") }
	if state.page == "home" then
		table.insert(children, caption("title", "添加项目", "wr.title"))
		table.insert(children, ui.node("row", { key = "hostRow", role = "wr.hostRow" }, {
			caption("hostLabel", "主机", "wr.hostLabel"),
			button(state, "host", state.hostName .. "  ▾", "wr.host", { href = hostsLink(state, false), actions = { click = "open" } }),
		}))
		table.insert(children, choice(state, "browse", "▱", "浏览文件夹", "本地项目、Git 仓库或包含多个仓库的文件夹", "wr.featuredChoice"))
		table.insert(children, caption("other", "其他添加方式", "wr.sectionLabel"))
		table.insert(children, ui.node("col", { key = "choices", role = "wr.choiceGroup" }, {
			choice(state, "clone", "◎", "从 URL 克隆", "克隆远程 Git 存储库"),
			choice(state, "create", "+", "创建新项目", "从空文件夹开始"),
		}))
	elseif state.page == "browser" then
		table.insert(children, caption("title", if state.browserFor == "parent" then "选择父目录" else "浏览文件夹", "wr.title"))
		table.insert(children, caption("description", "在 " .. state.hostName .. " 上浏览，或输入绝对路径。", "wr.description"))
		appendField(children, state, "browsePath", "当前目录", "例如 C:\\Users\\name 或 \\\\server\\share")
		table.insert(children, ui.node("row", { key = "browseActions", role = "wr.inlineActions" }, {
			button(state, "go", "打开路径", "wr.secondary"),
			button(state, "up", "上一级", "wr.secondary"),
		}))
		local entries = {}
		for index, entry in ipairs(state.entries) do
			table.insert(entries, button(state, "dir=" .. index, "›  " .. entry, "wr.entry"))
		end
		if #entries == 0 then
			table.insert(entries, caption("empty", "此目录为空，或尚未打开目录。", "wr.muted"))
		end
		table.insert(children, ui.node("col", { key = "entries", role = "wr.entries" }, entries))
		table.insert(children, caption("entryHint", "选择条目进入目录。文件或无权访问的目录会显示错误。", "wr.hint"))
		table.insert(children, button(state, "use", if state.browserFor == "parent" then "使用此目录" else "选择此文件夹", "wr.primary"))
	elseif state.page == "found" then
		table.insert(children, caption("title", "选择要添加的项目", "wr.title"))
		table.insert(children, caption("description", "已扫描 " .. state.browserPath .. "。可选择仓库，或将此目录作为普通文件夹。", "wr.description"))
		local choices = {}
		for index, project in ipairs(state.repos) do
			table.insert(choices, button(state, "repo=" .. index,
				(if state.selected[index] and not state.asFolder then "☑ " else "□ ") .. project.name .. "  ·  " .. project.path, "wr.selectRow"))
		end
		table.insert(choices, button(state, "folder", (if state.asFolder then "☑ " else "□ ") .. "作为普通文件夹添加  ·  " .. state.browserPath, "wr.selectRow"))
		table.insert(children, ui.node("col", { key = "repositories", role = "wr.entries" }, choices))
		table.insert(children, button(state, "add", "添加所选项目", "wr.primary"))
	elseif state.page == "create" or state.page == "clone" then
		local cloning = state.page == "clone"
		table.insert(children, caption("title", if cloning then "从 URL 克隆" else "创建新项目", "wr.title"))
		table.insert(children, caption("description", if cloning then "将远程 Git 仓库克隆到所选主机。" else "为它命名，在所选主机上创建一个新的 Git 项目。", "wr.description"))
		if cloning then
			appendField(children, state, "url", "仓库 URL", "https://github.com/user/repository.git")
		end
		appendField(children, state, "name", "名称", "my-project")
		appendField(children, state, "parent", "父目录", "输入现有目录")
		table.insert(children, button(state, "browseParent", "浏览父目录…", "wr.secondary"))
		table.insert(children, ui.node("col", { key = "preview", role = "wr.preview" }, {
			caption("label", "Git 存储库将创建在", "wr.previewLabel"),
			caption("path", preview(state.fields.parent.text, state.fields.name.text), "wr.previewPath"),
		}))
		table.insert(children, button(state, "submit", if cloning then "克隆项目" else "创建项目", "wr.primary"))
	elseif state.page == "worktree" then
		table.insert(children, caption("title", "创建工作树", "wr.title"))
		table.insert(children, caption("description", if state.project then "项目：" .. state.project.name .. "  ·  " .. state.project.path else "未指定项目。", "wr.description"))
		appendField(children, state, "branch", "新分支", "feature/my-work")
		appendField(children, state, "base", "起始分支或提交（可选）", "HEAD")
		appendField(children, state, "worktreePath", "工作树路径", "输入新的绝对路径")
		table.insert(children, button(state, "submit", "创建工作树", "wr.primary"))
	elseif state.page == "delete" then
		local worktree = state.worktree
		table.insert(children, caption("title", if worktree then "删除工作树？" else "移除项目？", "wr.title"))
		if worktree then
			table.insert(children, caption("description", "将删除工作树 " .. worktree.path .. "。", "wr.description"))
			table.insert(children, caption("warning", if worktree.main then "主要工作树不能删除。" else "此操作会删除该工作树中的文件，包括未跟踪和被忽略的文件。此操作无法撤销。", "wr.warning"))
			if worktree.error then
				table.insert(children, caption("previousError", "上次删除失败：" .. worktree.error, "wr.error"))
			end
		else
			table.insert(children, caption("description", if state.project then "从工作区移除 " .. state.project.name .. "（" .. state.project.path .. "）。" else "未指定项目。", "wr.description"))
			table.insert(children, caption("warning", "仅移除项目记录，不删除磁盘上的文件。", "wr.hint"))
		end
		table.insert(children, ui.node("row", { key = "confirm", role = "wr.confirm" }, {
			button(state, "close", "取消", "wr.secondary"),
			button(state, "submit", if worktree then "确认删除工作树" else "移除项目记录", "wr.danger"),
		}))
	elseif state.page == "success" then
		table.insert(children, caption("title", "完成", "wr.title"))
		table.insert(children, caption("success", state.success or "操作完成。", "wr.success"))
		table.insert(children, button(state, "close", "完成", "wr.primary"))
	elseif state.page == "invalid" then
		table.insert(children, caption("title", "无法打开向导", "wr.title"))
	end
	if state.busy then
		table.insert(children, caption("busy", state.busy, "wr.busy"))
	end
	if state.error then
		table.insert(children, caption("error", state.error, "wr.error"))
	end
	if state.page ~= "success" then
		table.insert(children, caption("keys", "Tab 切换  ·  Enter 选择  ·  Esc 返回", "wr.keys"))
	end
	return { main = ui.node("col", { role = "wr.wizard" }, children) }
end

local function checkedBlock<S>(definition: BlockDef<S>): BlockDef<S>
	return definition
end

return checkedBlock({
	features = { "edit" },
	init = function(cx, args, _saved)
		local ok, value = pcall(tern.json.decode, args[1] or "{}")
		local options = if ok and type(value) == "table" then value else {}
		local mode = if options.mode == "worktree" or options.mode == "delete" then options.mode else "add"
		local project = options.project
		if type(project) ~= "table" or type(project.id) ~= "string" or type(project.path) ~= "string"
			or type(project.name) ~= "string" or (project.kind ~= "git" and project.kind ~= "folder") then
			project = nil
		end
		local worktree = options.worktree
		local invalidWorktree = worktree ~= nil and (type(worktree) ~= "table" or type(worktree.path) ~= "string"
			or type(worktree.name) ~= "string" or type(worktree.main) ~= "boolean")
		if invalidWorktree then
			worktree = nil
		end
		local invalid = (mode ~= "add" and not project) or (mode == "delete" and invalidWorktree)
		local home = if tern.runtime.os == "windows" then tern.getenv("USERPROFILE") else nil
		if not home or home == "" then home = tern.getenv("HOME") end
		home = home or ""
		local parent = if home ~= "" then paths.join(paths.join(home, "tern"), "projects") else ""
		local state = {
			closed = false,
			mode = mode, page = if invalid then "invalid" elseif mode == "add" then "home" else mode,
			hostKey = if type(options.hostKey) == "string" then options.hostKey else "local",
			hostName = if type(options.hostName) == "string" then options.hostName
				elseif type(options.hostKey) == "string" then options.hostKey else "Local",
			windowKey = if type(options.windowKey) == "string" then options.windowKey else "",
			sourceToken = if type(options.sourceToken) == "string" then options.sourceToken else nil,
			project = project, worktree = worktree,
			error = if invalid then "项目或工作树参数无效，请从工作区重新打开此向导。" else nil,
			home = home, defaultParent = parent, browserPath = "", entries = {}, repos = {}, selected = {},
			fields = { name = text.new(""), parent = text.new(parent), url = text.new(""), branch = text.new(""),
				base = text.new(""), worktreePath = text.new(""), browsePath = text.new(home) },
			focus = if invalid then "close" elseif mode == "add" then "browse" elseif mode == "worktree" then "branch" else "close",
		}
		state.fields.worktreePath = text.new(autoWorktreePath(state))
		tern.timer(30, function()
			if not state.closed then
				focus(state, cx)
			end
		end)
		return state
	end,
	title = function()
		return "工作区项目"
	end,
	view = render,
	key = function(state, key, cx)
		if state.busy then
			return false
		end
		if key.name == "escape" or key.name == "esc" then
			if state.page == "browser" or state.page == "found" or state.page == "create" or state.page == "clone" then
				activate(state, "back", cx)
			else
				activate(state, "close", cx)
			end
			return true
		elseif key.name == "tab" then
			local order = fieldOrder(state)
			local index = table.find(order, state.focus) or 0
			state.focus = order[((index - 1 + (if key.shift then -1 else 1)) % #order) + 1]
			focus(state, cx)
			return true
		elseif key.name == "enter" then
			if state.focus == "browsePath" then
				activate(state, "go", cx)
			elseif state.fields[state.focus] then
				activate(state, "submit", cx)
			else
				activate(state, state.focus, cx)
			end
			return true
		end
		local field = state.fields[state.focus]
		if not field then
			return false
		end
		local name = string.lower(key.name)
		if (key.ctrl or key.meta) and (name == "c" or name == "x") then
			local selected = text.selection(field)
			if selected ~= "" then
				cx:copy(selected)
			end
			if name == "c" then
				return selected ~= ""
			end
		end
		local before = field.text
		local handled, err = text.key(field, key)
		if not handled then
			return false
		end
		state.error = err
		if field.text ~= before then
			changedField(state, state.focus)
		end
		return true
	end,
	event = function(state, event, cx)
		if event.ev == "action" and event.id == "main" and event.act == "bind" then
			local ok, value = pcall(tern.json.decode, event.value or "")
			if ok and type(value) == "table" and value.windowKey == state.windowKey and type(value.sourceToken) == "string" then
				state.sourceToken = value.sourceToken
			end
			return
		end
		if state.busy then
			return
		end
		if event.ev == "focus" then
			local name = event.id and event.id:match("^main%.([^%.]+)$")
			if name and state.fields[name] and table.find(fieldOrder(state), name) then
				state.focus = name
				focus(state, cx)
			end
		elseif event.ev == "edit" then
			local name = event.id and event.id:match("^main%.([^%.]+)$")
			local field = name and state.fields[name]
			if field and table.find(fieldOrder(state), name) then
				local before = field.text
				local handled, err = text.edit(field, event)
				state.error = err
				if handled and field.text ~= before then
					changedField(state, name)
				end
			end
		elseif event.ev == "action" and event.act then
			local action = event.act .. (if event.value ~= nil then "=" .. tostring(event.value) else "")
			state.focus = action
			activate(state, action, cx)
		end
	end,
})
