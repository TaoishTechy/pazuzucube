g_PluginInfo =
{
	Name = "AGIAPI",
	Version = "1.0.0",
	Date = "2025-10-27",
	Description = "Parses CuberiteAGI Lua namespaces and emits JSON, Markdown, and EmmyLua documentation.",
	SourceRepo = "https://github.com/TaoishTechy/pazuzucube",
	Commands = {}, -- No player commands
	ConsoleCommands =
	{
		agiapi =
		{
			HelpString = "Generate AGI API documentation (JSON/MD/Emmy)",
			Handler = function(Split)
				-- Ensure the main execution function is available
				if _G.AGIAPI_Run then
					LOG("AGIAPI: Starting documentation generation...")
					_G.AGIAPI_Run()
					LOG("[AGIAPI] Documentation complete. Check Server/Plugins/AGIAPI/api/")
				else
					LOGERROR("[AGIAPI] AGIAPI_Run function not found. Plugin initialization error.")
				end
				return true
			end
		}
	}
}
