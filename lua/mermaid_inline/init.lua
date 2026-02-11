local M = {}

local defaults = {
  command = "mermaid-inline",
  auto_render = true,
  pattern = "*.md",
  preview_height = 12,
  open_preview_on_render = false,
  render_args = { "--inline", "--clear" },
  inline_in_buffer = true,
  inline_out_dir = nil,
  modal_width_ratio = 0.85,
  modal_height_ratio = 0.85,
  modal_zoom_step = 0.15,
  modal_border = "rounded",
}

M.config = vim.deepcopy(defaults)
M.preview_job = nil
M.buffer_images = {}
M.modal = nil
M.ns = vim.api.nvim_create_namespace("MermaidInline")

local function is_job_running(job)
  if not job then
    return false
  end
  local status = vim.fn.jobwait({ job }, 0)[1]
  return status == -1
end

local function create_or_replace_user_command(name, fn, opts)
  pcall(vim.api.nvim_del_user_command, name)
  vim.api.nvim_create_user_command(name, fn, opts)
end

local function shellescape(value)
  return vim.fn.shellescape(value)
end

local function image_module()
  local ok, image = pcall(require, "image")
  if not ok or type(image.from_file) ~= "function" then
    return nil
  end
  return image
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
  local cmd = M.config.command .. " render " .. shellescape(file)
  for _, arg in ipairs(M.config.render_args or {}) do
    cmd = cmd .. " " .. arg
  end
  return cmd
end

local function find_mermaid_blocks(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local blocks = {}
  local start_line = nil

  for i, line in ipairs(lines) do
    if not start_line and line:match("^```mermaid%s*$") then
      start_line = i
    elseif start_line and line:match("^```%s*$") then
      blocks[#blocks + 1] = {
        index = #blocks + 1,
        start_line = start_line,
        end_line = i,
      }
      start_line = nil
    end
  end

  return blocks
end

local function block_index_at_cursor(bufnr)
  local line = vim.api.nvim_win_get_cursor(0)[1]
  for _, block in ipairs(find_mermaid_blocks(bufnr)) do
    if line >= block.start_line and line <= block.end_line then
      return block.index
    end
  end
  return nil
end

local function inline_out_dir(bufnr, file)
  if M.config.inline_out_dir and M.config.inline_out_dir ~= "" then
    vim.fn.mkdir(M.config.inline_out_dir, "p")
    return M.config.inline_out_dir
  end

  local stem = vim.fn.fnamemodify(file, ":t:r")
  if stem == "" then
    stem = "buffer-" .. tostring(bufnr)
  end
  stem = stem:gsub("[^%w%-%_]+", "_")

  local path = vim.fn.stdpath("cache") .. "/mermaid-inline/" .. stem
  vim.fn.mkdir(path, "p")
  return path
end

local function diagram_path(out_dir, index)
  return string.format("%s/mermaid-%d.png", out_dir, index)
end

local function clear_buffer_images(bufnr)
  local images = M.buffer_images[bufnr] or {}
  for _, img in ipairs(images) do
    pcall(function()
      img:clear()
    end)
  end
  M.buffer_images[bufnr] = {}
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, M.ns, 0, -1)
end

local function render_images_in_buffer(bufnr, out_dir)
  local image = image_module()
  if not image then
    return false, "image.nvim is not available"
  end

  local wins = vim.fn.win_findbuf(bufnr)
  local winid = wins[1] or vim.api.nvim_get_current_win()
  local blocks = find_mermaid_blocks(bufnr)

  clear_buffer_images(bufnr)

  for _, block in ipairs(blocks) do
    local path = diagram_path(out_dir, block.index)
    if vim.fn.filereadable(path) == 1 then
      local ok_img, img = pcall(image.from_file, path, {
        window = winid,
        buffer = bufnr,
        x = 0,
        y = block.start_line - 1,
        with_virtual_padding = true,
      })
      if ok_img and img then
        pcall(function()
          img:render()
        end)
        table.insert(M.buffer_images[bufnr], img)
      end
    end
  end

  return true
end

local function run_shell_async(cmd, on_exit)
  vim.fn.jobstart({ "sh", "-lc", cmd }, {
    on_exit = function(_, code)
      if on_exit then
        vim.schedule(function()
          on_exit(code)
        end)
      end
    end,
  })
end

local function close_modal()
  if M.modal and M.modal.img then
    pcall(function()
      M.modal.img:clear()
    end)
  end
  if M.modal and M.modal.win and vim.api.nvim_win_is_valid(M.modal.win) then
    pcall(vim.api.nvim_win_close, M.modal.win, true)
  end
  M.modal = nil
end

local function modal_size(scale)
  local cols = vim.o.columns
  local lines = vim.o.lines - vim.o.cmdheight

  local w = math.max(20, math.floor(cols * M.config.modal_width_ratio * scale))
  local h = math.max(6, math.floor(lines * M.config.modal_height_ratio * scale))

  w = math.min(w, cols - 4)
  h = math.min(h, lines - 4)

  return w, h
end

local function render_modal_image()
  if not M.modal then
    return
  end
  local image = image_module()
  if not image then
    vim.notify("image.nvim is required for modal view", vim.log.levels.WARN)
    return
  end

  if M.modal.img then
    pcall(function()
      M.modal.img:clear()
    end)
    M.modal.img = nil
  end

  local ok_img, img = pcall(image.from_file, M.modal.path, {
    window = M.modal.win,
    buffer = M.modal.buf,
    x = 0,
    y = 0,
    with_virtual_padding = true,
  })
  if ok_img and img then
    M.modal.img = img
    pcall(function()
      img:render()
    end)
  end
