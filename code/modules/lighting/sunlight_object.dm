//todo: handle moving sunlight turfs - see various uses of get_turf in lighting_object


/*

Sunlight System

	Objects + Details
		Sunlight Objects (this file)
			- Grayscale version of lighting_object
			- Has 3 states
				- SUNLIGHT_INDOOR  (0)
					- Turfs that are indoors. Has no light themselves but is affected by SUNLIGHT_BORDER
				- SUNLIGHT_OUTDOOR (1)
					- Turfs that are outdoors, with no neighbouring SUNLIGHT_INDOOR tiles
					  Emits no light, but is fully white to display the overlay colour
				- SUNLIGHT_BORDER  (2)
					-Turfs that are outdoors, which neighbour at least one SUNLIGHT_INDOOR tile.
				     Emits light to indoor tiles, and fully white to display the overlay colour

		Sunlight Overlay
			- per client screen overlay. This handles the actual sunlight colour.

		Sunlight Subsystem
			- Handles the sunlight object update queue, and the sunlight overlay colours


	todo:
	Investigate having SUNLIGHT_INDOOR also place themselves on a different layer of the sunlight plane,
	so that we can have a weather effect overlay without displaying indoors

*/

/atom/movable/sunlight_object
	name = ""
	mouse_opacity = 0
	anchored = 1
	blend_mode		    	= BLEND_OVERLAY
	icon                	= LIGHTING_ICON
	icon_state          	= null
	plane 					= SUNLIGHTING_PLANE /* we put this on a lower level than lighting so we dont multiply anything */
	layer 					= SUNLIGHTING_LAYER
	invisibility 			= INVISIBILITY_LIGHTING
	color 					= LIGHTING_BASE_MATRIX

	var/hasCalcedSunlightSpread = TRUE

	// render_target 			= SUNLIGHTING_RENDER_TARGET

	/* misc vars */
	var/list/turf/neighbourTurfs = list()
	var/state 					 = SUNLIGHT_OUTDOOR
	var/turf/roofTurf
	var/turf/source_turf
	var/list/datum/lighting_corner/affectingCorners


/atom/movable/sunlight_object/Destroy(var/force)
	if (force)
		var/turf/badTurf = get_turf(source_turf)
		stack_trace("A sunlighting object has been deleted [COORD(badTurf)]")
		return ..()

	else
		return QDEL_HINT_LETMELIVE


/atom/movable/sunlight_object/Initialize(mapload)
	. = ..()
	source_turf = loc
	if (source_turf.sunlight_object)
		qdel(source_turf.sunlight_object, force = TRUE)
	source_turf.sunlight_object = src
	GLOB.sunlight_objects += src
	neighbourTurfs = GetNeighbours()

/atom/movable/sunlight_object/proc/GetState()
	var/oldState = state
	if(!(source_turf.has_opaque_atom || HasRoof() ))
		state = SUNLIGHT_OUTDOOR
		for(var/turf/CT in neighbourTurfs)
			if(CT.has_opaque_atom  || (CT.sunlight_object && CT.sunlight_object.HasRoof())) /* update our unroofed, unlighty friends */
				state = SUNLIGHT_BORDER
				break
	else /* roofed, so turn off the lights*/
		state = SUNLIGHT_INDOOR

	if(oldState != state)
		DisableSunlight()



/atom/movable/sunlight_object/proc/GetNeighbours()
	return RANGE_TURFS(1, source_turf)


/atom/movable/sunlight_object/proc/HasRoof()
	/* if we are a wall or have a ceiling, we are under a roof and considered indoors */
	if(istype(source_turf, /turf/closed) ||  source_turf.GetCeilingTurf())
		return TRUE
	return FALSE

/* run up the Z column until we hit a non openspace turf, or the top of the map */
/turf/proc/GetCeilingTurf()
	if (roofType)
		roofType = roofType /* already calculated */
	else
		var/turf/ceiling = get_step_multiz(src, UP)
		if(ceiling)
			roofType = !isopenspace(ceiling) ? ceiling : ceiling.GetCeilingTurf()
	return roofType

/atom/movable/sunlight_object/proc/DisableSunlight()
	for(var/datum/lighting_corner/C in affectingCorners)
		LAZYREMOVE(C.globAffect, src)
		C.getSunFalloff()
		GLOB.SUNLIGHT_QUEUE_CORNER += C.masters

/atom/movable/sunlight_object/proc/ProcessState()
	switch(state)
		if(SUNLIGHT_INDOOR)
			color = SUNLIGHT_DARK_MATRIX //get the dark thing
			luminosity = 0
		if(SUNLIGHT_OUTDOOR)
			color = SSsunlight.color //transparent
			luminosity = 1
		if(SUNLIGHT_BORDER)
			CalcSunlightSpread()
			color = SSsunlight.color //transparent
			luminosity = GLOB.GLOBAL_LIGHT_RANGE

