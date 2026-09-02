--!nonstrict
-- Kimai control panel. Two modes:
--   * running  - the active entry's elapsed time, editable project / activity /
--                description / start time, plus Save and Stop
--   * idle     - project / activity / description pickers and a Start button
--
-- Project and activity lists load once on open. Edits are held as a local draft
-- and pushed with Save (PATCH); Start and Stop hit their own endpoints. After
-- any mutation the panel reloads the active entry and pokes the bar widget.

local kimai = require("./kimai.luau")

-- Whether to prefix each project option with its Kimai customer (client) name.
local SHOW_CLIENT = noctalia.getConfig("show_client") ~= false

-- ── state ────────────────────────────────────────────────────────────────────

local isOpen = false
local phase = "loading" -- "loading" | "error" | "running" | "idle"
local errorMessage = ""

local running = nil

local projectList = {} -- array of Kimai project entities, order = select order
local activityList = {} -- array of Kimai activity entities
local pendingLoads = 0
local busy = false

-- Sum of every finished entry that began this week (Sunday 00:00 local). The
-- running entry is excluded here and added live at render time, since Kimai does
-- not count it.
local weekFinishedSeconds = 0
local weekStatus = "loading" -- "loading" | "ok" | "error"

-- draft: what the form currently holds
local draft = {
  projectId = nil,
  activityId = nil,
  description = "",
  beginTime = "",
}
-- snapshot of the running entry the draft was seeded from, for dirty checks
local baseline = {}
local inputRevision = 0 -- bump to force inputs/selects to re-read their value

-- ── helpers ──────────────────────────────────────────────────────────────────

local function projectLabel(entity)
  if SHOW_CLIENT and type(entity.parentTitle) == "string" and entity.parentTitle ~= "" then
    return entity.parentTitle .. " / " .. tostring(entity.name)
  end
  return tostring(entity.name)
end

