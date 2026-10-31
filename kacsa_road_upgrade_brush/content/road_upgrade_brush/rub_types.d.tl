-- Types of the road upgrade modules. Declarations only; nothing here runs in the game.
-- Every global name is prefixed Rus (globals are shared by all loaded mods).

--- A road type of the tool and the vanilla street template bases it uses.
global record RusRoadType
	name : string
	bases : {string}
	country : boolean
end

global record RusConfig
	roadTypes : {RusRoadType}
	TreesSuffix : string
	BarriersSuffix : string
end

global record RusTemplates
	resolve : function(roadType : RusRoadType, suffix : string, year : integer) : string
end

--- The options chosen in the tool menu.
global record RusChoices
	roadType : integer
	busLane : boolean
	tram : boolean
	catenary : boolean
	trees : boolean
	barrier : boolean
	lock : boolean
	symmetric : boolean
	underground : boolean
end

global record RusRules
	enum Problem
		"treesAndBarrier"
		"treesCountry"
		"noTemplate"
		"busTramLanes"
	end

	targetTemplate : function(choices : RusChoices, year : integer) : string
	check : function(choices : RusChoices, year : integer) : {RusRules.Problem}
end

global record RusOptions
	fromParams : function(params : {string : number}) : RusChoices
	params : function() : {ConstructionMenuParam}
end

global record RusAction
	install : function(toolResName : ResName)
end
