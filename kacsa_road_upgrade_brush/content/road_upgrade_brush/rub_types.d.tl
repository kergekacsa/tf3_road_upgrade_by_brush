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
end

global record RubChoices
	roadType : integer
	busLane : boolean
	tram : boolean
	catenary : boolean
	trees : boolean
	barrier : boolean
	lock : string       -- "keep" | "lock" | "unlock"
	symmetric : boolean
	underground : boolean
end

global record RubRules
	enum Problem
		"treesAndBarrier"
		"treesCountry"
		"noTemplate"
		"busTramLanes"
	end

	targetTemplate : function(choices : RubChoices, year : integer) : string
	check : function(choices : RubChoices, year : integer) : {RubRules.Problem}
end

global record RubOptions
	fromParams : function(params : {string : number}) : RubChoices
	params : function() : {ConstructionMenuParam}
end
