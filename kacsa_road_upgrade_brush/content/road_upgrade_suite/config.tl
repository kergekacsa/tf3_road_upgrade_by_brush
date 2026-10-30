-- Based on 'Road Upgrade All in One' by kurowasiichi (mod.io 6487083). Private build, not for publication.
-- Road types of the tool and the vanilla street templates they use.
-- The variants with alley trees / noise barriers are the vanilla templates <base>_trees / <base>_barriers
-- (country roads have no trees variant). One-way streets only exist as new templates (from 1940).

local config : RusConfig = {
	roadTypes = {
		{ name = "rus_type_town_small", bases = { "town_new_small", "town_old_small" }, country = false },
		{ name = "rus_type_town_medium", bases = { "town_new_medium", "town_old_medium" }, country = false },
		{ name = "rus_type_town_large", bases = { "town_new_large", "town_old_large" }, country = false },
		{ name = "rus_type_country_small", bases = { "country_new_small", "country_old_small" }, country = true },
		{ name = "rus_type_country_medium", bases = { "country_new_medium", "country_old_medium" }, country = true },
		{ name = "rus_type_country_large", bases = { "country_new_large", "country_old_large" }, country = true },
		{ name = "rus_type_one_way_small", bases = { "town_new_one_way_small" }, country = false },
		{ name = "rus_type_one_way_medium", bases = { "town_new_one_way_medium" }, country = false },
	},
	TreesSuffix = "_trees",
	BarriersSuffix = "_barriers",
}

return config
