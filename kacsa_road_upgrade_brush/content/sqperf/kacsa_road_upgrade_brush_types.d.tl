-- Based on 'Bulk Bulldozer' by square17 (mod.io 6434884). Private build, not for publication.
recordDef = true

-- Types for Teal callers of content/sqperf/kacsa_road_upgrade_brush.lua.
-- Global names carry the mod's prefix (SquareBulkBulldozer): globals are shared by all loaded mods.
-- Usage: local sqperf = ug_require "kacsa_road_upgrade_brush::/sqperf/kacsa_road_upgrade_brush.lua" as SquareBulkBulldozerSqPerf

global record SquareBulkBulldozerSqPerfOptions
	mod : string
	ctx : string
	timed : boolean
	slowMs : number
	paramKey : string
	enabled : boolean
	gate : function() : boolean
	first : {string}
	initMs : number
	now : function() : number
end

global record SquareBulkBulldozerSqPerfInst
	mod : string
	ctx : string
	timed : boolean
	on : boolean
	slowMs : number
	start : function(self : SquareBulkBulldozerSqPerfInst) : number
	stop : function(self : SquareBulkBulldozerSqPerfInst, name : string, t0 : number) : number
	hit : function(self : SquareBulkBulldozerSqPerfInst, name : string)
	count : function(self : SquareBulkBulldozerSqPerfInst, name : string, n? : integer)
	-- detail: appended string, or a string.format pattern with its args (formatted only when logged)
	phase : function(self : SquareBulkBulldozerSqPerfInst, name : string, t0 : number, detail? : string, ...: any) : number
	wrap : function<F>(self : SquareBulkBulldozerSqPerfInst, name : string, fn : F) : F
end

global record SquareBulkBulldozerSqPerf
	VERSION : integer
	GUI_SLOW_MS : number
	SIM_SLOW_MS : number
	RATE_MS : number
	WINDOW_MS : number
	INIT_LOG_MS : number
	vm : string
	new : function(opts : SquareBulkBulldozerSqPerfOptions) : SquareBulkBulldozerSqPerfInst
	MASTER_MOD : string
	PARAM_KEY : string
	-- all: getModParams() or runFn's allModParams; key defaults to PARAM_KEY ("sqperf_log")
	debugOn : function(all : any, mod : string, key? : string) : boolean
	readParam : function(mod : string, key? : string) : boolean
end

recordDef = false