end

local function apply_modal_resize()
  if not (M.modal and M.modal.win and vim.api.nvim_win_is_valid(M.modal.win)) then
    return
  end
  local width, height = modal_size(M.modal.scale)
  local row = math.floor((vim.o.lines - height) / 2) - 1
  local col = math.floor((vim.o.columns - width) / 2)

  vim.api.nvim_win_set_config(M.modal.win, {
    relative = "editor",
    style = "minimal",
    border = M.config.modal_border,
    row = math.max(0, row),
    col = math.max(0, col),
    width = width,
    height = height,
  })
  render_modal_image()
end

local function modal_zoom(delta)
  if not M.modal then
    return
  end
  M.modal.scale = math.max(0.4, math.min(2.0, M.modal.scale + delta))
  apply_modal_resize()
end

local function open_modal(path)
  local image = image_module()
  if not image then
    vim.notify("image.nvim is required for modal view", vim.log.levels.WARN)
    return
  end

  if vim.fn.filereadable(path) ~= 1 then
    vim.notify("Mermaid image not found: " .. path, vim.log.levels.WARN)
    return
  end

  close_modal()

  local width, height = modal_size(1.0)
  local row = math.floor((vim.o.lines - height) / 2) - 1
  local col = math.floor((vim.o.columns - width) / 2)

  local buf = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    style = "minimal",
    border = M.config.modal_border,
    row = math.max(0, row),
    col = math.max(0, col),
    width = width,
    height = height,
  })

  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false

  M.modal = {
    buf = buf,
    win = win,
    img = nil,
    path = path,
    scale = 1.0,
  }

  local function map(lhs, rhs)
    vim.keymap.set("n", lhs, rhs, { buffer = buf, nowait = true, silent = true })
  end

  map("q", close_modal)
  map("<Esc>", close_modal)
  map("+", function()
    modal_zoom(M.config.modal_zoom_step)
  end)
  map("=", function()
    modal_zoom(M.config.modal_zoom_step)
  end)
  map("-", function()
    modal_zoom(-M.config.modal_zoom_step)
  end)

  render_modal_image()
end

local function render_inline_in_buffer(file, bufnr)
  local out_dir = inline_out_dir(bufnr, file)
  local cmd = M.config.command .. " render " .. shellescape(file) .. " --out-dir " .. shellescape(out_dir)

  run_shell_async(cmd, function(code)
    if code ~= 0 then
      vim.notify("Mermaid render failed (exit " .. tostring(code) .. ")", vim.log.levels.WARN)
      return
    end

    local ok, err = render_images_in_buffer(bufnr, out_dir)
    if not ok and err then
      vim.notify("Mermaid inline render fallback: " .. err, vim.log.levels.WARN)
    end
  end)
end

local function open_modal_for_current(file, bufnr)
  local blocks = find_mermaid_blocks(bufnr)
  if #blocks == 0 then
    vim.notify("No mermaid block found in current buffer", vim.log.levels.INFO)
    return
  end

  local index = block_index_at_cursor(bufnr) or 1
  local out_dir = inline_out_dir(bufnr, file)
  local path = diagram_path(out_dir, index)

  if vim.fn.filereadable(path) == 1 then
    open_modal(path)
    return
  end

  local cmd = M.config.command .. " render " .. shellescape(file) .. " --out-dir " .. shellescape(out_dir)
  run_shell_async(cmd, function(code)
    if code ~= 0 then
      vim.notify("Mermaid render failed (exit " .. tostring(code) .. ")", vim.log.levels.WARN)
      return
    end
    open_modal(path)
  end)
end

function M.render(file, bufnr)
  local target = file or vim.api.nvim_buf_get_name(0)
  if target == "" then
    return
  end

  local current_buf = bufnr or vim.api.nvim_get_current_buf()

  if M.config.inline_in_buffer then
    render_inline_in_buffer(target, current_buf)
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
    run_shell_async(cmd)
  end
end

local function define_autocmd()
  local group = vim.api.nvim_create_augroup("MermaidInlineAuto", { clear = true })
  if not M.config.auto_render then
    return
  end

  vim.api.nvim_create_autocmd({ "BufWritePost", "BufEnter" }, {
    group = group,
    pattern = M.config.pattern,
    callback = function(args)
      M.render(args.file, args.buf)
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

  create_or_replace_user_command("MermaidInlineOpenPreview", function()
    M.open_preview()
  end, {})

  create_or_replace_user_command("MermaidInlineRender", function(cmd_opts)
    local file = cmd_opts.args ~= "" and cmd_opts.args or nil
    M.render(file)
  end, {
    nargs = "?",
    complete = "file",
  })

  create_or_replace_user_command("MermaidInlineOpenModal", function(cmd_opts)
    local bufnr = vim.api.nvim_get_current_buf()
    local file = cmd_opts.args ~= "" and cmd_opts.args or vim.api.nvim_buf_get_name(bufnr)
    if file == "" then
      vim.notify("No file to render", vim.log.levels.WARN)
      return
    end
    open_modal_for_current(file, bufnr)
  end, {
    nargs = "?",
    complete = "file",
  })

  create_or_replace_user_command("MermaidInlineToggleAuto", function()
    M.toggle_auto()
  end, {})
end

return M
