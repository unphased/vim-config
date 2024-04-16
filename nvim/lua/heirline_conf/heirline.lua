local conditions = require("heirline.conditions")
local utils = require("heirline.utils")

local colors = {
    bright_bg = utils.get_highlight("Folded").bg,
    bright_fg = utils.get_highlight("Folded").fg,
    red = utils.get_highlight("DiagnosticError").fg,
    dark_red = utils.get_highlight("DiffDelete").bg,
    green = utils.get_highlight("String").fg,
    blue = utils.get_highlight("Function").fg,
    gray = utils.get_highlight("NonText").fg,
    orange = utils.get_highlight("Constant").fg,
    purple = utils.get_highlight("Statement").fg,
    cyan = utils.get_highlight("Special").fg,
    diag_warn = utils.get_highlight("DiagnosticWarn").fg,
    diag_error = utils.get_highlight("DiagnosticError").fg,
    diag_hint = utils.get_highlight("DiagnosticHint").fg,
    diag_info = utils.get_highlight("DiagnosticInfo").fg,
    git_del = utils.get_highlight("DiffDelete").bg,
    git_add = utils.get_highlight("DiffAdd").bg,
    git_change = utils.get_highlight("DiffChange").bg,
}
-- the hex is needed to read these colors
-- vim.pretty_print(vim.tbl_map(function (v) return string.format("0x%06x", v) end, colors))

vim.cmd([[
  highlight DiffAdd guibg=#203520 guifg=NONE
  highlight DiffChange guibg=#13292e guifg=NONE
  " highlight DiffText guibg=#452250 guifg=NONE
  highlight DiffDelete guibg=#30181a guifg=NONE
]])

require('heirline').load_colors(colors)

local ViMode = {
    -- get vim current mode, this information will be required by the provider
    -- and the highlight functions, so we compute it only once per component
    -- evaluation and store it as a component attribute
    init = function(self)
        self.mode = vim.fn.mode(1) -- :h mode()

        -- execute this only once, this is required if you want the ViMode
        -- component to be updated on operator pending mode
        if not self.once then
            vim.api.nvim_create_autocmd("ModeChanged", {
                pattern = "*:*o",
                command = 'redrawstatus'
            })
            self.once = true
        end
    end,
    -- Now we define some dictionaries to map the output of mode() to the
    -- corresponding string and color. We can put these into `static` to compute
    -- them at initialisation time.
    static = {
        mode_names = { -- change the strings if you like it vvvvverbose!
            n = "N",
            no = "N?",
            nov = "N?",
            noV = "N?",
            ["no\22"] = "N?",
            niI = "Ni",
            niR = "Nr",
            niV = "Nv",
            nt = "Nt",
            v = "V",
            vs = "Vs",
            V = "V_",
            Vs = "Vs",
            ["\22"] = "^V",
            ["\22s"] = "^V",
            s = "S",
            S = "S_",
            ["\19"] = "^S",
            i = "I",
            ic = "Ic",
            ix = "Ix",
            R = "R",
            Rc = "Rc",
            Rx = "Rx",
            Rv = "Rv",
            Rvc = "Rv",
            Rvx = "Rv",
            c = "C",
            cv = "Ex",
            r = "...",
            rm = "M",
            ["r?"] = "?",
            ["!"] = "!",
            t = "T",
        },
        mode_colors = {
            n = "red" ,
            i = "green",
            v = "cyan",
            V =  "cyan",
            ["\22"] =  "cyan",
            c =  "orange",
            s =  "purple",
            S =  "purple",
            ["\19"] =  "purple",
            R =  "orange",
            r =  "orange",
            ["!"] =  "red",
            t =  "red",
        }
    },
    -- We can now access the value of mode() that, by now, would have been
    -- computed by `init()` and use it to index our strings dictionary.
    -- note how `static` fields become just regular attributes once the
    -- component is instantiated.
    -- To be extra meticulous, we can also add some vim statusline syntax to
    -- control the padding and make sure our string is always at least 2
    -- characters long. Plus a nice Icon.
    provider = function(self)
        return "%("..self.mode_names[self.mode].."%)"
    end,
    -- Same goes for the highlight. Now the foreground will change according to the current mode.
    hl = function(self)
        local mode = self.mode:sub(1, 1) -- get only the first mode character
        return { fg = self.mode_colors[mode], bold = true, }
    end,
    -- Re-evaluate the component only on ModeChanged event!
    -- This is not required in any way, but it's there, and it's a small
    -- performance improvement.
    update = {
        "ModeChanged",
    },
}

local FileNameBlockPre = {
    -- let's first set up some attributes needed by this component and it's children
    init = function(self)
        self.filename = vim.api.nvim_buf_get_name(0)
    end,
}
-- We can now define some children separately and add them later

local FileIcon = {
    init = function(self)
        local filename = self.filename
        local extension = vim.fn.fnamemodify(filename, ":e")
        self.icon, self.icon_color = require("nvim-web-devicons").get_icon_color(filename, extension, { default = true })
    end,
    hl = function(self)
        return { fg = self.icon_color }
    end,
    flexible = 5,
    {
        provider = function(self)
            return self.icon and (self.icon .. " ")
        end,
    },
    {
        provider = "",
    },
}

