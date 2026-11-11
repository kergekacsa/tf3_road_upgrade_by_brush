-- Based on 'Road Upgrade All in One' by kurowasiichi (mod.io 6487083).
-- Global names use the prefix Rub: globals are shared by all loaded mods.

global record RubRoadType
	name : string
	bases : {string}
	country : boolean
end

global record RubConfig
	roadTypes : {RubRoadType}
	TreesSuffix : string
	BarriersSuffix : string
end

global record RubTemplates
	resolve : function(roadType : RubRoadType, suffix : string, year : integer) : string
	--- The name of a street template without its path and ending: "::/infrastructure/street/town/town_new_large.street_template" is "town_new_large".
	baseName : function(resName : string) : string
	--- Whether the street template exists and is available in the year.
	isAvailable : function(resName : string, year : integer) : boolean
	--- The resource name of the street template with the short name ("town_new_large_trees"), in any year. nil when the game has none.
	find : function(name : string) : string
end

--- The Roads choices of the toolbar. An add-on state is "keep", "add" or "remove".
global record RubChoices
	roadType : integer  -- an index in `config.roadTypes`; 0 = Keep road type
	busLane : string
	tram : string
	catenary : string   -- "keep" while the toolbar hides the choice
	trees : string
	barrier : string
	lock : string       -- "keep" | "lock" | "unlock"
	underground : boolean
end

global record RubRules
	enum Problem
		"treesAndBarrier"
		"treesCountry"
		"noTemplate"
		"busTramLanes"
	end

	--- The problems of the choices that hold for every road. A problem that depends on the road is a reason of its plan.
	check : function(choices : RubChoices, year : integer) : {RubRules.Problem}
end

global record RubOptions
	fromParams : function(params : {string : number}) : RubChoices
	params : function() : {ConstructionMenuParam}
end
