local M = {}

local defaults = {
  command = "mermaid-inline",
  auto_render = true,
  pattern = "*.md",
  preview_height = 12,
  open_preview_on_render = true,
  render_args = { "--inline", "--clear" },
}

M.config = vim.deepcopy(defaults)
M.preview_job = nil

local function is_job_running(job)
  if not job then
    return false
  end
  local status = vim.fn.jobwait({ job }, 0)[1]
  return status == -1
end

function M.open_preview()
  if is_job_running(M.preview_job) then
    return M.preview_job
  end

  vim.cmd("botright " .. tostring(M.config.preview_height) .. "split")
  vim.cmd("terminal")
  M.preview_job = vim.b.terminal_job_id
  return M.preview_job
end

local function render_cmd(file)
  local cmd = M.config.command .. " render " .. vim.fn.shellescape(file)
  for _, arg in ipairs(M.config.render_args or {}) do
    cmd = cmd .. " " .. arg
  end
  return cmd
end

function M.render(file)
  local target = file or vim.api.nvim_buf_get_name(0)
  if target == "" then
    return
  end

  local job = M.preview_job
  if M.config.open_preview_on_render then
    job = M.open_preview()
  end

  local cmd = render_cmd(target)
  if job and is_job_running(job) then
    vim.fn.chansend(job, cmd .. "\n")
  else
    vim.fn.jobstart({ "sh", "-lc", cmd }, { detach = true })
  end
end

local function define_autocmd()
  local group = vim.api.nvim_create_augroup("MermaidInlineAuto", { clear = true })
  if not M.config.auto_render then
    return
  end

  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    pattern = M.config.pattern,
    callback = function(args)
      M.render(args.file)
    end,
  })
end

function M.toggle_auto()
  M.config.auto_render = not M.config.auto_render
  define_autocmd()
  if M.config.auto_render then
    vim.notify("MermaidInline auto-render enabled", vim.log.levels.INFO)
  else
    vim.notify("MermaidInline auto-render disabled", vim.log.levels.INFO)
  end
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  define_autocmd()

  vim.api.nvim_create_user_command("MermaidInlineOpenPreview", function()
    M.open_preview()
  end, {})

  vim.api.nvim_create_user_command("MermaidInlineRender", function(cmd_opts)
    local file = cmd_opts.args ~= "" and cmd_opts.args or nil
    M.render(file)
  end, {
    nargs = "?",
    complete = "file",
  })

  vim.api.nvim_create_user_command("MermaidInlineToggleAuto", function()
    M.toggle_auto()
  end, {})
end

return M