-- local FileName = {
--     provider = function(self)
--         -- first, trim the pattern relative to the current directory. For other
--         -- options, see :h filename-modifers
--         local filename = vim.fn.fnamemodify(self.filename, ":.")
--         if filename == "" then return "[No Name]" end
--         -- now, if the filename would occupy more than 1/4th of the available
--         -- space, we trim the file path to its initials
--         -- See Flexible Components section below for dynamic truncation
--         if not conditions.width_percent_below(#filename, 0.25) then
--             filename = vim.fn.pathshorten(filename)
--         end
--         return filename
--     end,
--     hl = { fg = utils.get_highlight("Directory").fg },
-- }

local FileFlags = {
    {
        condition = function()
            return vim.bo.modified
        end,
        provider = "● ",
        hl = { fg = "green" },
    },
    {
        condition = function()
            return not vim.bo.modifiable or vim.bo.readonly
        end,
        provider = "",
        hl = { fg = "orange" },
    },
}

local FileName = {
    init = function(self)
        self.lfilename = vim.fn.fnamemodify(self.filename, ":.")
        if self.lfilename == "" then self.lfilename = "[No Name]" end
    end,
    hl = { fg = utils.get_highlight("Directory").fg, bold = true },

    flexible = 1000,
    -- TODO decide if this expanding chain is really useful since it does make it copy into a useless path)
    {
        provider = function(self)
            return self.lfilename .. " "
        end,
    },
    {
        provider = function(self)
            return vim.fn.pathshorten(self.lfilename, 4) .. " "
        end,
    },
    {
        provider = function(self)
            return vim.fn.pathshorten(self.lfilename, 3) .. " "
        end,
    },
    {
        provider = function(self)
            return vim.fn.pathshorten(self.lfilename, 2) .. " "
        end,
    },
    {
        provider = function(self)
            return vim.fn.pathshorten(self.lfilename, 1) .. " "
        end,
    }
}


-- Now, let's say that we want the filename color to change if the buffer is
-- modified. Of course, we could do that directly using the FileName.hl field,
-- but we'll see how easy it is to alter existing components using a "modifier"
-- component

local FileNameModifer = {
    hl = function()
        if vim.bo.modified then
            -- use `force` because we need to override the child's hl foreground
            return { fg = "cyan", bold = true, force=true }
        end
    end,
}

-- let's add the children to our FileNameBlock component
FileNameBlock = utils.insert(FileNameBlockPre,
    utils.insert(FileNameModifer, FileName), -- a new table where FileName is a child of FileNameModifier
    FileFlags,
    FileIcon,
    { provider = '%<'} -- this means that the statusline is cut here when there's not enough space
)

local FileType = {
    hl = { fg = utils.get_highlight("Type").fg, bold = true },
    flexible = 6,
    {
        provider = function()
            return string.upper(vim.bo.filetype)
        end,
    },
    { provider = "" }
}

local FileTypeSpace = {
    hl = { fg = utils.get_highlight("Type").fg, bold = true },
    flexible = 6,
    {
        provider = function()
            return string.upper(vim.bo.filetype) .. " "
        end,
    },
    { provider = "" }
}

local FileEncodingSpace = {
    provider = function()
        local enc = (vim.bo.fenc ~= '' and vim.bo.fenc) or vim.o.enc -- :h 'enc'
        return enc ~= 'utf-8' and enc:upper()
    end
}
local FileFormatSpace = {
    provider = function()
        -- local fmt = vim.bo.fileformat
        -- return fmt ~= 'unix' and fmt:upper()
        return vim.bo.fileformat .. " "
    end
}

local FileSize = {
    flexible = 5,
    {
        provider = function()
            -- stackoverflow, compute human readable file size
            local suffix = { 'B', 'K', 'M', 'G', 'T', 'P', 'E' }
            local fsize = vim.fn.getfsize(vim.api.nvim_buf_get_name(0))
            fsize = (fsize < 0 and 0) or fsize
            if fsize < 1024 then
                return fsize .. suffix[1]
            end
            local i = math.floor((math.log(fsize) / math.log(1024)))
            local format = "%.0f%s"
            local scaled_fsize = fsize / math.pow(1024, i)
            if scaled_fsize < 10 then
                format = "%.2f%s"
            elseif scaled_fsize < 100 then
                format = "%.1f%s"
            end
            return string.format(format, scaled_fsize, suffix[i + 1]) .. ' '
        end
    }, {
        provider = ""
    }
}
local FileLastModified = {
    -- did you know? Vim is full of functions!
    provider = function()
        local ftime = vim.fn.getftime(vim.api.nvim_buf_get_name(0))
        return (ftime > 0) and os.date("%c", ftime)
    end
}

local RulerLineNo = {
    provider = "%l",
    hl = { bold = true }
}

