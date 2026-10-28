local paths = require("./paths")

local PROJECTS_KEY = "workspace-rail.projects"
local FAILURES_KEY = "workspace-rail.worktree-failures"
local ANCHORS_KEY = "workspace-rail.git-anchors"

local store = {}

local function readArray(key)
	local value = tern.kv.get(key)
	if value == nil then
		return tern.json.array()
	end
	if type(value) ~= "table" then
		error("Stored workspace data is invalid: " .. key)
	end
	return value
end

function store.projects()
	return readArray(PROJECTS_KEY)
end

function store.saveProjects(projects)
	tern.kv.set(PROJECTS_KEY, tern.json.array(projects))
end

function store.anchor(projectId)
	for _, record in ipairs(readArray(ANCHORS_KEY)) do
		if paths.same(record.projectId, projectId) then
			return record.path
		end
	end
	return nil
end

function store.saveAnchor(projectId, path)
	local records = tern.json.array()
	local existing = nil
	for _, record in ipairs(readArray(ANCHORS_KEY)) do
		if paths.same(record.projectId, projectId) then
			existing = record.path
		else
			table.insert(records, record)
		end
	end
	if existing and paths.same(existing, path) then
		return
	end
	table.insert(records, { projectId = projectId, path = path })
	tern.kv.set(ANCHORS_KEY, records)
end

function store.failures(projectId)
	local result = tern.json.array()
	for _, record in ipairs(readArray(FAILURES_KEY)) do
		if paths.same(record.projectId, projectId) then
			table.insert(result, record.worktree)
		end
	end
	return result
end

function store.setFailure(projectId, worktree)
	local records = tern.json.array()
	for _, record in ipairs(readArray(FAILURES_KEY)) do
		if not (paths.same(record.projectId, projectId) and paths.same(record.worktree.path, worktree.path)) then
			table.insert(records, record)
		end
	end
	table.insert(records, { projectId = projectId, worktree = worktree })
	tern.kv.set(FAILURES_KEY, records)
end

function store.clearFailure(projectId, path)
	local records = tern.json.array()
	local changed = false
	for _, record in ipairs(readArray(FAILURES_KEY)) do
		if paths.same(record.projectId, projectId) and paths.same(record.worktree.path, path) then
			changed = true
		else
			table.insert(records, record)
		end
	end
	if changed then
		tern.kv.set(FAILURES_KEY, records)
	end
end

return store
