@fragment
fn fragment_main (fragData: VertexOut) -> @location(0) vec4f
{
	// var out: vec4f = vec4f(fragData.color.xy * fragData.cell, fragData.color.zw);
	// let c = fragData.cell / colsRows.xy;
	let c = fragData.cell / colsRows;
	var out: vec4f = vec4f(c.xy, 1f - c.x, 1f);

	let cameraPos = viewMat[3].xyz;
	let viewDir = normalize(fragData.worldPosition.xyz - cameraPos);

	let distanceToLight:f32 = distance(lightSource.pos, fragData.worldPosition.xyz);
	let distanceToLightFactor = max(1.0f, pow(distanceToLight, 2.0f));
	let distanceToCamera = distance(cameraPos, fragData.worldPosition.xyz);
	let distanceToCameraFactor = max(1.0f, pow(distanceToCamera, 2.0f));


	let incidentLight = lightSource.magnitude / distanceToLightFactor;
	let incidentLightDir = normalize(fragData.worldPosition.xyz - lightSource.pos);
	let reflectedLightDir = reflect(incidentLightDir, fragData.normal);
	let reflectedLight = incidentLight * dot(reflectedLightDir, -viewDir);

	// Second term here (incidentLight * out.xyz) simulates diffuse light.
	let totalObservedSpectrum = (out.xyz * reflectedLight + incidentLight * out.xyz) / distanceToCameraFactor;

	// out = vec4(out.xyz * incidentLight, out.w);
	out = vec4(totalObservedSpectrum, out.w);
	// out = vec4(fragData.normal, out.w);

	if (fragData.pointerIdx == fragData.instance && cellStates[fragData.instance] != 1)
	{
		out = vec4f(out.xyz * 0.5f, out.w);

		// This is not supported by WGSL atm.
		// out.xyz *= 0.5f;
	}

	// Gamma correction with 2.2f.
	out = vec4f(pow(out.xyz, vec3f(1 / 2.2f)), out.w);

	return out;
}