-- Activities valid for a project: its own plus the global (project-less) ones.
local function activitiesFor(projectId)
  local out = {}
  for _, activity in ipairs(activityList) do
    if activity.project == nil or tostring(activity.project) == tostring(projectId) then
      out[#out + 1] = activity
    end
  end
  return out
end

local function indexOfId(list, id)
  for i, entity in ipairs(list) do
    if tostring(entity.id) == tostring(id) then
      return i
    end
  end
  return nil
end

local function dirty()
  if draft.description ~= baseline.description then
    return true
  end
  if tostring(draft.projectId) ~= tostring(baseline.projectId) then
    return true
  end
  if tostring(draft.activityId) ~= tostring(baseline.activityId) then
    return true
  end
  if draft.beginTime ~= baseline.beginTime then
    return true
  end
  return false
end

-- Keep the drafted activity valid whenever the drafted project changes.
local function reconcileActivity()
  local valid = activitiesFor(draft.projectId)
  if draft.activityId ~= nil and indexOfId(valid, draft.activityId) ~= nil then
    return
  end
  draft.activityId = valid[1] and valid[1].id or nil
end

-- ── data loading ─────────────────────────────────────────────────────────────

local function seedDraftFromRunning()
  local begun = kimai.beginSeconds(running)
  draft = {
    projectId = kimai.entityId(running.project),
    activityId = kimai.entityId(running.activity),
    description = (type(running.description) == "string" and running.description) or "",
    beginTime = begun and kimai.formatClock(begun) or "",
  }
  baseline = {
    projectId = draft.projectId,
    activityId = draft.activityId,
    description = draft.description,
    beginTime = draft.beginTime,
  }
end

-- Set once the user edits the idle form, so a slow server response does not
-- overwrite their pick. Cleared each time the form is reseeded.
local idleFormTouched = false

-- seed is an optional { project, activity, description } from server history to
-- prefer; a project id not in the current list is ignored.
local function seedDraftForIdle(seed)
  local projectId = projectList[1] and projectList[1].id or nil
  local activityId = nil
  local description = ""

  if type(seed) == "table" and indexOfId(projectList, seed.project) ~= nil then
    projectId = seed.project
    activityId = seed.activity
    description = (type(seed.description) == "string" and seed.description) or ""
  end

  draft = {
    projectId = projectId,
    activityId = activityId,
    description = description,
    beginTime = "",
  }
  reconcileActivity()
  baseline = {}
  idleFormTouched = false
end

local function recomputePhase()
  if not kimai.ready() then
    phase, errorMessage = "error", noctalia.tr("errors.not_configured")
  elseif running ~= nil then
    phase = "running"
    seedDraftFromRunning()
  else
    phase = "idle"
    seedDraftForIdle(nil)
  end
  inputRevision = inputRevision + 1
end

-- Default the idle pickers to the most recent timesheet on the server, unless
-- the user has already touched the form.
local function seedIdleFromServer()
  if phase ~= "idle" or idleFormTouched then
    return
  end
  kimai.recent(function(ok, data)
    if not isOpen or not ok or phase ~= "idle" or idleFormTouched then
      return
    end
    local recent = type(data) == "table" and data[1] or nil
    if recent == nil then
      return
    end
    seedDraftForIdle({
      project = recent.project,
      activity = recent.activity,
      description = (type(recent.description) == "string" and recent.description) or "",
    })
    inputRevision = inputRevision + 1
    render()
  end)
end

-- render() is a global defined further down; every call site here runs either
-- from an async callback or a host-invoked entry point, after the file has fully
-- loaded, so the definition is always in place by then.

local function loadWeek()
  weekStatus = "loading"
  kimai.timesheetsSince(kimai.weekStartDateTime(), function(ok, list)
    if not isOpen then
      return
    end
    if not ok then
      weekStatus = "error"
      render()
      return
    end
    local total = 0
    for _, entry in ipairs(list) do
      if running == nil or tostring(entry.id) ~= tostring(running.id) then
        total = total + (tonumber(entry.duration) or 0)
      end
    end
    weekFinishedSeconds, weekStatus = total, "ok"
    render()
  end)
end

local function loadActive(afterMutation)
  kimai.active(function(ok, data, _status, err)
    if not isOpen then
      return
    end
    if not ok then
      phase, errorMessage = "error", err or noctalia.tr("errors.network")
      render()
      return
    end
    running = (type(data) == "table") and data[1] or nil
    recomputePhase()
    render()
    seedIdleFromServer()
    loadWeek()
    if afterMutation then
      noctalia.runAsync({ "noctalia", "msg", "plugin", "jechton/kimai:bar", "all", "refresh" })
    end
  end)
end

local function loadLists()
  pendingLoads = 2
  local function done()
    pendingLoads = pendingLoads - 1
    if pendingLoads <= 0 then
      loadActive(false)
    end
  end
  kimai.projects(function(ok, data)
    if ok and type(data) == "table" then
      projectList = data
    end
    done()
  end)
  kimai.activities(function(ok, data)
    if ok and type(data) == "table" then
      activityList = data
    end
    done()
  end)
end

-- ── mutations ────────────────────────────────────────────────────────────────

local function finishMutation(ok, err, successKey)
  busy = false
  if ok then
    noctalia.notify(noctalia.tr("title"), noctalia.tr(successKey))
    loadActive(true)
  else
    noctalia.notifyError(noctalia.tr("title"), err or noctalia.tr("errors.network"))
    render()
  end
end

function onSave()
  if busy or phase ~= "running" or running == nil then
    return
  end
  local patch = {}
  if draft.description ~= baseline.description then
    patch.description = draft.description
  end
  if tostring(draft.projectId) ~= tostring(baseline.projectId) then
    patch.project = tonumber(draft.projectId)
  end
  if tostring(draft.activityId) ~= tostring(baseline.activityId) then
    patch.activity = tonumber(draft.activityId)
  end
  if draft.beginTime ~= baseline.beginTime then
    local hh, mm = kimai.parseClock(draft.beginTime)
    local date = kimai.beginDate(running)
    if hh == nil or date == nil then
      noctalia.notifyError(noctalia.tr("title"), noctalia.tr("errors.bad_time"))
      return
    end
    patch["begin"] = string.format("%sT%02d:%02d:00", date, hh, mm)
  end

  if next(patch) == nil then
    return
  end
  busy = true
  render()
  kimai.patch(running.id, patch, function(ok, _data, _status, err)
    finishMutation(ok, err, "notify.saved")
  end)
end

function onStop()
  if busy or running == nil then
    return
  end
  busy = true
  render()
  kimai.stop(running.id, function(ok, _data, _status, err)
    finishMutation(ok, err, "notify.stopped")
  end)
end

function onStart()
  if busy or phase ~= "idle" then
    return
  end
  if draft.projectId == nil or draft.activityId == nil then
    noctalia.notifyError(noctalia.tr("title"), noctalia.tr("errors.pick_project"))
    return
  end
  busy = true
  render()
  kimai.start({
    ["begin"] = kimai.nowDateTime(),
    project = tonumber(draft.projectId),
    activity = tonumber(draft.activityId),
    description = draft.description,
  }, function(ok, _data, _status, err)
    finishMutation(ok, err, "notify.started")
  end)
end

-- ── form callbacks ───────────────────────────────────────────────────────────

function onProjectChange(index)
  local i = (tonumber(index) or 0) + 1
  local chosen = projectList[i]
  draft.projectId = chosen and chosen.id or nil
  idleFormTouched = true
  reconcileActivity()
  render()
end

function onActivityChange(index)
  local valid = activitiesFor(draft.projectId)
  local chosen = valid[(tonumber(index) or 0) + 1]
  draft.activityId = chosen and chosen.id or nil
  idleFormTouched = true
  render()
end

function onDescriptionChange(value)
  draft.description = (type(value) == "string" and value) or ""
  idleFormTouched = true
end

function onBeginChange(value)
  draft.beginTime = (type(value) == "string" and value) or ""
end

function onRefresh()
  phase = "loading"
  render()
  loadLists()
end

function onCloseClicked()
  panel.close()
end

-- ── rendering ────────────────────────────────────────────────────────────────

local function header()
  return ui.row({ align = "center", justify = "space_between", gap = 8 }, {
    ui.label({ text = noctalia.tr("title"), fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
    ui.button({ glyph = "refresh", variant = "ghost", onClick = "onRefresh" }),
    ui.button({ glyph = "close", variant = "ghost", onClick = "onCloseClicked" }),
  })
end

-- Weekly total: finished entries this week plus the live running elapsed.
local function weekRow()
  local value
  if weekStatus == "loading" then
    value = "…"
  elseif weekStatus == "error" then
    value = noctalia.tr("week.unavailable")
  else
    local seconds = weekFinishedSeconds
    if running ~= nil then
      seconds = seconds + kimai.elapsedSeconds(running)
    end
    value = kimai.hhmm(seconds)
  end
  return ui.row({ align = "center", justify = "space_between", gap = 8 }, {
    ui.label({ text = noctalia.tr("week.label"), fontSize = 12, color = "on_surface_variant" }),
    ui.label({ text = value, fontSize = 12, fontWeight = "bold", color = "on_surface" }),
  })
end

local function projectSelect()
  local options, order = {}, {}
  for _, entity in ipairs(projectList) do
    order[#order + 1] = entity
    options[#options + 1] = projectLabel(entity)
  end
  local selected = indexOfId(order, draft.projectId)
  return ui.column({ gap = 2, align = "stretch" }, {
    ui.label({ text = noctalia.tr("field.project"), fontSize = 11, color = "on_surface_variant" }),
    ui.select({
      key = "project-" .. tostring(inputRevision),
      options = options,
      selectedIndex = selected and (selected - 1) or 0,
      onChange = "onProjectChange",
    }),
  })
end

local function activitySelect()
  local valid = activitiesFor(draft.projectId)
  local options = {}
  for _, entity in ipairs(valid) do
    options[#options + 1] = tostring(entity.name)
  end
  local selected = indexOfId(valid, draft.activityId)
  return ui.column({ gap = 2, align = "stretch" }, {
    ui.label({ text = noctalia.tr("field.activity"), fontSize = 11, color = "on_surface_variant" }),
    ui.select({
      key = "activity-" .. tostring(inputRevision) .. "-" .. tostring(draft.projectId),
      options = options,
      selectedIndex = selected and (selected - 1) or 0,
      onChange = "onActivityChange",
    }),
  })
end

local function descriptionInput()
  return ui.column({ gap = 2, align = "stretch" }, {
    ui.label({ text = noctalia.tr("field.description"), fontSize = 11, color = "on_surface_variant" }),
    ui.input({
      key = "desc-" .. tostring(inputRevision),
      value = draft.description,
      placeholder = noctalia.tr("field.description_placeholder"),
      onChange = "onDescriptionChange",
    }),
  })
end

local function runningBody()
  local elapsed = kimai.hhmm(kimai.elapsedSeconds(running))
  return {
    ui.row({ justify = "center" }, {
      ui.label({ text = elapsed, fontSize = 30, fontWeight = "bold", color = "primary" }),
    }),
    projectSelect(),
    activitySelect(),
    descriptionInput(),
    ui.column({ gap = 2, align = "stretch" }, {
      ui.label({ text = noctalia.tr("field.begin"), fontSize = 11, color = "on_surface_variant" }),
      ui.input({
        key = "begin-" .. tostring(inputRevision),
        value = draft.beginTime,
        placeholder = noctalia.tr("field.begin_placeholder"),
        onChange = "onBeginChange",
        onSubmit = "onSave",
      }),
    }),
    ui.row({ justify = "space_between", gap = 8 }, {
      ui.button({
        text = noctalia.tr("action.save"),
        variant = "primary",
        enabled = not busy and dirty(),
        onClick = "onSave",
      }),
      ui.button({
        text = noctalia.tr("action.stop"),
        variant = "primary",
        enabled = not busy,
        onClick = "onStop",
      }),
    }),
  }
end

local function idleBody()
  return {
    ui.row({ justify = "center" }, {
      ui.label({ text = noctalia.tr("state.idle"), fontSize = 13, color = "on_surface_variant" }),
    }),
    projectSelect(),
    activitySelect(),
    descriptionInput(),
    ui.row({ justify = "center" }, {
      ui.button({
        text = noctalia.tr("action.start"),
        variant = "primary",
        enabled = not busy and draft.projectId ~= nil and draft.activityId ~= nil,
        onClick = "onStart",
      }),
    }),
  }
end

function render()
  if not isOpen then
    return
  end

  local body
  if phase == "loading" then
    body = {
      ui.column({ flexGrow = 1, align = "center", justify = "center" }, {
        ui.label({ text = noctalia.tr("state.loading"), color = "on_surface_variant" }),
      }),
    }
  elseif phase == "error" then
    body = {
      ui.column({ flexGrow = 1, align = "center", justify = "center", gap = 8 }, {
        ui.glyph({ name = "alert", size = 28, color = "error" }),
        ui.label({ text = errorMessage, color = "on_surface_variant", textAlign = "center", maxLines = 4 }),
        ui.button({ text = noctalia.tr("action.retry"), variant = "primary", onClick = "onRefresh" }),
      }),
    }
  elseif phase == "running" then
    body = runningBody()
  else
    body = idleBody()
  end

  local chrome = { header() }
  if phase == "running" or phase == "idle" then
    chrome[#chrome + 1] = weekRow()
    chrome[#chrome + 1] = ui.separator({})
  end
  chrome[#chrome + 1] = ui.scroll({ flexGrow = 1, gap = 12, align = "stretch" }, body)

  panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, chrome))
end

-- ── lifecycle ────────────────────────────────────────────────────────────────

function onOpen(_context)
  isOpen = true
  phase = "loading"
  panel.setWantsSecondTicks(true)
  render()
  loadLists()
end

function onClose()
  isOpen = false
  panel.setWantsSecondTicks(false)
end

function update()
  if isOpen and phase == "running" then
    render() -- tick the elapsed label
  end
end
