local M = {}

-- Treesitter parser policy lives here instead of inside the plugin spec because
-- parser provenance is now a real maintenance concern:
--
-- - Neovim 0.12 ships some bundled parsers under lib/nvim/parser.
-- - nvim-treesitter installs user parsers under stdpath("data")/site/parser.
-- - runtimepath can therefore expose multiple parser candidates for the same
--   language, and grouped languages like markdown + markdown_inline can end up
--   mixed across directories.
--
-- For now we explicitly enforce only parser families that must stay matched
-- together, and we warn loudly about duplicate parser candidates elsewhere.
-- That keeps markdown stable without papering over every duplicate runtimepath
-- situation with more risky overrides.

M.base_install_languages = {
  "rust",
  "javascript",
  "zig",
  "c",
  "lua",
  "vim",
  "bash",
  "comment",
  "gitcommit",
  "diff",
  "git_rebase",
}

M.parser_groups = {
  {
    name = "markdown",
    languages = { "markdown", "markdown_inline" },
    reason = "markdown plugins use both block and inline parsers; mixed sources can crash ranged parsing",
  },
}

local function uniq(list)
  local out = {}
  local seen = {}
  for _, item in ipairs(list) do
    if not seen[item] then
      seen[item] = true
      table.insert(out, item)
    end
  end
  return out
end

local function parser_file(lang)
  return ("parser/%s.so"):format(lang)
end

local function parser_candidates(lang)
  return vim.api.nvim_get_runtime_file(parser_file(lang), true)
end

local function parser_root(path)
  return vim.fn.fnamemodify(path, ":h")
end

local function parser_source_kind(root)
  if root:find("/lib/nvim/parser", 1, true) then
    return "builtin"
  end
  if root:find("/site/parser", 1, true) then
    return "site"
  end
  return "other"
end

local function current_nvim_parser_root()
  local progpath = vim.fn.resolve(vim.v.progpath)
  local nvim_root = vim.fn.fnamemodify(progpath, ":h:h")
  local parser_root_dir = nvim_root .. "/lib/nvim/parser"
  return vim.fn.isdirectory(parser_root_dir) == 1 and parser_root_dir or nil
end

local function complete_group_from_root(group, root)
  local paths = {}
  for _, lang in ipairs(group.languages) do
    local path = root .. "/" .. lang .. ".so"
    if vim.fn.filereadable(path) ~= 1 then
      return nil
    end
    paths[lang] = path
  end
  return {
    root = root,
    kind = parser_source_kind(root),
    paths = paths,
  }
end

local function choose_group_source(group)
  local builtin_root = current_nvim_parser_root()
  local site_roots = {}
  local other_roots = {}

  for _, lang in ipairs(group.languages) do
    for _, path in ipairs(parser_candidates(lang)) do
      local root = parser_root(path)
      local kind = parser_source_kind(root)
      if kind == "site" then
        site_roots[root] = true
      elseif kind == "other" then
        other_roots[root] = true
      end
    end
  end

  for root, _ in pairs(site_roots) do
    local complete = complete_group_from_root(group, root)
    if complete then
      return complete
    end
  end

  if builtin_root then
    local builtin = complete_group_from_root(group, builtin_root)
    if builtin then
      return builtin
    end
  end

  for root, _ in pairs(other_roots) do
    local complete = complete_group_from_root(group, root)
    if complete then
      return complete
    end
  end

  return nil
end

local function choose_singleton_source(lang)
  local candidates = parser_candidates(lang)
  if #candidates == 0 then
    return nil
  end

  local preferred
  for _, path in ipairs(candidates) do
    if parser_source_kind(parser_root(path)) == "site" then
      preferred = path
      break
    end
  end

  if not preferred then
    for _, path in ipairs(candidates) do
      if parser_source_kind(parser_root(path)) == "builtin" then
        preferred = path
        break
      end
    end
  end

  preferred = preferred or candidates[1]
  return {
    path = preferred,
    root = parser_root(preferred),
    kind = parser_source_kind(parser_root(preferred)),
    candidates = candidates,
  }
end

local function raw_group_report(group)
  local report = {
    name = group.name,
    languages = group.languages,
    reason = group.reason,
    candidates = {},
    mixed = false,
  }

  local roots = {}
  for _, lang in ipairs(group.languages) do
    report.candidates[lang] = parser_candidates(lang)
    for _, path in ipairs(report.candidates[lang]) do
      roots[parser_root(path)] = true
    end
  end

  local root_list = vim.tbl_keys(roots)
  table.sort(root_list)
  report.roots = root_list
  report.mixed = #root_list > 1
  report.chosen = choose_group_source(group)
  return report
end

local function duplicate_parser_report(languages)
  local duplicates = {}
  for _, lang in ipairs(languages) do
    local paths = parser_candidates(lang)
    if #paths > 1 then
      duplicates[lang] = paths
    end
  end
  return duplicates
end

