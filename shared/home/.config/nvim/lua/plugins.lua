vim.g.suda_smart_edit = 1
vim.pack.add({
	{ src = 'https://github.com/navarasu/onedark.nvim' },
	{ src = 'https://github.com/nvim-lualine/lualine.nvim' },
	{ src = 'https://github.com/nvim-tree/nvim-web-devicons' },
	{ src = 'https://github.com/neovim/nvim-lspconfig' },
	{ src = 'https://github.com/mason-org/mason.nvim' },
	{ src = 'https://github.com/WhoIsSethDaniel/mason-tool-installer.nvim' },
	{ src = 'https://github.com/nvim-treesitter/nvim-treesitter', version = 'main' },
	{ src = 'https://github.com/nvim-mini/mini.pick' },
	{ src = 'https://github.com/stevearc/oil.nvim' },
	{ src = 'https://github.com/Saghen/blink.cmp', version = 'v1.7.0' },
	{ src = 'https://github.com/akinsho/toggleterm.nvim' },
	{ src = 'https://github.com/folke/which-key.nvim' },
	{ src = 'https://github.com/lambdalisue/vim-suda' },
})

require('onedark').setup {
	style = 'warmer',
}
require('onedark').load()

require('config.lualine')

require('nvim-web-devicons').setup{}

require('mason').setup()
require('mason-tool-installer').setup({
	ensure_installed = {
		{ 'clangd', condition = function() return vim.fn.executable('clangd') == 0 end },
		'typescript-language-server',
		'tailwindcss-language-server',
		'oxlint',
		'json-lsp',
	}
})

vim.lsp.enable({
	'clangd',
	'ts_ls',
	'tailwindcss',
	'oxlint',
	'jsonls',
})

require('nvim-treesitter.config').setup({
	highlight = {
		enable = true,
		additional_vim_regex_highlighting = false,
	},
})

require('mini.pick').setup()

-- make oil keymaps mirror ones from mini
require('oil').setup({
	keymaps = {
		['<C-l>'] = false,
		['<C-S-r>'] = 'actions.refresh',
		['<C-h>'] = false,
		['<C-s>'] = { 'actions.select', opts = { horizontal = true } },
		['<C-v>'] = { 'actions.select', opts = { vertical = true } }
	},
})

require('blink.cmp').setup({
	-- 'default' (recommended) for mappings similar to built-in completions (C-y to accept)
	-- 'super-tab' for mappings similar to vscode (tab to accept)
	-- 'enter' for enter to accept
	-- 'none' for no mappings
	-- All presets have the following mappings:
	-- C-space: Open menu or open docs if already open
	-- C-n/C-p or Up/Down: Select next/previous item
	-- C-e: Hide menu
	-- C-k: Toggle signature help (if signature.enabled = true)
	-- See :h blink-cmp-config-keymap for defining your own keymap
	keymap = { preset = 'default' },
	appearance = {
		nerd_font_variant = 'normal'
	},
	completion = {
		menu = {
			border = 'none'
		},
		documentation = {
			window = {
				border = 'none'
			},
			auto_show = false
		},
		ghost_text = {
			enabled = true
		},
	},
	signature = {
		enabled = true,
		window = {
			border = 'none'
		}
	},
	fuzzy = {
		implementation = 'prefer_rust_with_warning'
	}
})

require('toggleterm').setup({
	persist_size = false,
	size = function(term)
		if term.direction == 'horizontal' then
			-- return math.floor(vim.api.nvim_get_option('lines') * 0.45)
			return 20
		elseif term.direction == 'vertical' then
			return math.floor(vim.api.nvim_get_option('columns') * 0.45)
		end
		return 20 -- fallback for float or others
	end,
})

vim.api.nvim_create_autocmd('VimResized', {
	callback = function()
		local terms = require('toggleterm.terminal').get_all()
		for _, t in pairs(terms) do
			if t:is_open() then
				t:close()
				t:open()
			end
		end
	end,
})

require('which-key').setup()