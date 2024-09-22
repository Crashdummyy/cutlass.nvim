local debug = require("cutlass.debug")
local lspconfig = require("lspconfig")
local api = vim.api
local M = {}

---@param table   table e.g., { foo = { bar = "z" } }
---@param section string indicating the field of the table, e.g., "foo.bar"
---@return any|nil setting value read from the table, or `nil` not found
function M.lookup_section(table, section)
	if table[section] ~= nil then
		return table[section]
	end

	local keys = vim.split(section, ".", { plain = true }) --- @type string[]
	return vim.tbl_get(table, unpack(keys))
end

function M.get_cutlass_client()
	local clients = vim.lsp.get_clients({ name = "cutlass" })

	if clients and clients[1] then
		return clients[1]
	end
end

---@param state ProjectedBufState
function M.attach_lsps(state, handlers, html_config, cs_config)
	--- Attach LSP client to the buffer manually if not attached
	---@param buf integer
	local function attach_lsp_clients(buf, filetype, config)
		debug.log_message("attach lsp clients bufnr: " .. buf)

		-- Iterate over all available LSPs for the current buffer
		local clients = vim.lsp.get_clients({ bufnr = buf })

		if #clients == 0 then
			debug.log_message("Manually starting LSP for buffer: " .. buf)
			-- reference to the real buffer
			local real_buf = api.nvim_get_current_buf()
			-- we need to set the active buffer to the projected buffer and then start the lsp

			-- if we provide a config, use that
			-- if we don't provide a config then try to use lspconfig (which will attach omnisharp for cs...idk)
			if not config and lspconfig[filetype] then
				lspconfig[filetype].setup({
					handlers = vim.tbl_extend("force", vim.lsp.handlers, handlers),
				})
				config = lspconfig[filetype]

				assert(config ~= nil, "Failed to load configuration for " .. filetype)
			end
			api.nvim_set_current_buf(buf)
			vim.lsp.start(config)
			api.nvim_set_current_buf(real_buf)
		else
			-- Clients already attached, log them
			for _, client in ipairs(clients) do
				debug.log_message("LSP client already attached: " .. client.name)
			end
		end
	end

	local function attach_roslyn(bufnr)
		local real_buf = api.nvim_get_current_buf()

		api.nvim_set_current_buf(bufnr)
		vim.api.nvim_exec_autocmds("BufEnter", { buffer = state.proj_cs_bufnr })
		api.nvim_set_current_buf(real_buf)
	end

	-- Use the root_dir from the parent buffer or fallback to the working directory
	state.root_dir = state.root_dir

	-- TODO make the starting a strategy we pass in as a function
	-- Attach LSPs to the HTML projected buffer
	attach_lsp_clients(state.proj_html_bufnr, "html", nil)
	attach_roslyn(state.proj_cs_bufnr)

	-- attach_lsp_clients(state.proj_cs_bufnr, "cs", {})
end

function M.monkeyPatchSemanticTokens(client)
  -- make sure this happens once per client, not per buffer
  if not client.is_hacked_roslyn then
    client.is_hacked_roslyn = true

    -- let the runtime know the server can do semanticTokens/full now
    if client.server_capabilities.semanticTokensProvider then
        client.server_capabilities = vim.tbl_deep_extend("force", client.server_capabilities, {
            semanticTokensProvider = {
                full = true,
            },
        })
    end

    -- -- monkey patch the request proxy
    local request_inner = client.request
    client.request = function(method, params, handler, req_bufnr)
        if method ~= vim.lsp.protocol.Methods.textDocument_semanticTokens_full then
            return request_inner(method, params, handler, req_bufnr)
        end

        local function find_buf_by_uri(search_uri)
            local bufs = vim.api.nvim_list_bufs()
            for _, buf in ipairs(bufs) do
                local name = vim.api.nvim_buf_get_name(buf)
                local uri = "file://" .. name
                if uri == search_uri then
                    return buf
                end
            end
        end

        local doc_uri = params.textDocument.uri

        local target_bufnr = find_buf_by_uri(doc_uri)
        local line_count = vim.api.nvim_buf_line_count(target_bufnr)
        local last_line = vim.api.nvim_buf_get_lines(target_bufnr, line_count - 1, line_count,
            true)[1]

        return request_inner("textDocument/semanticTokens/range", {
                textDocument = params.textDocument,
                range = {
                    ["start"] = {
                        line = 0,
                        character = 0,
                    },
                    ["end"] = {
                        line = line_count - 1,
                        character = string.len(last_line) - 1,
                    },
                },
            },
            handler,
            req_bufnr
        )
    end
  end
end


return M
