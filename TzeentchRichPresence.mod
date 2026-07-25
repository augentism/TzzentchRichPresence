return {
	run = function()
		fassert(rawget(_G, "new_mod"), "`TzeentchRichPresence` encountered an error loading the Darktide Mod Framework.")

		new_mod("TzeentchRichPresence", {
			mod_script       = "TzeentchRichPresence/scripts/mods/TzeentchRichPresence/TzeentchRichPresence",
			mod_data         = "TzeentchRichPresence/scripts/mods/TzeentchRichPresence/TzeentchRichPresence_data",
			mod_localization = "TzeentchRichPresence/scripts/mods/TzeentchRichPresence/TzeentchRichPresence_localization",
		})
	end,
	packages = {},
}
