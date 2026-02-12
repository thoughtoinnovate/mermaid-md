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
  default_view_mode = "image", -- image|code
  image_width_cells = 80,
  toggle_key = "<leader>mt",
  modal_width_ratio = 0.85,
  modal_height_ratio = 0.85,
  modal_zoom_step = 0.15,
  modal_border = "rounded",
}

M.config = vim.deepcopy(defaults)
M.preview_job = nil
M.buffer_images = {}
M.buffer_state = {}
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

local function get_state(bufnr)
  if not M.buffer_state[bufnr] then
    M.buffer_state[bufnr] = {
      mode = M.config.default_view_mode,
      out_dir = nil,
      keymaps_set = false,
      win_fold_opts = {},
    }
  end
  return M.buffer_state[bufnr]
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
  local state = get_state(bufnr)
  if state.out_dir and state.out_dir ~= "" then
    vim.fn.mkdir(state.out_dir, "p")
    return state.out_dir
  end

  if M.config.inline_out_dir and M.config.inline_out_dir ~= "" then
    state.out_dir = M.config.inline_out_dir
    vim.fn.mkdir(state.out_dir, "p")
    return state.out_dir
  end

  local stem = vim.fn.fnamemodify(file, ":t:r")
  if stem == "" then
    stem = "buffer-" .. tostring(bufnr)
  end
  stem = stem:gsub("[^%w%-%_]+", "_")

  state.out_dir = vim.fn.stdpath("cache") .. "/mermaid-inline/" .. stem
  vim.fn.mkdir(state.out_dir, "p")
  return state.out_dir
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

local render_inline_in_buffer

local function close_modal()
  local modal = M.modal
  if modal and modal.img then
    pcall(function()
      modal.img:clear()
    end)
  end
  if modal and modal.win and vim.api.nvim_win_is_valid(modal.win) then
    pcall(vim.api.nvim_win_close, modal.win, true)
  end
  M.modal = nil

  if modal and modal.bufnr and modal.file and render_inline_in_buffer then
    local bufnr = modal.bufnr
    local file = modal.file
    if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr) ~= "" then
      local state = get_state(bufnr)
      if state.mode == "image" then
        vim.schedule(function()
          render_inline_in_buffer(file, bufnr)
        end)
      end
    end
  end
end

local function modal_size()
  local cols = vim.o.columns
  local lines = vim.o.lines - vim.o.cmdheight

  local w = math.max(20, math.floor(cols * M.config.modal_width_ratio))
  local h = math.max(6, math.floor(lines * M.config.modal_height_ratio))

  w = math.min(w, cols - 4)
  h = math.min(h, lines - 4)

  return w, h
end