local function warning_lines(state)
  local lines = {}

  for _, report in ipairs(state.group_reports) do
    if report.mixed then
      table.insert(lines, ("[%s] mixed parser roots detected"):format(report.name))
      for _, lang in ipairs(report.languages) do
        table.insert(lines, ("  %s: %s"):format(lang, table.concat(report.candidates[lang], " | ")))
      end
      if report.chosen then
        table.insert(lines, ("  policy: forcing matched %s parser pair from %s"):format(report.chosen.kind, report.chosen.root))
      else
        table.insert(lines, "  policy: no complete matched pair found; falling back to nvim-treesitter install")
      end
    end
  end

  local duplicate_langs = vim.tbl_keys(state.duplicates)
  table.sort(duplicate_langs)
  if #duplicate_langs > 0 then
    table.insert(lines, "")
    table.insert(lines, "duplicate parser candidates on runtimepath:")
    for _, lang in ipairs(duplicate_langs) do
      local singleton = state.singleton_reports[lang]
      local suffix = ""
      if singleton then
        suffix = (" [preferred: %s]"):format(singleton.path)
      end
      table.insert(lines, ("  %s: %s%s"):format(lang, table.concat(state.duplicates[lang], " | "), suffix))
    end
    table.insert(lines, "run :TSParserReport for a full report")
  end

  return lines
end

local function report_lines(state)
  local lines = {
    "Treesitter parser report",
    "",
    ("Neovim parser root: %s"):format(current_nvim_parser_root() or "<none>"),
    "",
    "Managed parser groups:",
  }

  for _, report in ipairs(state.group_reports) do
    table.insert(lines, ("- %s"):format(report.name))
    table.insert(lines, ("  reason: %s"):format(report.reason))
    for _, lang in ipairs(report.languages) do
      local candidates = report.candidates[lang]
      local rendered = #candidates > 0 and table.concat(candidates, " | ") or "<missing>"
      table.insert(lines, ("  %s: %s"):format(lang, rendered))
    end
    if report.chosen then
      table.insert(lines, ("  chosen root: %s (%s)"):format(report.chosen.root, report.chosen.kind))
    else
      table.insert(lines, "  chosen root: <none>")
    end
  end

  table.insert(lines, "")
  table.insert(lines, "Managed standalone parsers:")
  local singleton_langs = vim.tbl_keys(state.singleton_reports)
  table.sort(singleton_langs)
  for _, lang in ipairs(singleton_langs) do
    local report = state.singleton_reports[lang]
    if report then
      table.insert(lines, ("- %s: %s (%s)"):format(lang, report.path, report.kind))
    else
      table.insert(lines, ("- %s: <missing>"):format(lang))
    end
  end

  local duplicate_langs = vim.tbl_keys(state.duplicates)
  table.sort(duplicate_langs)
  table.insert(lines, "")
  table.insert(lines, "Duplicate parser candidates:")
  if #duplicate_langs == 0 then
    table.insert(lines, "- none")
  else
    for _, lang in ipairs(duplicate_langs) do
      table.insert(lines, ("- %s: %s"):format(lang, table.concat(state.duplicates[lang], " | ")))
    end
  end

  table.insert(lines, "")
  table.insert(lines, "Install languages:")
  table.insert(lines, "- " .. table.concat(state.install_languages, ", "))

  return lines
end

function M.inspect()
  local install_languages = vim.deepcopy(M.base_install_languages)
  local group_reports = {}

  for _, group in ipairs(M.parser_groups) do
    local report = raw_group_report(group)
    table.insert(group_reports, report)
    if not report.chosen then
      vim.list_extend(install_languages, group.languages)
    end
  end

  local singleton_reports = {}
  for _, lang in ipairs(M.base_install_languages) do
    local report = choose_singleton_source(lang)
    singleton_reports[lang] = report
  end

  install_languages = uniq(install_languages)

  local duplicate_scope = vim.deepcopy(M.base_install_languages)
  for _, group in ipairs(M.parser_groups) do
    vim.list_extend(duplicate_scope, group.languages)
  end

  return {
    install_languages = install_languages,
    group_reports = group_reports,
    singleton_reports = singleton_reports,
    duplicates = duplicate_parser_report(uniq(duplicate_scope)),
  }
end

function M.apply_parser_policy()
  local state = M.inspect()
  M._last_state = state

  for _, report in ipairs(state.group_reports) do
    if report.chosen then
      for lang, path in pairs(report.chosen.paths) do
        vim.treesitter.language.add(lang, { path = path })
      end
    end
  end

  local lines = warning_lines(state)
  if #lines > 0 then
    vim.schedule(function()
      vim.notify(table.concat(lines, "\n"), vim.log.levels.WARN, {
        title = "Treesitter Parser Policy",
      })
    end)
  end

  return state.install_languages
end

function M.setup_user_commands()
  vim.api.nvim_create_user_command("TSParserReport", function()
    local state = M._last_state or M.inspect()
    local buf = vim.api.nvim_create_buf(false, true)
    local lines = report_lines(state)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = "text"
    vim.cmd("tabnew")
    vim.api.nvim_win_set_buf(0, buf)
  end, {
    desc = "Inspect Treesitter parser policy and runtimepath conflicts",
  })
end

return M