local RulerRestSpace = {
    -- %l = current line number
    -- %L = number of lines in the buffer
    -- %c = column number
    -- %P = percentage through file of displayed window
    flexible = 7,
    {
        provider = "/%L:%c %P "
    }, {
        provider = "/%L:%c "
    }, {
        provider = ":%c "
    }, {
        provider = " "
    }
}

local prose = require 'nvim-prose'
-- Additional info that belongs in ruler but need a lower prio 
local RulerExtraSpace = {
    flexible = 4,
    {
        provider = function ()
            local wc = prose.word_count()
            local rt = prose.reading_time()
            return wc .. " " .. rt .. " %o 0x%02B "
        end
    },
    {
        -- %o = byte offset of cursor in the file
        -- 0x%02B = cursor's byte value shown in hex
        provider = "%o 0x%02B "
    },
    {
        provider = "%o %02B "
    },
    {
        provider = "%o "
    },
    {
        provider = ""
    }
}

-- I take no credits for this! :lion:
local ScrollBar = {
    static = {
        -- The original (with my modification):
        -- sbar = { '█', '▇', '▆', '▅', '▄', '▃', '▂', '▁', ' ' }
        -- My invention (17):
        -- sbar = { '  ', ' ⢀', ' ⢠', ' ⢰', ' ⢸', ' ⣸', ' ⣼', ' ⣾', ' ⣿', '⢀⣿', '⢠⣿', '⢰⣿', '⢸⣿', '⣸⣿', '⣼⣿', '⣾⣿', '⣿⣿'  }
        -- Using three (25):
        -- sbar = { '', '⢀', '⢠', '⢰', '⢸', '⣸', '⣼', '⣾', '⣿', '⢀⣿', '⢠⣿', '⢰⣿', '⢸⣿', '⣸⣿', '⣼⣿', '⣾⣿', '⣿⣿', '⢀⣿⣿', '⢠⣿⣿', '⢰⣿⣿', '⢸⣿⣿', '⣸⣿⣿', '⣼⣿⣿', '⣾⣿⣿', '⣿⣿⣿'  }
        -- Animate the dots falling down to fill the space. Adds a lot of additional states while grabbing a char back. (41)
        sbar = { '', '⠁', '⠂', '⠄', '⡀', '⡈', '⡐', '⡠', '⣀', '⣁', '⣂', '⣄', '⣌', '⣔', '⣤', '⣥', '⣦', '⣮', '⣶', '⣷', '⣿', '⠈⣿', '⠐⣿', '⠠⣿', '⢀⣿', '⢁⣿', '⢂⣿', '⢄⣿', '⣀⣿', '⣈⣿', '⣐⣿', '⣠⣿', '⣡⣿', '⣢⣿', '⣤⣿', '⣬⣿', '⣴⣿', '⣵⣿', '⣶⣿', '⣾⣿', '⣿⣿' }
        -- The beauty of this one is that by filling columns separately, 50% still looks like 50%
    },
    flexible = 8,
    {
        provider = function(self)
            local curr_line = vim.api.nvim_win_get_cursor(0)[1]
            local lines = vim.api.nvim_buf_line_count(0)
            local i = math.floor((curr_line - 1) / lines * #self.sbar) + 1
            return self.sbar[i]
        end,
        hl = { fg = "blue" },
    },
    {
        provider = ""
    }
}

local LSPActive = {
    hl = { fg = "green", bold = false },

    -- You can keep it simple,
    -- provider = " [LSP]",

    -- Or complicate things a bit and get the servers names
    flexible = 2,
    {
        condition = conditions.lsp_attached,
        update = {'LspAttach', 'LspDetach'},
        provider = function()
            local names = {}
            for _, server in pairs(vim.lsp.get_active_clients({ bufnr = 0 })) do
                table.insert(names, server.name)
            end
            return " " .. table.concat(names, " ") .. " "
        end,
    },
    {
        condition = conditions.lsp_attached,
        update = {'LspAttach', 'LspDetach'},
        provider = function()
            local count = 0
            for _, server in pairs(vim.lsp.get_active_clients({ bufnr = 0 })) do
                count = count + 1
            end
            return " " .. count .. " "
        end,
    }, {
        condition = conditions.lsp_attached,
        update = {'LspAttach', 'LspDetach'},
        provider = " "
    }, { provider = "" }
}

-- I personally use it only to display progress messages!
-- See lsp-status/README.md for configuration options.

-- Note: check "j-hui/fidget.nvim" for a nice statusline-free alternative.
-- local LSPMessages = {
--     provider = require("lsp-status").status,
--     hl = { fg = "gray" },
-- }

-- Awesome plugin

-- The easy way.
-- local Navic = {
--     condition = function() return require("nvim-navic").is_available() end,
--     provider = function()
--         require("nvim-navic").get_location({highlight=true})
--     end,
--     update = 'CursorMoved'
-- }

-- Full nerd (with icon colors and clickable elements)!
-- works in multi window, but does not support flexible components (yet ...)
-- local Navic = {
--     condition = require("nvim-navic").is_available,
--     static = {
--         -- create a type highlight map
--         type_hl = {
--             File = "Directory",
--             Module = "@include",
--             Namespace = "@namespace",
--             Package = "@include",
--             Class = "@structure",
--             Method = "@method",
--             Property = "@property",
--             Field = "@field",
--             Constructor = "@constructor",
--             Enum = "@field",
--             Interface = "@type",
--             Function = "@function",
--             Variable = "@variable",
--             Constant = "@constant",
--             String = "@string",
--             Number = "@number",
--             Boolean = "@boolean",
--             Array = "@field",
--             Object = "@type",
--             Key = "@keyword",
--             Null = "@comment",
--             EnumMember = "@field",
--             Struct = "@structure",
--             Event = "@keyword",
--             Operator = "@operator",
--             TypeParameter = "@type",
--         },
--         -- bit operation dark magic, see below...
--         enc = function(line, col, winnr)
--             return bit.bor(bit.lshift(line, 16), bit.lshift(col, 6), winnr)
--         end,
--         -- line: 16 bit (65535); col: 10 bit (1023); winnr: 6 bit (63)
--         dec = function(c)
--             local line = bit.rshift(c, 16)
--             local col = bit.band(bit.rshift(c, 6), 1023)
--             local winnr = bit.band(c,  63)
--             return line, col, winnr
--         end
--     },
--     init = function(self)
--         local data = require("nvim-navic").get_data() or {}
--         local children = {}
--         -- create a child for each level
--         for i, d in ipairs(data) do
--             -- encode line and column numbers into a single integer
--             local pos = self.enc(d.scope.start.line, d.scope.start.character, self.winnr)
--             local child = {
--                 {
--                     provider = d.icon,
--                     hl = self.type_hl[d.type],
--                 },
--                 {
--                     -- escape `%`s (elixir) and buggy default separators
--                     provider = d.name:gsub("%%", "%%%%"):gsub("%s*->%s*", ''),
--                     -- highlight icon only or location name as well
--                     -- hl = self.type_hl[d.type],
--
--                     on_click = {
--                         -- pass the encoded position through minwid
--                         minwid = pos,
--                         callback = function(_, minwid)
--                             -- decode
--                             local line, col, winnr = self.dec(minwid)
--                             vim.api.nvim_win_set_cursor(vim.fn.win_getid(winnr), {line, col})
--                         end,
--                         name = "heirline_navic",
--                     },
--                 },
--             }
--             -- add a separator only if needed
--             if #data > 1 and i < #data then
--                 table.insert(child, {
--                     provider = " > ",
--                     hl = { fg = 'bright_fg' },
--                 })
--             end
--             table.insert(children, child)
--         end
--         -- instantiate the new child, overwriting the previous one
--         self.child = self:new(children, 1)
--     end,
--     -- evaluate the children containing navic components
--     provider = function(self)
--         return self.child:eval()
--     end,
--     hl = { fg = "gray" },
--     update = 'CursorMoved'
-- }

local Diagnostics = {

    condition = conditions.has_diagnostics,

    on_click = {
        callback = function()
            -- I just open the Trouble window by calling :TroubleToggle
            require("trouble").toggle()
        end,
        name = "open_diags"
    },

    static = {
        -- error_icon = vim.fn.sign_getdefined("DiagnosticSignError")[1].text,
        -- warn_icon = vim.fn.sign_getdefined("DiagnosticSignWarn")[1].text,
        -- info_icon = vim.fn.sign_getdefined("DiagnosticSignInfo")[1].text,
        -- hint_icon = vim.fn.sign_getdefined("DiagnosticSignHint")[1].text,
        error_icon = "✘ ",
        warn_icon = "▲ ",
        info_icon = " ",
        hint_icon = "⚑ ",
    },

    init = function(self)
        self.errors = #vim.diagnostic.get(0, { severity = vim.diagnostic.severity.ERROR })
        self.warnings = #vim.diagnostic.get(0, { severity = vim.diagnostic.severity.WARN })
        self.hints = #vim.diagnostic.get(0, { severity = vim.diagnostic.severity.HINT })
        self.info = #vim.diagnostic.get(0, { severity = vim.diagnostic.severity.INFO })
    end,

    flexible = 20,
    {
        update = { "DiagnosticChanged", "BufEnter" },
        {
            provider = function(self)
                -- 0 is just another output, we can decide to print it or not!
                return self.errors > 0 and (self.error_icon .. self.errors .. " ")
            end,
            hl = { fg = "diag_error" },
        },
        {
            provider = function(self)
                return self.warnings > 0 and (self.warn_icon .. self.warnings .. " ")
            end,
            hl = { fg = "diag_warn" },
        },
        {
            provider = function(self)
                return self.info > 0 and (self.info_icon .. self.info .. " ")
            end,
            hl = { fg = "diag_info" },
        },
        {
            provider = function(self)
                return self.hints > 0 and (self.hint_icon .. self.hints .. " ")
            end,
            hl = { fg = "diag_hint" },
        },
    },
    {
        update = { "DiagnosticChanged", "BufEnter" },
        {
            provider = function(self)
                -- 0 is just another output, we can decide to print it or not!
                return self.errors > 0 and (self.error_icon .. self.errors .. " ")
            end,
            hl = { fg = "diag_error" },
        },
        {
            provider = function(self)
                return self.warnings > 0 and (self.warn_icon .. self.warnings .. " ")
            end,
            hl = { fg = "diag_warn" },
        },
        {
            provider = function(self)
                return self.info > 0 and (self.info_icon .. self.info .. " ")
            end,
            hl = { fg = "diag_info" },
        },
    },
    {
        update = { "DiagnosticChanged", "BufEnter" },
        {
            provider = function(self)
                -- 0 is just another output, we can decide to print it or not!
                return self.errors > 0 and (self.error_icon .. self.errors .. " ")
            end,
            hl = { fg = "diag_error" },
        },
        {
            provider = function(self)
                return self.warnings > 0 and (self.warn_icon .. self.warnings .. " ")
            end,
            hl = { fg = "diag_warn" },
        },
    },
    {
        update = { "DiagnosticChanged", "BufEnter" },
        {
            provider = function(self)
                -- 0 is just another output, we can decide to print it or not!
                return self.errors > 0 and (self.error_icon .. self.errors .. " ")
            end,
            hl = { fg = "diag_error" },
        },

    }
}

-- Let's say that you'd like to have only the diagnostic icon colored, not the actual count. Just replace the children with something like this.

-- ...
--     {
--         condition = function(self) return self.errors > 0 end,
--         {
--             provider = function(self) return self.error_icon end,
--             hl = { fg = "diag_error" },
--         },
--         {
--             provider = function(self) return self.errors .. " " end,
--         }
--     },
-- ...

-- Diagnostics = utils.surround({"![", "]"}, nil, Diagnostics)

local GitSpace = {
    condition = conditions.is_git_repo,

    init = function(self)
        self.status_dict = vim.b.gitsigns_status_dict
        self.has_changes = self.status_dict.added ~= 0 or self.status_dict.removed ~= 0 or self.status_dict.changed ~= 0
    end,

    hl = { fg = "orange" },
    flexible = 15,
    {
        utils.surround({ "", "" }, "status_bubble_bg", {
            {   -- git branch name
                provider = function(self)
                    return " " .. self.status_dict.head
                end,
                hl = { bold = true }
            },
            -- You could handle delimiters, icons and counts similar to Diagnostics
            {
                condition = function(self)
                    return self.has_changes
                end,
                provider = " "
            },
            {
                provider = function(self)
                    local count = self.status_dict.added or 0
                    return count > 0 and ("+" .. count)
                end,
                hl = { fg = "git_add" },
            },
            {
                provider = function(self)
                    local count = self.status_dict.removed or 0
                    return count > 0 and ("-" .. count)
                end,
                hl = { fg = "git_del" },
            },
            {
                provider = function(self)
                    local count = self.status_dict.changed or 0
                    return count > 0 and ("~" .. count)
                end,
                hl = { fg = "git_change" },
            },
        }), {
            provider = " ",
        },
    },
    {
        utils.surround({ "", "" }, "status_bubble_bg", {
            {   -- git branch name
                provider = function(self)
                    return " " .. self.status_dict.head
                end,
                hl = { bold = true }
            },
        }), {
            provider = " ",
        },
    },
    { provider = "" }
}

-- local DAPMessages = {
--     condition = function()
--         local session = require("dap").session()
--         return session ~= nil
--     end,
--     provider = function()
--         return " " .. require("dap").status()
--     end,
--     hl = "Debug"
--     -- see Click-it! section for clickable actions
-- }

-- local UltTest = {
--     condition = function()
--         return vim .api.nvim_call_function("ultest#is_test_file", {}) ~= 0
--     end,
--     static = {
--         passed_icon = vim.fn.sign_getdefined("test_pass")[1].text,
--         failed_icon = vim.fn.sign_getdefined("test_fail")[1].text,
--         passed_hl = { fg = utils.get_highlight("UltestPass").fg },
--         failed_hl = { fg = utils.get_highlight("UltestFail").fg },
--     },
--     init = function(self)
--         self.status = vim.api.nvim_call_function("ultest#status", {})
--     end,
--
--     -- again, if you'd like icons and numbers to be colored differently,
--     -- just split the component in two
--     {
--         provider = function(self)
--             return self.passed_icon .. self.status.passed .. " "
--         end,
--         hl = function(self)
--             return self.passed_hl
--         end,
--     },
--     {
--         provider = function(self)
--             return self.failed_icon .. self.status.failed .. " "
--         end,
--         hl = function(self)
--             return self.failed_hl
--         end,
--     },
--     {
--         provider = function(self)
--             return "of " .. self.status.tests - 1
--         end,
--     },
-- }

local TerminalName = {
    -- we could add a condition to check that buftype == 'terminal'
    -- or we could do that later (see #conditional-statuslines below)
    provider = function()
        local tname, _ = vim.api.nvim_buf_get_name(0):gsub(".*:", "")
        return " " .. tname
    end,
    hl = { fg = "blue", bold = true },
}

local HelpFileName = {
    condition = function()
        return vim.bo.filetype == "help"
    end,
    provider = function()
        local filename = vim.api.nvim_buf_get_name(0)
        return vim.fn.fnamemodify(filename, ":t")
    end,
    hl = { fg = colors.blue },
}

-- local luasnip = require('luasnip')

-- local Snippets = {
--     -- check that we are in insert or select mode
--     condition = function()
--         return vim.tbl_contains({'s', 'i'}, vim.fn.mode())
--     end,
--     provider = function()
--         local forward = luasnip.expand_or_jumpable() and "" or ""
--         local backward = luasnip.jumpable(-1) and " " or ""
--         return backward .. forward
--     end,
--     hl = { fg = "red", bold = true },
-- }

local Spell = {
    condition = function()
        return vim.wo.spell
    end,
    provider = 'SPELL ',
    hl = { bold = true, fg = "orange"}
}

local WorkDir = {
    init = function(self)
        self.icon = (vim.fn.haslocaldir(0) == 1 and "l " or "") .. " "
        local cwd = vim.fn.getcwd(0)
        self.cwd = vim.fn.fnamemodify(cwd, ":~")
    end,
    hl = { fg = utils.get_highlight("Directory").fg },

    flexible = 1,
    {
        -- evaluates to the full-length path
        provider = function(self)
            local trail = self.cwd:sub(-1) == "/" and "" or "/"
            return self.icon .. self.cwd .. trail
        end,
    },
    {
        -- evaluates to the shortened path (TODO decide if this is useful since it does make it copy into a useless path)
        provider = function(self)
            local cwd = vim.fn.pathshorten(self.cwd)
            local trail = self.cwd:sub(-1) == "/" and "" or "/"
            return self.icon .. cwd .. trail
        end,
    },
    {
        -- evaluates to "", hiding the component
        provider = "",
    }
}

local Navic = { flexible = 3, Navic, { provider = "" } }

local Align = { provider = "%=" }
local Space = { provider = " " }

ViMode = utils.surround({ "", "" }, "status_bubble_bg", { ViMode })

local LazySpace = {
    condition = function()
        local ok, lazy_status = pcall(require, "lazy.status")
        return ok and lazy_status.has_updates()
    end,
    on_click = {
        callback = function () require('lazy').update() end,
        name = "update_plugins"
    },
    hl = "Error",
    flexible = 3,
    {
        provider = function()
            return require("lazy.status").updates() .. " "
        end
    },
    {
        provider = ""
    }
}

local SearchCount = {
    condition = function()
        return vim.v.hlsearch ~= 0 and vim.o.cmdheight == 0
    end,
    init = function(self)
        local ok, search = pcall(vim.fn.searchcount)
        if ok and search.total then
            self.search = search
        end
    end,
    provider = function(self)
        local search = self.search
        return string.format("[%d/%d] ", search.current, math.min(search.total, search.maxcount))
    end,
}

-- only shows when cmdheight is 0
local MacroRecShowIfCmdHidden = {
    condition = function()
        return vim.fn.reg_recording() ~= "" and vim.o.cmdheight == 0
    end,
    provider = " ",
    hl = { fg = "orange", bold = true },
    utils.surround({ "[", "] " }, nil, {
        provider = function()
            return vim.fn.reg_recording()
        end,
        hl = { fg = "green", bold = true },
    }),
}

-- Spacing convention: 
-- Items to the left of Align are to put their spaces to the left, items to the right put their spaces on the right, etc. All components need to have a space included so that no stacking of spaces takes place.
local DefaultStatusline = {
    -- TODO make the workdir and filename render out in separate styles for visual distinction but allow copying an abspath
    ViMode, Space, LazySpace, GitSpace, Diagnostics, LSPActive, Align, WorkDir,
    FileNameBlock, Align, FileTypeSpace, SearchCount, MacroRecShowIfCmdHidden, RulerExtraSpace, FileSize, RulerLineNo, RulerRestSpace, ScrollBar
}

local InactiveStatusline = {
    condition = conditions.is_not_active,
    Align, WorkDir, FileNameBlock, Space, Align, FileTypeSpace, RulerLineNo, RulerRestSpace
}

local SpecialStatusline = {
    condition = function()
        return conditions.buffer_matches({
            buftype = {
                "nofile",
                "prompt",
                "help",
                "quickfix"
            },
            filetype = { "^git.*", "fugitive" },
        })
    end,

    FileType, Space, HelpFileName, Align
}

local TerminalStatusline = {

    condition = function()
        return conditions.buffer_matches({ buftype = { "terminal" } })
    end,

    hl = { bg = "dark_red" },

    -- Quickly add a condition to the ViMode to only show it when buffer is active!
    { condition = conditions.is_active, ViMode, Space }, FileType, Space, TerminalName, Align,
}

local StatusLines = {

    hl = function()
        if conditions.is_active() then
            return "StatusLine"
        else
            return "StatusLineNC"
        end
    end,

    -- the first statusline with no condition, or which condition returns true is used.
    -- think of it as a switch case with breaks to stop fallthrough.
    fallthrough = false,

    SpecialStatusline, TerminalStatusline, InactiveStatusline, DefaultStatusline,
}

local WinBars = {
    fallthrough = false,
    {   -- A special winbar for terminals
        condition = function()
            return conditions.buffer_matches({ buftype = { "terminal" } })
        end,
        utils.surround({ "", "" }, "dark_red", {
            FileType,
            Space,
            TerminalName,
        }),
    },
    {   -- An inactive winbar for regular files
        condition = function()
            return not conditions.is_active()
        end,
        utils.surround({ "", "" }, "bright_bg", { hl = { fg = "gray", force = true }, FileNameBlock }),
    },
    -- A winbar for regular files
    utils.surround({ "", "" }, "bright_bg", FileNameBlock),
}

local TablineBufnr = {
    provider = function(self)
        return " " .. tostring(self.bufnr) .. " "
    end,
    hl = "Comment",
}

-- we redefine the filename component, as we probably only want the tail and not the relative path
local TablineFileName = {
    provider = function(self)
        local filename = self.filename
        if filename == "" then
            return "[No Name]"
        elseif string.find(filename, "/index%.[tj]s$") then
            -- Extract the last directory name
            local last_dir = filename:match(".*/(.*)/index%.[tj]s$")
            -- If the last directory name is found, format it accordingly
            if last_dir then
                return last_dir .. "/i"
            else
                return "i" -- Fallback if no directory is found
            end
        else
            -- Just return the file name for non-index files
            return vim.fn.fnamemodify(filename, ":t")
        end
    end,
    hl = function(self)
        return { bold = self.is_active or self.is_visible, italic = true }
    end,
}

-- this looks exactly like the FileFlags component that we saw in
-- #crash-course-part-ii-filename-and-friends, but we are indexing the bufnr explicitly
-- also, we are adding a nice icon for terminal buffers.
local TablineFileFlags = {
    {
        condition = function(self)
            return vim.api.nvim_buf_get_option(self.bufnr, "modified")
        end,
        provider = " ● ",
        hl = { fg = "cyan" },

    },
    {
        condition = function(self)
            return not vim.api.nvim_buf_get_option(self.bufnr, "modifiable")
                or vim.api.nvim_buf_get_option(self.bufnr, "readonly")
        end,
        provider = function(self)
            if vim.api.nvim_buf_get_option(self.bufnr, "buftype") == "terminal" then
                return "  "
            else
                return " "
            end
        end,
        hl = { fg = "orange" },
    },
}

-- Here the filename block finally comes together
local TablineFileNameBlock = {
    init = function(self)
        self.filename = vim.api.nvim_buf_get_name(self.bufnr)
    end,
    hl = function(self)
        if self.is_active then
            return "TabLineSel"
        -- why not?
        elseif not vim.api.nvim_buf_is_loaded(self.bufnr) then
            return { fg = "gray" }
        else
            return "TabLine"
        end
    end,
    on_click = {
        callback = function(_, minwid, _, button)
            if (button == "m") then -- close on mouse middle click
                vim.api.nvim_buf_delete(minwid, {force = false})
            else
                vim.api.nvim_win_set_buf(0, minwid)
            end
        end,
        minwid = function(self)
            return self.bufnr
        end,
        name = "heirline_tabline_buffer_callback",
    },
    -- TablineBufnr,
    FileIcon, -- turns out the version defined in #crash-course-part-ii-filename-and-friends can be reutilized as is here!
    TablineFileName,
    TablineFileFlags,
}

-- a nice "x" button to close the buffer
local TablineCloseButton = {
    condition = function(self)
        return not vim.api.nvim_buf_get_option(self.bufnr, "modified")
    end,
    { provider = " " },
    {
        provider = "\u{2715}",
        hl = { fg = "gray" },
        on_click = {
            callback = function(_, minwid)
                vim.api.nvim_buf_delete(minwid, { force = false })
            end,
            minwid = function(self)
                return self.bufnr
            end,
            name = "heirline_tabline_close_buffer_callback",
        },
    },
}

-- The final touch!
local TablineBufferBlock = utils.surround({ "", "" }, function(self)
    if self.is_active then
        return utils.get_highlight("TabLineSel").bg
    else
        return utils.get_highlight("TabLine").bg
    end
end, { TablineFileNameBlock, TablineCloseButton })

-- this is the default function used to retrieve buffers
local get_bufs = function()
    return vim.tbl_filter(function(bufnr)
        return vim.api.nvim_buf_get_option(bufnr, "buflisted")
    end, vim.api.nvim_list_bufs())
end

-- initialize the buflist cache
local buflist_cache = {}

-- setup an autocmd that updates the buflist_cache every time that buffers are added/removed
vim.api.nvim_create_autocmd({ "BufAdd", "BufDelete" }, {
    callback = function()
        vim.schedule(function()
            local buffers = get_bufs()
            for i, v in ipairs(buffers) do
                buflist_cache[i] = v
            end
            for i = #buffers + 1, #buflist_cache do
                buflist_cache[i] = nil
            end

            -- check how many buffers we have and set showtabline accordingly
            if #buflist_cache > 1 then
                vim.o.showtabline = 2 -- always
            else
                vim.o.showtabline = 1 -- only when #tabpages > 1
            end
        end)
    end,
})

local BufferLine = utils.make_buflist(
    TablineBufferBlock,
    { provider = " ", hl = { fg = "gray" } },
    { provider = " ", hl = { fg = "gray" } },
    -- out buf_func simply returns the buflist_cache
    function()
        return buflist_cache
    end,
    -- no cache, as we're handling everything ourselves
    false
)

local Tabpage = {
    provider = function(self)
        return "%" .. self.tabnr .. "T " .. self.tabpage .. " %T"
    end,
    hl = function(self)
        if not self.is_active then
            return "TabLine"
        else
            return "TabLineSel"
        end
    end,
}

local TabpageClose = {
    provider = "%999X \u{2715} %X",
    hl = "TabLine",
}

local TabPages = {
    -- only show this component if there's 2 or more tabpages
    condition = function()
        return #vim.api.nvim_list_tabpages() >= 2
    end,
    { provider = "%=" },
    utils.make_tablist(Tabpage),
    TabpageClose,
}

local TabLineOffset = {
    condition = function(self)
        local win = vim.api.nvim_tabpage_list_wins(0)[1]
        local bufnr = vim.api.nvim_win_get_buf(win)
        self.winid = win

        if vim.bo[bufnr].filetype == "NvimTree" then
            self.title = "NvimTree"
            return true
        -- elseif vim.bo[bufnr].filetype == "TagBar" then
        --     ...
        end
    end,

    provider = function(self)
        local title = self.title
        local width = vim.api.nvim_win_get_width(self.winid)
        local pad = math.ceil((width - #title) / 2)
        return string.rep(" ", pad) .. title .. string.rep(" ", pad)
    end,

    hl = function(self)
        if vim.api.nvim_get_current_win() == self.winid then
            return "TablineSel"
        else
            return "Tabline"
        end
    end,
}

local TabLine = { TabLineOffset, BufferLine, TabPages }

require("heirline").setup({
    statusline = StatusLines,
    -- Honestly I just dont see the point of a winbar. earlier winbar code from an earlier coobook combined with updated heirline caused popups to break in a really weird way. I updated the config now, so this is no longer a thing, but i still have not found a reason to bring it back and much rather have one more row of real estate.
    -- winbar = WinBars,
    tabline = TabLine,
    -- statuscolumn = nil,
    opts = {
        -- -- if the callback returns true, the winbar will be disabled for that window
        -- -- the args parameter corresponds to the table argument passed to autocommand callbacks. :h nvim_lua_create_autocmd()
        -- disable_winbar_cb = function(args)
        --     return conditions.buffer_matches({
        --         buftype = { "nofile", "prompt", "help", "quickfix" },
        --         filetype = { "^git.*", "fugitive", "Trouble", "dashboard" },
        --     }, args.buf)
        -- end,
    },
})

-- Yep, with heirline we're driving manual!
vim.cmd([[au FileType * if index(['wipe', 'delete'], &bufhidden) >= 0 | set nobuflisted | endif]])

local function setup_colors()
    return {
        bright_bg = utils.get_highlight("Folded").bg,
        status_bubble_bg = "#196768",
        bright_fg = utils.get_highlight("Folded").fg,
        red = utils.get_highlight("DiagnosticError").fg,
        dark_red = utils.get_highlight("DiffDelete").bg,
        green = utils.get_highlight("String").fg,
        blue = utils.get_highlight("Function").fg,
        gray = utils.get_highlight("NonText").fg,
        orange = utils.get_highlight("Constant").fg,
        purple = utils.get_highlight("Statement").fg,
        cyan = utils.get_highlight("Special").fg,
        diag_warn = utils.get_highlight("DiagnosticWarn").fg,
        diag_error = utils.get_highlight("DiagnosticError").fg,
        diag_hint = utils.get_highlight("DiagnosticHint").fg,
        diag_info = utils.get_highlight("DiagnosticInfo").fg,
        git_del = utils.get_highlight("DiffDelete").fg,
        git_add = utils.get_highlight("DiffAdd").fg,
        git_change = utils.get_highlight("DiffChange").fg,
    }
end
require('heirline').load_colors(setup_colors())

vim.api.nvim_create_augroup("Heirline", { clear = true })
vim.api.nvim_create_autocmd("ColorScheme", {
    callback = function()
        local colors = setup_colors()
        utils.on_colorscheme(colors)
    end,
    group = "Heirline",
})