local function render_modal_image()
  if not (M.modal and M.modal.win and M.modal.buf and vim.api.nvim_win_is_valid(M.modal.win)) then
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

  local win_width = vim.api.nvim_win_get_width(M.modal.win)
  local win_height = vim.api.nvim_win_get_height(M.modal.win)
  local usable_width = math.max(1, win_width - 2)
  local usable_height = math.max(1, win_height - 2)
  local zoom = M.modal.zoom or 1.0
  local img_width = math.max(1, math.floor(usable_width * zoom))
  local img_height = math.max(1, math.floor(usable_height * zoom))
  local x = math.max(0, math.floor((usable_width - img_width) / 2))
  local y = math.max(0, math.floor((usable_height - img_height) / 2))

  local ok_img, img = pcall(image.from_file, M.modal.path, {
    window = M.modal.win,
    buffer = M.modal.buf,
    x = x,
    y = y,
    width = img_width,
    max_width = img_width,
    height = img_height,
    max_height = img_height,
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
  local width, height = modal_size()
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
  M.modal.zoom = math.max(0.25, math.min(3.0, (M.modal.zoom or 1.0) + delta))
  render_modal_image()
end

local function open_modal(path, bufnr, file)
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

  if bufnr then
    clear_buffer_images(bufnr)
  end

  local width, height = modal_size()
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
    zoom = 1.0,
    bufnr = bufnr,
    file = file,
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

local function set_mermaid_folds(bufnr, blocks)
  local state = get_state(bufnr)
  local wins = vim.fn.win_findbuf(bufnr)

  for _, winid in ipairs(wins) do
    if not state.win_fold_opts[winid] then
      state.win_fold_opts[winid] = {
        foldmethod = vim.wo[winid].foldmethod,
        foldenable = vim.wo[winid].foldenable,
        foldlevel = vim.wo[winid].foldlevel,
      }
    end

    vim.wo[winid].foldmethod = "manual"
    vim.wo[winid].foldenable = true

    vim.api.nvim_win_call(winid, function()
      vim.cmd("silent! normal! zE")
      for _, block in ipairs(blocks) do
        vim.cmd(string.format("silent! %d,%dfold", block.start_line, block.end_line))
      end
      vim.cmd("silent! normal! zM")
    end)
  end
end

local function restore_folds(bufnr)
  local state = get_state(bufnr)
  local wins = vim.fn.win_findbuf(bufnr)

  for _, winid in ipairs(wins) do
    local saved = state.win_fold_opts[winid]
    if saved then
      vim.api.nvim_win_call(winid, function()
        vim.cmd("silent! normal! zE")
      end)
      vim.wo[winid].foldmethod = saved.foldmethod
      vim.wo[winid].foldenable = saved.foldenable
      vim.wo[winid].foldlevel = saved.foldlevel
      state.win_fold_opts[winid] = nil
    end
  end
end

local function render_images_in_buffer(bufnr, out_dir, blocks)
  local image = image_module()
  if not image then
    return false, "image.nvim is not available"
  end

  clear_buffer_images(bufnr)

  local wins = vim.fn.win_findbuf(bufnr)
  local current_win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_is_valid(current_win) and vim.api.nvim_win_get_buf(current_win) == bufnr then
    table.insert(wins, 1, current_win)
  end

  local seen = {}
  local final_wins = {}
  for _, winid in ipairs(wins) do
    if vim.api.nvim_win_is_valid(winid) and not seen[winid] then
      seen[winid] = true
      table.insert(final_wins, winid)
    end
  end

  if #final_wins == 0 then
    return false, "no visible window for markdown buffer"
  end

  local rendered_count = 0

  for _, winid in ipairs(final_wins) do
    local win_width = vim.api.nvim_win_get_width(winid)
    local x = math.max(0, math.floor((win_width - M.config.image_width_cells) / 2))

    for _, block in ipairs(blocks) do
      local path = diagram_path(out_dir, block.index)
      if vim.fn.filereadable(path) == 1 then
        local ok_img, img = pcall(image.from_file, path, {
          window = winid,
          buffer = bufnr,
          x = x,
          y = math.max(0, block.start_line - 2),
          with_virtual_padding = true,
        })
        if ok_img and img then
          local ok_render = pcall(function()
            img:render()
          end)
          if ok_render then
            rendered_count = rendered_count + 1
            table.insert(M.buffer_images[bufnr], img)
          end
        end
      end
    end
  end

  if rendered_count == 0 then
    return false, "no images rendered (check image.nvim backend and terminal support)"
  end

  return true
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
    open_modal(path, bufnr, file)
    return
  end

  local cmd = M.config.command .. " render " .. shellescape(file) .. " --out-dir " .. shellescape(out_dir)
  run_shell_async(cmd, function(code)
    if code ~= 0 then
      vim.notify("Mermaid render failed (exit " .. tostring(code) .. ")", vim.log.levels.WARN)
      return
    end
    open_modal(path, bufnr, file)
  end)
end

render_inline_in_buffer = function(file, bufnr)
  local state = get_state(bufnr)
  local blocks = find_mermaid_blocks(bufnr)

  if #blocks == 0 then
    clear_buffer_images(bufnr)
    restore_folds(bufnr)
    return
  end

  local out_dir = inline_out_dir(bufnr, file)
  local cmd = M.config.command .. " render " .. shellescape(file) .. " --out-dir " .. shellescape(out_dir)

  run_shell_async(cmd, function(code)
    if code ~= 0 then
      clear_buffer_images(bufnr)
      restore_folds(bufnr)
      vim.notify("Mermaid render failed (exit " .. tostring(code) .. ")", vim.log.levels.WARN)
      return
    end

    if state.mode == "image" then
      local ok, err = render_images_in_buffer(bufnr, out_dir, blocks)
      if not ok then
        clear_buffer_images(bufnr)
        restore_folds(bufnr)
      end
      if not ok and err then
        vim.notify("Mermaid inline render fallback: " .. err, vim.log.levels.WARN)
      end
      if ok then
        set_mermaid_folds(bufnr, blocks)
      end
    else
      clear_buffer_images(bufnr)
      restore_folds(bufnr)
    end
  end)
end

local function ensure_buffer_keymaps(bufnr)
  local state = get_state(bufnr)
  if state.keymaps_set then
    return
  end
  state.keymaps_set = true

  vim.keymap.set("n", M.config.toggle_key, function()
    local s = get_state(bufnr)
    s.mode = (s.mode == "image") and "code" or "image"
    local file = vim.api.nvim_buf_get_name(bufnr)
    if file ~= "" then
      render_inline_in_buffer(file, bufnr)
    end
    vim.notify("Mermaid view mode: " .. s.mode, vim.log.levels.INFO)
  end, { buffer = bufnr, silent = true, nowait = true })

  vim.keymap.set("n", "<CR>", function()
    local file = vim.api.nvim_buf_get_name(bufnr)
    if file ~= "" and block_index_at_cursor(bufnr) then
      vim.schedule(function()
        open_modal_for_current(file, bufnr)
      end)
      return
    end
    vim.cmd("normal! <CR>")
  end, { buffer = bufnr, silent = true })
end

function M.render(file, bufnr)
  local target = file or vim.api.nvim_buf_get_name(0)
  if target == "" then
    return
  end

  local current_buf = bufnr or vim.api.nvim_get_current_buf()
  ensure_buffer_keymaps(current_buf)

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

  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    pattern = M.config.pattern,
    callback = function(args)
      ensure_buffer_keymaps(args.buf)
      if M.config.auto_render then
        M.render(args.file, args.buf)
      end
    end,
  })

  if not M.config.auto_render then
    return
  end

  vim.api.nvim_create_autocmd("BufWritePost", {
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

  create_or_replace_user_command("MermaidInlineToggleView", function()
    local bufnr = vim.api.nvim_get_current_buf()
    local state = get_state(bufnr)
    state.mode = (state.mode == "image") and "code" or "image"
    local file = vim.api.nvim_buf_get_name(bufnr)
    if file ~= "" then
      render_inline_in_buffer(file, bufnr)
    end
    vim.notify("Mermaid view mode: " .. state.mode, vim.log.levels.INFO)
  end, {})

  create_or_replace_user_command("MermaidInlineToggleAuto", function()
    M.toggle_auto()
  end, {})
end

return M
