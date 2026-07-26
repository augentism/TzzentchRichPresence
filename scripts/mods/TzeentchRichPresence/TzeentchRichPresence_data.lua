local mod = get_mod("TzeentchRichPresence")

return {
	name = "TzeentchRichPresence",
	description = mod:localize("mod_description"),
	is_togglable = true,
	options = {
		widgets = {
			{
				setting_id = "debug_logging",
				type = "checkbox",
				default_value = false,
			},
		},
	},
}