/atom/movable/sunlight_object/proc/UpdateColour()

	if (state != SUNLIGHT_INDOOR)
		return /* full bright, not for me sorry */

	/* check if we are globally affected or not */
	var/static/datum/lighting_corner/dummy/dummy_lighting_corner = new


	var/datum/lighting_corner/cr = dummy_lighting_corner
	var/datum/lighting_corner/cg = dummy_lighting_corner
	var/datum/lighting_corner/cb = dummy_lighting_corner
	var/datum/lighting_corner/ca = dummy_lighting_corner

	cr = source_turf.corners[3] || dummy_lighting_corner
	cg = source_turf.corners[2] || dummy_lighting_corner
	cb = source_turf.corners[4] || dummy_lighting_corner
	ca = source_turf.corners[1] || dummy_lighting_corner

	var/fr = cr.sunFalloff
	var/fg = cg.sunFalloff
	var/fb = cb.sunFalloff
	var/fa = ca.sunFalloff

	#if LIGHTING_SOFT_THRESHOLD != 0
	luminosity = max(fr, fg, fb, fa) > LIGHTING_SOFT_THRESHOLD
	#else
	luminosity = max(fr, fg, fb, fa) > 1e-6
	#endif

	//anything that passes the first case is very likely to pass the second, and addition is a little faster in this case
	if((fr & fg & fb & fa) && (fr + fg + fb + fa == 4)) /* this will likely never happen */
		color = SSsunlight.color
	else if(!luminosity)
		color = SUNLIGHT_DARK_MATRIX
	else
		color = list(
					fr, fr, fr,  00 ,
					fg, fg, fg,  00 ,
					fb, fb, fb,  00 ,
					fa, fa, fa,  00 ,
					00, 00, 00,  01 )

#define hardSun 0.5 /* our hyperboloidy modifyer funky times -  */
/* calculate the indoor corners we are affecting */
#define SUN_FALLOFF(C, T) (1 - CLAMP01(sqrt((C.x - T.x) ** 2 + (C.y - T.y) ** 2 - hardSun) / max(1, GLOB.GLOBAL_LIGHT_RANGE)))


/atom/movable/sunlight_object/proc/CalcSunlightSpread(debug = FALSE)

	var/list/turf/turfs                    = list()
	var/datum/lighting_corner/C
	var/turf/T
	var/list/tempMasterList = list() /* to mimimize double ups */
	var/list/corners  = list() /* corners we are currently affecting */

	for(T in view(CEILING(GLOB.GLOBAL_LIGHT_RANGE, 1), source_turf))
		for(C in T.get_corners())
			corners |= C
			/* temp master? */
		turfs += T

	/* fix up the lists */
	/* add ourselves and our distance to the corner */
	LAZYINITLIST(affectingCorners)
	var/list/L = corners - affectingCorners
	affectingCorners += L
	for (C in L)
		LAZYSET(C.globAffect, src, SUN_FALLOFF(C,source_turf))
		if(C.globAffect[src] > C.sunFalloff) /* if are closer than current dist, update the corner */
			C.sunFalloff = C.globAffect[src]
			tempMasterList |= C.masters

	L = affectingCorners - corners // Now-gone corners, remove us from the affecting.
	affectingCorners -= L
	for (C in L)
		LAZYREMOVE(C.globAffect, src)
		C.getSunFalloff()
		tempMasterList |= C.masters /* update the dudes we just removed  */

	GLOB.SUNLIGHT_QUEUE_CORNER += tempMasterList /* update the boys */

/* Related object changes */
/* I moved this here to consolidate sunlight changes as much as possible, so its easily disabled */

/* area fuckery */
/area/var/turf/roofType

/* turf fuckery */
/turf/var/tmp/atom/movable/sunlight_object/sunlight_object /* a turf's sunlight overlay */
/turf/var/turf/roofType /* our roof turf - may be a path for top z level, or a ref to the turf above*/

/* moved this out of reconsider lights so we can call it in multiz refresh  */
/turf/proc/reconsider_sunlight()
	if(!SSlighting.initialized)
		return

	/* remove roof refs (not path for psuedo roof) so we can recalculate it */
	if(roofType && !ispath(roofType))
		roofType = null

	/* update sunlight */
	if(sunlight_object)
		GLOB.SUNLIGHT_QUEUE_WORK += sunlight_object

	var/datum/lighting_corner/C
	var/atom/movable/sunlight_object/S
	for(C in corners)
		for(S in C.globAffect)
			GLOB.SUNLIGHT_QUEUE_WORK += S

/* corner fuckery */
/datum/lighting_corner/var/list/globAffect = list() /* list of sunlight objects affecting this corner */
/datum/lighting_corner/var/sunFalloff = 0 /* smallest distance to sunlight turf, for sunlight falloff */
/* loop through our masters and find our strongest sunlight value */
/datum/lighting_corner/proc/getSunFalloff()
	sunFalloff = 0

	for(var/turf/T in masters)
		var/atom/movable/sunlight_object/S
		for(S in globAffect)
			sunFalloff = sunFalloff < globAffect[S] ? globAffect[S] : sunFalloff




/* Effect Fuckery */
/* these bits are to set the roof on a top-z level, as there is no turf above to act as a roof */
/obj/effect/mapping_helpers/sunlight/roofSetter
	icon_state = "roof"
	var/turf/roofType
	mountain
		roofType = /turf/closed/indestructible/rock
		icon_state = "roof_rock"
	wood
		roofType = /turf/open/floor/wood/f13
		icon_state = "roof_wood"


/obj/effect/mapping_helpers/sunlight/roofSetter/Initialize(mapload)
	. = ..()
	if(!mapload)
		log_mapping("[src] spawned outside of mapload!")
		return
	if(isturf(loc) && !get_step_multiz(loc, UP))
		var/turf/T = loc
		T.roofType = roofType
















#undef SUN_FALLOFF
#undef hardSun
