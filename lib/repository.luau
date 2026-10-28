local paths = require("./paths")
local store = require("./store")

local repository = {}

local SCAN_DEPTH = 8
local SCAN_CANDIDATES = 512

local WINDOWS_SCAN = [=[
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$ignored = @('node_modules', 'build', 'dist', 'target', 'out', '.next', '.venv')
$stack = [System.Collections.Generic.Stack[object]]::new()
$stack.Push(@($env:WORKSPACE_RAIL_SCAN_ROOT, 0))
$count = 0
$depthLimit = [int]$env:WORKSPACE_RAIL_SCAN_DEPTH
$candidateLimit = [int]$env:WORKSPACE_RAIL_SCAN_LIMIT
try {
    while ($stack.Count -gt 0) {
        $current = $stack.Pop()
        $directory = [string]$current[0]
        $depth = [int]$current[1]
        foreach ($entry in [System.IO.Directory]::EnumerateFileSystemEntries($directory)) {
            $name = [System.IO.Path]::GetFileName($entry)
            if ($name -eq '.git') {
                $count++
                if ($count -gt $candidateLimit) {
                    throw "More than $candidateLimit repository markers were found; select a smaller directory."
                }
                [Console]::Write($entry)
                [Console]::Write([char]0)
            } elseif ($depth -lt $depthLimit -and $ignored -notcontains $name) {
                $attributes = [System.IO.File]::GetAttributes($entry)
                if (($attributes -band [System.IO.FileAttributes]::Directory) -and
                    -not ($attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
                    $stack.Push(@($entry, ($depth + 1)))
                }
            }
        }
    }
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
]=]

local WINDOWS_REMOVE_EMPTY = [=[
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
try {
    [System.IO.Directory]::Delete($env:WORKSPACE_RAIL_WORKTREE_PATH, $false)
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
]=]

local function run(argv, extraEnv, cb)
	local env = { LC_ALL = "C", LANG = "C" }
	if extraEnv then
		for key, value in pairs(extraEnv) do
			env[key] = value
		end
	end
	local ok, err = pcall(tern.process.run, argv, { env = env }, function(result)
		cb(result, nil)
	end)
	if not ok then
		cb(nil, tostring(err))
	end
end

local function git(args, cb)
	local argv = { "git" }
	for _, arg in ipairs(args) do
		table.insert(argv, arg)
	end
	run(argv, nil, cb)
end

local function processError(result, spawnError)
	if spawnError then
		return spawnError
	end
	local text = result.stderr
	if text == "" then
		text = result.stdout
	end
	text = text:gsub("%s+$", "")
	if text == "" then
		text = "Process exited with status " .. tostring(result.status) .. "."
	end
	if result.timed_out then
		text = text .. " (The process timed out.)"
	end
	return text
end

local function outputLine(text)
	if text:sub(-1) == "\n" then
		text = text:sub(1, -2)
		if text:sub(-1) == "\r" then
			text = text:sub(1, -2)
		end
	end
	return text
end

local function directory(path)
	local ok, result = pcall(tern.fs.list, path)
	if not ok then
		return nil, "Cannot open directory " .. path .. ": " .. tostring(result)
	end
	return true
end

local function exists(path)
	local ok, result = pcall(tern.fs.exists, path)
	if not ok then
		return nil, "Cannot inspect " .. path .. ": " .. tostring(result)
	end
	return result
end

local function gitInProject(project, args, cb)
	local loaded, anchor = pcall(store.anchor, project.id)
	if not loaded then
		cb(nil, "Cannot read the saved Git location: " .. tostring(anchor))
		return
	end
	local location = project.path
	if anchor and not paths.same(anchor, project.path) then
		local present, inspectError = exists(anchor)
		if present == nil then
			cb(nil, inspectError)
			return
		elseif present then
			location = anchor
		end
	end
	local command = { "-C", location }
	for _, arg in ipairs(args) do
		table.insert(command, arg)
	end
	git(command, cb)
end

local function projectAt(path, kind)
	return { id = path, path = path, name = paths.basename(path), kind = kind }
end

local function validName(name)
	if type(name) ~= "string" or name == "" or name:match("^%s*$") or name == "." or name == ".." then
		return nil, "Enter a directory name."
	end
	if name:find("/", 1, true) or name:find("\0", 1, true) then
		return nil, "The name must be a single directory name."
	end
	if tern.runtime.os == "windows" then
		if name:find("[<>:\"\\|%?%*%c]") or name:match("[ .]$") then
			return nil, "The directory name contains characters Windows does not allow."
		end
		local stem = (name:match("^([^.]+)") or name):upper()
		if stem == "CON" or stem == "PRN" or stem == "AUX" or stem == "NUL"
			or stem:match("^COM[1-9]$") or stem:match("^LPT[1-9]$") then
			return nil, "The directory name is reserved by Windows."
		end
	end
	return true
end

local function destination(parent, name)
	local valid, nameError = validName(name)
	if not valid then
		return nil, nameError
	end
	local base, pathError = paths.absolute(parent)
	if not base then
		return nil, pathError
	end
	local ok, directoryError = directory(base)
	if not ok then
		return nil, directoryError
	end
	local target = paths.join(base, name)
	local present, inspectError = exists(target)
	if present == nil then
		return nil, inspectError
	elseif present then
		return nil, "The destination already exists: " .. target
	end
	return target
end

function repository.projects()
	return store.projects()
end

function repository.addProject(project)
	if type(project) ~= "table" or (project.kind ~= "git" and project.kind ~= "folder") then
		return nil, "A Git repository or folder project is required."
	end
	local path, pathError = paths.absolute(project.path)
	if not path then
		return nil, pathError
	end
	local ok, directoryError = directory(path)
	if not ok then
		return nil, directoryError
	end
	local entry = {
		id = path,
		path = path,
		name = type(project.name) == "string" and project.name ~= "" and project.name or paths.basename(path),
		kind = project.kind,
	}
	local loaded, projects = pcall(store.projects)
	if not loaded then
		return nil, "Cannot read saved projects: " .. tostring(projects)
	end
	local updated = tern.json.array()
	local replaced = false
	for _, existing in ipairs(projects) do
		if paths.same(existing.path, path) then
			if not replaced then
				table.insert(updated, entry)
				replaced = true
			end
		else
			table.insert(updated, existing)
		end
	end
	if not replaced then
		table.insert(updated, entry)
	end
	local saved, saveError = pcall(store.saveProjects, updated)
	if not saved then
		return nil, "Cannot save the project: " .. tostring(saveError)
	end
	return entry
end

function repository.removeProject(id)
	local updated = tern.json.array()
	for _, project in ipairs(store.projects()) do
		if not paths.same(project.id, id) then
			table.insert(updated, project)
		end
	end
	store.saveProjects(updated)
end

local function scanDirectories(root, cb)
	local argv
	local env
	if tern.runtime.os == "windows" then
		argv = { "powershell.exe", "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", WINDOWS_SCAN }
		env = {
			WORKSPACE_RAIL_SCAN_ROOT = root,
			WORKSPACE_RAIL_SCAN_DEPTH = tostring(SCAN_DEPTH),
			WORKSPACE_RAIL_SCAN_LIMIT = tostring(SCAN_CANDIDATES),
		}
	else
		argv = {
			"find", root, "-mindepth", "1", "-maxdepth", tostring(SCAN_DEPTH + 1),
			"(", "-type", "d", "(", "-name", "node_modules", "-o", "-name", "build", "-o",
			"-name", "dist", "-o", "-name", "target", "-o", "-name", "out", "-o",
			"-name", ".next", "-o", "-name", ".venv", ")", "-prune", ")", "-o",
			"(", "-name", ".git", "-print0", "-prune", ")",
		}
	end
	run(argv, env, function(result, spawnError)
		if not result or result.status ~= 0 then
			cb(nil, "Cannot scan " .. root .. ": " .. processError(result, spawnError))
			return
		end
		local candidates = tern.json.array()
		local offset = 1
		while offset <= #result.stdout do
			local stop = result.stdout:find("\0", offset, true)
			if not stop then
				cb(nil, "Directory scan output was incomplete for " .. root .. ". Select a smaller directory.")
				return
			end
			local marker = result.stdout:sub(offset, stop - 1)
			table.insert(candidates, paths.parent(marker))
			if #candidates > SCAN_CANDIDATES then
				cb(nil, "More than " .. tostring(SCAN_CANDIDATES) .. " repository markers were found; select a smaller directory.")
				return
			end
			offset = stop + 1
		end
		cb(candidates, nil)
	end)
end

local function gitRoot(path, cb)
	git({ "-C", path, "rev-parse", "--show-toplevel" }, function(result, spawnError)
		if not result then
			cb(nil, processError(nil, spawnError), false)
		elseif result.status ~= 0 then
			local message = processError(result, nil)
			local notRepository = message:lower():find("not a git repository", 1, true) ~= nil
			cb(nil, message, notRepository)
		else
			local root, pathError = paths.absolute(outputLine(result.stdout))
			if not root then
				cb(nil, "Git returned an invalid repository path: " .. pathError, false)
			else
				cb(root, nil, false)
			end
		end
	end)
end

function repository.discover(path, cb)
	local selected, pathError = paths.absolute(path)
	if not selected then
		cb(nil, pathError)
		return
	end
	local ok, directoryError = directory(selected)
	if not ok then
		cb(nil, directoryError)
		return
	end
	gitRoot(selected, function(root, gitError, notRepository)
		if root then
			cb({ root = root, repos = tern.json.array({ projectAt(root, "git") }) }, nil)
		elseif not notRepository then
			cb(nil, gitError)
		else
			scanDirectories(selected, function(candidates, scanError)
				if not candidates then
					cb(nil, scanError)
					return
				end
				local repos = tern.json.array()
				local index = 0
				local function nextCandidate()
					index += 1
					if index > #candidates then
						table.sort(repos, function(a, b)
							return a.path:lower() < b.path:lower()
						end)
						cb({ root = selected, repos = repos }, nil)
						return
					end
					local candidate = candidates[index]
					gitRoot(candidate, function(found, err)
						if not found then
							cb(nil, "Cannot inspect repository marker in " .. candidate .. ": " .. err)
							return
						end
						local duplicate = false
						for _, existing in ipairs(repos) do
							if paths.same(existing.path, found) then
								duplicate = true
								break
							end
						end
						if not duplicate then
							table.insert(repos, projectAt(found, "git"))
						end
						nextCandidate()
					end)
				end
				nextCandidate()
			end)
		end
	end)
end

function repository.createProject(parent, name, cb)
	local target, targetError = destination(parent, name)
	if not target then
		cb(nil, targetError)
		return
	end
	local created, createError = pcall(tern.fs.mkdir, target)
	if not created then
		cb(nil, "Cannot create directory " .. target .. ": " .. tostring(createError))
		return
	end
	git({ "-C", target, "init" }, function(initResult, initError)
		if not initResult or initResult.status ~= 0 then
			cb(nil, "Git initialization failed: " .. processError(initResult, initError) .. "\nThe directory was preserved at " .. target .. ".")
			return
		end
		git({ "-C", target, "commit", "--allow-empty", "-m", "Initial commit" }, function(commitResult, commitError)
			if not commitResult or commitResult.status ~= 0 then
				cb(nil, "The initial commit failed: " .. processError(commitResult, commitError)
					.. "\nThe initialized repository was preserved at " .. target
					.. ". Resolve the Git error and commit manually, or import the existing repository.")
				return
			end
			local project, saveError = repository.addProject(projectAt(target, "git"))
			if not project then
				cb(nil, saveError .. "\nThe repository remains at " .. target .. ". Import it to try again.")
				return
			end
			cb(project, nil)
		end)
	end)
end

function repository.cloneProject(parent, url, name, cb)
	if type(url) ~= "string" or url:match("^%s*$") or url:find("\0", 1, true) then
		cb(nil, "Enter a Git clone URL.")
		return
	end
	local target, targetError = destination(parent, name)
	if not target then
		cb(nil, targetError)
		return
	end
	git({ "clone", "--", url, target }, function(result, spawnError)
		if not result or result.status ~= 0 then
			cb(nil, "Git clone failed: " .. processError(result, spawnError)
				.. "\nAny remaining files at " .. target .. " were not removed by the plugin.")
			return
		end
		local project, saveError = repository.addProject(projectAt(target, "git"))
		if not project then
			cb(nil, saveError .. "\nThe cloned repository remains at " .. target .. ". Import it to try again.")
			return
		end
		cb(project, nil)
	end)
end

local function parseWorktrees(output)
	local rows = tern.json.array()
	local row = nil
	local offset = 1
	while offset <= #output do
		local stop = output:find("\0", offset, true)
		if not stop then
			return nil, "Git returned incomplete worktree data."
		end
		local field = output:sub(offset, stop - 1)
		offset = stop + 1
		if field == "" then
			if row then
				table.insert(rows, row)
				row = nil
			end
		elseif field:sub(1, 9) == "worktree " then
			if row then
				return nil, "Git returned malformed worktree data."
			end
			local path, pathError = paths.absolute(field:sub(10))
			if not path then
				return nil, "Git returned an invalid worktree path: " .. pathError
			end
			row = { path = path, name = paths.basename(path), main = #rows == 0 }
		elseif not row then
			return nil, "Git returned malformed worktree data."
		elseif field:sub(1, 5) == "HEAD " then
			row.head = field:sub(6)
		elseif field:sub(1, 7) == "branch " then
			local branch = field:sub(8)
			row.branch = branch:sub(1, 11) == "refs/heads/" and branch:sub(12) or branch
		elseif field == "detached" then
			row.branch = nil
		elseif field == "locked" or field:sub(1, 7) == "locked " then
			row.locked = true
		end
	end
	if row or #rows == 0 then
		return nil, "Git returned incomplete worktree data."
	end
	return rows
end

function repository.worktrees(project, cb)
	if project.kind == "folder" then
		local present, inspectError = exists(project.path)
		if present == nil then
			cb(nil, inspectError)
			return
		end
		cb(tern.json.array({ {
			path = project.path,
			name = project.name,
			main = true,
			missing = not present or nil,
		} }), nil)
		return
	end
	if project.kind ~= "git" then
		cb(nil, "Unknown project kind.")
		return
	end
	gitInProject(project, { "worktree", "list", "--porcelain", "-z" }, function(result, spawnError)
		if not result or result.status ~= 0 then
			cb(nil, "Cannot list worktrees: " .. processError(result, spawnError))
			return
		end
		local rows, parseError = parseWorktrees(result.stdout)
		if not rows then
			cb(nil, parseError)
			return
		end
		for _, row in ipairs(rows) do
			local present, inspectError = exists(row.path)
			if present == nil then
				cb(nil, inspectError)
				return
			elseif not present then
				row.missing = true
			end
		end
		local anchor = nil
		for _, row in ipairs(rows) do
			if not row.missing then
				if row.main then
					anchor = row.path
					break
				elseif not anchor or paths.same(anchor, project.path) then
					anchor = row.path
				end
			end
		end
		if anchor then
			local saved, saveError = pcall(store.saveAnchor, project.id, anchor)
			if not saved then
				cb(nil, "Cannot save the Git location: " .. tostring(saveError))
				return
			end
		end
		local loaded, failures = pcall(store.failures, project.id)
		if not loaded then
			cb(nil, "Cannot read saved worktree errors: " .. tostring(failures))
			return
		end
		for _, failure in ipairs(failures) do
			local matched = false
			for _, row in ipairs(rows) do
				if paths.same(row.path, failure.path) then
					row.error = failure.error
					matched = true
					break
				end
			end
			if not matched then
				local present, inspectError = exists(failure.path)
				if present == nil then
					cb(nil, inspectError)
					return
				elseif not present then
					local cleared, clearError = pcall(store.clearFailure, project.id, failure.path)
					if not cleared then
						cb(nil, "Cannot clear the resolved worktree error: " .. tostring(clearError))
						return
					end
				else
					failure.missing = nil
					failure.unregistered = true
					table.insert(rows, failure)
				end
			end
		end
		cb(rows, nil)
	end)
end

function repository.createWorktree(project, options, cb)
	if project.kind ~= "git" then
		cb(nil, "Worktrees can only be created for a Git project.")
		return
	end
	if type(options) ~= "table" or type(options.branch) ~= "string" or options.branch == ""
		or options.branch:sub(1, 1) == "-" or options.branch:find("\0", 1, true) then
		cb(nil, "Enter a valid new branch name.")
		return
	end
	if type(options.path) ~= "string" or not paths.isAbsolute(options.path) then
		cb(nil, "Enter an absolute destination path for the worktree.")
		return
	end
	local target, pathError = paths.absolute(options.path)
	if not target then
		cb(nil, pathError)
		return
	end
	local present, inspectError = exists(target)
	if present == nil then
		cb(nil, inspectError)
		return
	elseif present then
		cb(nil, "The worktree destination already exists: " .. target)
		return
	end
	if options.base ~= nil and (type(options.base) ~= "string" or options.base:find("\0", 1, true)) then
		cb(nil, "Enter a valid base revision.")
		return
	end
	git({ "check-ref-format", "--branch", options.branch }, function(checkResult, checkError)
		if not checkResult or checkResult.status ~= 0 then
			cb(nil, "Invalid branch name: " .. processError(checkResult, checkError))
			return
		end
		local args = { "worktree", "add", "-b", options.branch, "--", target }
		if options.base and options.base ~= "" then
			table.insert(args, options.base)
		end
		gitInProject(project, args, function(result, spawnError)
			if not result or result.status ~= 0 then
				cb(nil, "Cannot create worktree: " .. processError(result, spawnError)
					.. "\nAny remaining files at " .. target .. " were not removed by the plugin.")
				return
			end
			local cleared, clearError = pcall(store.clearFailure, project.id, target)
			if not cleared then
				cb(nil, "The worktree was created at " .. target .. ", but its saved error could not be cleared: " .. tostring(clearError))
				return
			end
			cb({ path = target, name = paths.basename(target), branch = options.branch, main = false }, nil)
		end)
	end)
end

local function failedRemoval(project, worktree, message, cb)
	local failure = {
		path = worktree.path,
		name = worktree.name or paths.basename(worktree.path),
		branch = worktree.branch,
		head = worktree.head,
		main = worktree.main == true,
		locked = worktree.locked,
		missing = worktree.missing,
		error = message,
	}
	local saved, saveError = pcall(store.setFailure, project.id, failure)
	if not saved then
		message = message .. "\nThe failure could not be saved: " .. tostring(saveError)
	end
	cb(nil, message)
end

local function completedRemoval(project, path, cb)
	local cleared, clearError = pcall(store.clearFailure, project.id, path)
	if not cleared then
		cb(nil, "The worktree was removed, but its saved error could not be cleared: " .. tostring(clearError))
		return
	end
	cb(true, nil)
end

function repository.removeWorktree(project, worktree, cb)
	if project.kind ~= "git" then
		cb(nil, "Only Git worktrees can be removed.")
		return
	end
	if type(worktree) ~= "table" or type(worktree.path) ~= "string" then
		cb(nil, "A worktree is required.")
		return
	end
	local path, pathError = paths.absolute(worktree.path)
	if not path then
		cb(nil, pathError)
		return
	end
	worktree = {
		path = path,
		name = worktree.name,
		branch = worktree.branch,
		head = worktree.head,
		main = worktree.main,
		locked = worktree.locked,
		missing = worktree.missing,
	}
	if worktree.main then
		failedRemoval(project, worktree, "The main worktree cannot be removed.", cb)
		return
	end
	repository.worktrees(project, function(rows, listError)
		if not rows then
			failedRemoval(project, worktree, listError, cb)
			return
		end
		local target = nil
		local executionPath = nil
		for _, row in ipairs(rows) do
			if paths.same(row.path, path) then
				target = row
				if row.main then
					failedRemoval(project, row, "The main worktree cannot be removed.", cb)
					return
				end
			elseif not row.missing and not row.unregistered and (not executionPath or row.main) then
				executionPath = row.path
			end
		end
		if target and target.unregistered then
			local argv
			local env
			if tern.runtime.os == "windows" then
				argv = { "powershell.exe", "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", WINDOWS_REMOVE_EMPTY }
				env = { WORKSPACE_RAIL_WORKTREE_PATH = path }
			else
				argv = { "rmdir", path }
			end
			run(argv, env, function(result, spawnError)
				local present, inspectError = exists(path)
				if present == false then
					completedRemoval(project, path, cb)
				elseif not result or result.status ~= 0 then
					local message = "Cannot remove the remaining worktree directory: " .. processError(result, spawnError)
						.. "\nOnly an empty directory can be removed; its contents were not removed by the plugin."
					if inspectError then
						message ..= "\n" .. inspectError
					end
					failedRemoval(project, target, message, cb)
				elseif present == nil then
					failedRemoval(project, target, "The directory removal completed, but the destination could not be inspected: " .. inspectError, cb)
				else
					failedRemoval(project, target, "The directory removal completed, but the destination still exists at " .. path .. ".", cb)
				end
			end)
			return
		elseif not target then
			local present, inspectError = exists(path)
			if present == nil then
				cb(nil, inspectError)
			elseif not present then
				completedRemoval(project, path, cb)
			else
				cb(nil, "The path is not a registered worktree. Its directory was not removed.")
			end
			return
		end
		if not executionPath then
			failedRemoval(project, worktree, "No other available worktree can run Git to remove " .. path .. ".", cb)
			return
		end
		git({ "-C", executionPath, "worktree", "remove", "--", path }, function(result, spawnError)
			if not result or result.status ~= 0 then
				failedRemoval(project, worktree, "Cannot remove worktree: " .. processError(result, spawnError), cb)
				return
			end
			local present, inspectError = exists(path)
			if present == nil then
				failedRemoval(project, worktree, "Git completed the removal, but the destination could not be inspected: " .. inspectError, cb)
				return
			elseif present then
				failedRemoval(project, worktree, "Git completed the removal, but the directory still exists at " .. path .. ". It was not deleted by the plugin.", cb)
				return
			end
			completedRemoval(project, path, cb)
		end)
	end)
end

return repository
