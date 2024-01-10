const PI: f32 = 3.14159265359;
const PI2: f32 = PI * 2.0f;
const inv4PI: f32 = 1.0f / (4.0f * PI);
const PI_OVER_180: f32 = PI / 180.0f;
const COT_HALF_FOV: f32 = 1. / tan((37.5f) * PI_OVER_180);
const HALF_CUBE_SIZE = 0.5f;
const FULL_CUBE_SIZE = HALF_CUBE_SIZE * 2.0f;
const OCCLUSION_FACTOR: f32 = 0.095f;

struct RayMarchOut {
	color: vec4f,
	finalSamplePoint: vec3f,
	farthestMarchPoint: vec3f
}

struct ShaderOut {
	@location(0) presentation: vec4f,
	@location(1) lightAndDepth: vec4f
}

// TODO: replace with uniforms.
const uCubeOrigin = vec3f(0.0f, 0.0f, 0.0f);
const uCellSize = 0.85f;

//note: uniformly distributed, normalized rand, [0;1[
fn nrand(n: vec2f) -> f32
{
  return fract(sin(dot(n.xy, vec2f(12.9898, 78.233)))* 43758.5453);
}

fn n1rand(n: vec2f) -> f32
{
  return nrand(0.07 * fract(uT) + n);
}

fn sdBox(p: vec3f, b: vec3f) -> f32
{
	let q: vec3f = abs(p) - b;
	return length(max(q, vec3f(0.0f))) + min(max(q.x, max(q.y, q.z)), 0.0f);
}

fn getRay(uv: vec2f) -> vec4f
{
	let r = uWindowSize.x / uWindowSize.y;
	var xy: vec2f = uv - 0.5f;
	xy = vec2f(xy.x * r, xy.y);
	let z = 0.5f * COT_HALF_FOV;
	let ray = normalize(vec3f(xy, -z));
	return vec4f(ray, 0.0f);
}

// Googled:
fn intersectCube(origin: vec3f, ray: vec3f, cubeMin: vec3f, cubeMax: vec3f) -> vec2f
{
	let tMin = (cubeMin - origin) / ray;
	let tMax = (cubeMax - origin) / ray;
	let t1 = min(tMin, tMax);
	let t2 = max(tMin, tMax);
	let tNear: f32 = max(max(t1.x, t1.y), t1.z);
	let tFar: f32 = min(min(t2.x, t2.y), t2.z);
	return vec2f(tNear, tFar);
}

// ChatGPTed:
fn rayCubeIntersect(rayOrigin: vec3f, rayDirection: vec3f, cubeCenter: vec3f, cubeHalfExtents: vec3f) -> vec2f
{
    let invRayDir = 1.0 / rayDirection;
    let tMin = (cubeCenter - cubeHalfExtents - rayOrigin) * invRayDir;
    let tMax = (cubeCenter + cubeHalfExtents - rayOrigin) * invRayDir;

    let t1 = min(tMin, tMax);
    let t2 = max(tMin, tMax);

    let tNear = max(max(t1.x, t1.y), t1.z);
    let tFar = min(min(t2.x, t2.y), t2.z);

    return vec2f(tNear, tFar);
}

fn getCubeFaceNormal(intersectionPoint: vec3f, cubeOrigin: vec3f) -> vec3f
{
	var faceNormal = vec3f(0.0);

	let dirFromCubeOrigin = intersectionPoint - cubeOrigin;

	// Taking magnitudes to compare them further.
	let absDir = abs(dirFromCubeOrigin);

	// Finding maximum allows to get direction of the normal pointing at one of 3 the faces.
	let dirMax = max(max(absDir.x, absDir.y), absDir.z);

	// TODO: figure out how to do this wihtout ifs.
	if (absDir.x == dirMax)
	{
		faceNormal = vec3f(dirFromCubeOrigin.x, 0.0f, 0.0f);
	}
	else if (absDir.y == dirMax)
	{
		faceNormal = vec3f(0.0f, dirFromCubeOrigin.y, 0.0f);
	}
	else
	{
		faceNormal = vec3f(0.0f, 0.0f, dirFromCubeOrigin.z);
	}

	return normalize(faceNormal);
}

fn getCellIdx(cellCoords: vec3f) -> u32
{
	var x = u32(cellCoords.x);
	var y = u32(cellCoords.y);
	var z = u32(cellCoords.z);
	let u32Cols = u32(uGridSize.x);
	let u32Rows = u32(uGridSize.y);
	let u32Depth = u32(uGridSize.z);
	let layerSize = u32(uGridSize.x * uGridSize.y);

	return x + y * u32Cols + z * layerSize;
}

fn calculateLigtingAndOcclusionAt(samplePoint: vec3f, vUv: vec2f) -> vec4f
{
	var out = vec4f(0, 0, 0, 1);
	var occlusionFactor = 1.0f;
	let cellSize = FULL_CUBE_SIZE / uGridSize;
	let cellCoords = floor((samplePoint + HALF_CUBE_SIZE) / cellSize);
	let cellOrigin = cellCoords * cellSize + cellSize * 0.5f - HALF_CUBE_SIZE;
	let i = getCellIdx(cellCoords);
	let lightDir = normalize(lightSource.pos - samplePoint);
	let rndOffset = n1rand(vUv);

	// If sample point is occluded from light source by cube itself.
	// If light is at the angle larger 90deg with face normal, that face is not hit by direct light at all.
	let faceNormal = getCubeFaceNormal(samplePoint, cellOrigin);
	// if (dot(faceNormal, lightDir) < 0.0f)
	// {
	// 	occlusionFactor = OCCLUSION_FACTOR;
	// }
	// else
	// {
	// 	let volumeIntersect = rayCubeIntersect(samplePoint, lightDir, vec3f(0.0f), vec3f(HALF_CUBE_SIZE));
	// 	let volumeExit = samplePoint + lightDir * volumeIntersect.y;
	// 	occlusionFactor = rayMarchShadow(samplePoint, volumeExit, i, rndOffset, 10.0f);
	// }

	let c = cellCoords / uGridSize;
	let cellColor = vec4f(c.xy, 1f - c.x, 1f);
	out = calculateLigtingAt(samplePoint, cellOrigin, cellColor) * occlusionFactor;

	return out;
}

fn mixWithReprojectedPixel(currentSampleColor: vec4f, samplePos: vec3f, farthestMarchPos: vec3f, marchOrigin: vec3f) -> vec4f
{
	let prevFrameSamplePos: vec4f = uPrevProjViewMatInv * vec4f(samplePos, 1.0f);
	let curFrameSamplePos: vec4f = uProjViewMatInv * vec4f(samplePos, 1.0f);
	let currentMarchDepth = length(marchOrigin - samplePos);

	// Converting to clipspace ranged [-1, 1].
	let prevFrameSamplePosClipSpace = prevFrameSamplePos / prevFrameSamplePos.w;

	// Converting to [0, 1] range.
	// Note the .y component has to be flipped.
	// This is due to it going from top to bottom, rather than bottom to top, which we want.
	let uv: vec2f = vec2f(prevFrameSamplePosClipSpace.x, -prevFrameSamplePosClipSpace.y) * 0.5f + 0.5f;
	// let prevFrameShaderOut = textureSample(prevFrame, prevFrameSampler, uv);
	let prevFrameShaderOut = textureLoad(prevFrame, vec2i(uv * uWindowSize), 0);
	var prevFrameColor = vec4f(prevFrameShaderOut.xyz, 1.0f);
	var prevFrameMarchDepth = prevFrameShaderOut.w;

	// TODO: test if there are differences between textureSample and textureLoad.
	// var prevFrameColor = textureLoad(prevFrame, vec2i(uv * uWindowSize), 0);
	var temporalAlpha = 0.1f;
	// temporalAlpha = 1.f;

	// Only apply reprojection within the range of positive uvs.
	// Clamping does not matter here, since it's the pixels we care about not the values.
	// In pixel positions where uvs are negative we don't need reprojection.
	// Applying it there would cause ghosting, rather just leave the current sample as is.
	if (uv.x < 0.0f || uv.x > 1.0f || uv.y < 0.0f || uv.y > 1.0f)
	{
		prevFrameColor = currentSampleColor;
		prevFrameMarchDepth = currentMarchDepth;
	}

	if (all(samplePos == farthestMarchPos))
	{
		let cameraPos = viewMat[3].xyz;
		let prevCameraPos = uPrevViewMat[3].xyz;
		let MAX_NO_GHOST_V: f32 = .0025;
		let v: f32 = clamp(length(cameraPos - prevCameraPos), 0.0f, MAX_NO_GHOST_V) / MAX_NO_GHOST_V;
		temporalAlpha = mix(temporalAlpha, 1.0f, v);
	}

	var mixedColor = clamp(mix(prevFrameColor, currentSampleColor, temporalAlpha), vec4f(0.0f), vec4f(1.0f));

	// Discard previous depth if reprojected position changed. This means observer / camera moved.
	if (any(uPrevProjViewMatInv[0] != uProjViewMatInv[0]) ||
		any(uPrevProjViewMatInv[1] != uProjViewMatInv[1]) ||
		any(uPrevProjViewMatInv[2] != uProjViewMatInv[2]) ||
		any(uPrevProjViewMatInv[3] != uProjViewMatInv[3]))
	{
		// prevFrameMarchDepth = currentMarchDepth;
		prevFrameMarchDepth = clamp(mix(prevFrameMarchDepth, currentMarchDepth, temporalAlpha), 0.0f, 1.0f);
	}


	let minDepth = min(prevFrameMarchDepth, currentMarchDepth);

	return vec4f(mixedColor.xyz, minDepth);
}

fn calculateLigtingAt(samplePoint: vec3f, cellOrigin: vec3f, initialMaterialColor: vec4f) -> vec4f
{
	let faceNormal = getCubeFaceNormal(samplePoint, cellOrigin);
	let cameraPos = viewMat[3].xyz;
	let viewDir = normalize(samplePoint - cameraPos);

	// TODO: should dependant parameters be passed as arguments?
	let distanceToLight:f32 = distance(lightSource.pos, samplePoint);
	let distanceToLightFactor = max(1.0f, pow(distanceToLight, 2.0f));
	let distanceToCamera = distance(cameraPos, samplePoint);
	let distanceToCameraFactor = max(1.0f, pow(distanceToCamera, 2.0f));

	let incidentLight = lightSource.magnitude / distanceToLightFactor;
	let incidentLightDir = normalize(samplePoint - lightSource.pos);
	let reflectedLightDir = reflect(incidentLightDir, faceNormal);
	let reflectedLight = incidentLight * dot(reflectedLightDir, -viewDir);

	// Second term here (incidentLight * out.xyz) simulates diffuse light.
	let totalObservedSpectrum = (initialMaterialColor.xyz * reflectedLight + incidentLight * initialMaterialColor.xyz) / distanceToCameraFactor;

	// let out = vec4(out.xyz * incidentLight, out.w);
	let out = vec4f(totalObservedSpectrum, initialMaterialColor.w);
	// let out = vec4(faceNormal * incidentLight, initialMaterialColor.w);

	return out;
}

fn rayMarchShadow(start: vec3f, end: vec3f, cellIdx: u32, rndOffset: f32, steps: f32)-> f32
{
	var i: u32 = 0;
	var occlusionFactor: f32 = 1.0f;
	let dir = normalize(end - start);
	let marchDepth = length(end - start);
	var stepSize = marchDepth / steps;

	// TODO: to think how to optimize starting point for shadow marching.
	var depth = stepSize * rndOffset + 0.0025f;
	var samplePoint = vec3f(0.0f);
	var cellCoords = vec3f(0.0f);
	var cellOrigin = vec3f(0.0f);
	let cellSize = FULL_CUBE_SIZE / uGridSize;
	var s = steps;

	// while(depth < marchDepth && s >= 0.0f)
	while(depth < marchDepth)
	{
		// stepSize = pow(rndOffset, -s) * marchDepth - depth;
		// s = s - 1.0f;
		samplePoint = start + dir * depth;
		cellCoords = floor((samplePoint + HALF_CUBE_SIZE) / cellSize);
		cellOrigin = cellCoords * cellSize + cellSize * 0.5f - HALF_CUBE_SIZE;
		i = getCellIdx(cellCoords);

		if (i != cellIdx && cellStates[i] == 1)
		// if (cellStates[i] == 1)
		{
			occlusionFactor = OCCLUSION_FACTOR;
			break;
		}

		depth += stepSize;
	}

	return occlusionFactor;
}

fn rayMarch(start: vec3f, end: vec3f, vUv: vec2f, steps: f32) -> RayMarchOut
{
	var out: RayMarchOut;
	out.color = vec4f(0.0f, 0.0f, 0.0f, 1.0f);
	out.farthestMarchPoint = end;
	var i: u32 = 0;
	let dir = normalize(end - start);
	let marchDepth = length(end - start);
	let stepSize = marchDepth / steps;
	let rndOffset = n1rand(vUv);
	var depth = stepSize * rndOffset + 0.01f;
	var samplePoint = vec3f(0.0f);
	let cellSize = FULL_CUBE_SIZE / uGridSize;

	// Actual visible cell size might be smaller than the volume cell it is occupying.
	let actualVisibleCubeSize = cellSize * uCellSize * 0.5f;
	var cellCoords = vec3f(0.0f);
	var cellOrigin = vec3f(0.0f);
	var cellColor = vec4f(0.0f);
	var occlusionFactor: f32 = 1.0f;

	let uv = vec2<i32>(floor(vec2f(vUv.x, 1 - vUv.y) * uWindowSize));
	let prevFrameShaderOut = vec4f(textureLoad(prevFrame, uv, 0));

	// First before marching try to reuse depth from previously rendered frame.
	if (prevFrameShaderOut.w < marchDepth && prevFrameShaderOut.w > 0.0)
	{
		// depth = max(depth, prevFrameShaderOut.w);
		// samplePoint = start + dir * prevFrameShaderOut.w;
		// cellCoords = floor((samplePoint + HALF_CUBE_SIZE) / cellSize);
		// cellOrigin = cellCoords * cellSize + cellSize * 0.5f - HALF_CUBE_SIZE;
		// i = getCellIdx(cellCoords);
		// if (cellStates[i] == 1)
		// {
		// 	depth = max(depth, prevFrameShaderOut.w);
		// }
		// out.color = vec4f(1, 0, 0, 1);
		// out.finalSamplePoint = start + dir * depth;
		// return out;
	}

	while(depth < marchDepth)
	{
		samplePoint = start + dir * depth;
		out.finalSamplePoint = samplePoint;

		// Shifting inside the volume to calculate cells in [0, ... uGridSize] range.
		// As if the volume is completely in the positive domain.
		// TODO: improve this such that it takes into account volume's position.
		cellCoords = floor((samplePoint + HALF_CUBE_SIZE) / cellSize);
		cellOrigin = cellCoords * cellSize + cellSize * 0.5f - HALF_CUBE_SIZE;
		i = getCellIdx(cellCoords);

		if (cellStates[i] == 1)
		{
			// If we know we're in the cell that is active, the sample point might be anywhere relatively to the visible cube within it.
			// So we find an intersection point on the view ray and snap sample point to the cube.
			// This allows to get lighting calculations at correct point in space and thus reduce noise by making "hits" more accurate.
			let cellIntersectForward = rayCubeIntersect(start, dir, cellOrigin, actualVisibleCubeSize);

			if (cellIntersectForward.y >= 0.0f)
			{
				if (cellIntersectForward.x <= cellIntersectForward.y)
				{
					samplePoint = start + dir * cellIntersectForward.x;
					// if (prevFrameShaderOut.w < cellIntersectForward.x)
					// {
					// 	samplePoint = start + dir * prevFrameShaderOut.w;
					// }

					let lightDir = normalize(lightSource.pos - samplePoint);

					// If sample point is occluded from light source by cube itself.
					// If light is at the angle larger 90deg with face normal, that face is not hit by direct light at all.
					let faceNormal = getCubeFaceNormal(samplePoint, cellOrigin);
					if (dot(faceNormal, lightDir) < 0.0f)
					{
						occlusionFactor = OCCLUSION_FACTOR;
					}
					else
					{
						let volumeIntersect = rayCubeIntersect(samplePoint, lightDir, vec3f(0.0f), vec3f(HALF_CUBE_SIZE));
						let volumeExit = samplePoint + lightDir * volumeIntersect.y;
						occlusionFactor = rayMarchShadow(samplePoint, volumeExit, i, rndOffset, 10.0f);
					}

					let c = cellCoords / uGridSize;
					cellColor = vec4f(c.xy, 1f - c.x, 1f);
					out.color = calculateLigtingAt(samplePoint, cellOrigin, cellColor) * occlusionFactor;
					// if (prevFrameShaderOut.w < marchDepth)
					// {
					// 	out.color = vec4f(1, 0, 0, 1);
					// }
					// out.finalSamplePoint = samplePoint;

					// Use original depth to preserve depth buffer quality.
					out.finalSamplePoint = start + dir * depth;
					return out;
				}
			}

			// If we didn't hit anything it means visible cube is actually smaller than the cell it's occupying.
			// Just continue marching along the ray until we hit something.
		}

		depth += stepSize;
		// if (prevFrameShaderOut.w < marchDepth)
		// 	{
		// 		out.color = vec4f(1, 0, 0, 1);
		// 	}
	}

	out.finalSamplePoint = end;

	// Did we had a previously found depth that is closer than current march?
	// If so try to reuse it.
	// if (prevFrameShaderOut.w < marchDepth)
	// {
	// 	samplePoint = start + dir * prevFrameShaderOut.w;
	// 	cellCoords = floor((samplePoint + HALF_CUBE_SIZE) / cellSize);
	// 	cellOrigin = cellCoords * cellSize + cellSize * 0.5f - HALF_CUBE_SIZE;
	// 	i = getCellIdx(cellCoords);

	// 	if (cellStates[i] == 1)
	// 	{
	// 		// cellCoords = floor((samplePoint + HALF_CUBE_SIZE) / cellSize);
	// 		// cellOrigin = cellCoords * cellSize + cellSize * 0.5f - HALF_CUBE_SIZE;
	// 		// i = getCellIdx(cellCoords);
	// 		let lightDir = normalize(lightSource.pos - samplePoint);

	// 		// If sample point is occluded from light source by cube itself.
	// 		// If light is at the angle larger 90deg with face normal, that face is not hit by direct light at all.
	// 		let faceNormal = getCubeFaceNormal(samplePoint, cellOrigin);
	// 		if (dot(faceNormal, lightDir) < 0.0f)
	// 		{
	// 			occlusionFactor = OCCLUSION_FACTOR;
	// 		}
	// 		else
	// 		{
	// 			let volumeIntersect = rayCubeIntersect(samplePoint, lightDir, vec3f(0.0f), vec3f(HALF_CUBE_SIZE));
	// 			let volumeExit = samplePoint + lightDir * volumeIntersect.y;
	// 			occlusionFactor = rayMarchShadow(samplePoint, volumeExit, i, rndOffset, 10.0f);
	// 		}

	// 		let c = cellCoords / uGridSize;
	// 		cellColor = vec4f(c.xy, 1f - c.x, 1f);
	// 		out.color = calculateLigtingAt(samplePoint, cellOrigin, cellColor) * occlusionFactor;
	// 		// if (prevFrameShaderOut.w < marchDepth)
	// 		// {
	// 		// 	out.color = vec4f(1, 0, 0, 1);
	// 		// }
	// 		out.finalSamplePoint = samplePoint;
	// 		// out.color = vec4f(1, 0, 0, 1);
	// 		// out.finalSamplePoint = samplePoint;
	// 		// return out;
	// 	}

	// }

	return out;
}

@fragment
fn fragment_main(fragData: VertexOut) -> ShaderOut
{
	// var out: vec4f = vec4f(fragData.color.xy * fragData.cell, fragData.color.zw);
	// let c = fragData.cell / uGridSize.xy;
	// let c = fragData.cell / uGridSize;
	// var out: vec4f = vec4f(c.xy, 1f - c.x, 1f);
	var out = vec4f(0.0f, 0.0f, 0.0f, 1.0f);
	var shaderOut: ShaderOut;
	var rayMarchOut: RayMarchOut;

	let cameraPos = viewMat[3].xyz;
	// let viewDir = normalize(fragData.worldPosition.xyz - cameraPos);
	let viewRay = (viewMat * getRay(fragData.vUv)).xyz;

	let cubeIntersections = rayCubeIntersect(cameraPos, viewRay, vec3f(0.0f), vec3f(HALF_CUBE_SIZE));
	// let cubeIntersections = intersectCube(cameraPos, viewRay, vec3f(-0.5f), vec3f(0.5f));

	let cameraDistToBox = sdBox(cameraPos, vec3f(HALF_CUBE_SIZE));

	var cubeEnterPoint = cameraPos;
	var cubeExitPoint = cameraPos + viewRay * cubeIntersections.y;

	if (cubeIntersections.x <= cubeIntersections.y && cubeIntersections.y >= 0.0f)
	{
		if (cameraDistToBox >= 0.0f)
		{
			// Snap ray march starting point to first intersection with the cube.
			cubeEnterPoint = cameraPos + viewRay * cubeIntersections.x;
			// cubeExitPoint = cameraPos + viewRay * cubeIntersections.y;
		}

		rayMarchOut = rayMarch(cubeEnterPoint, cubeExitPoint, fragData.vUv, 25.0f);
		out = rayMarchOut.color;
		// out = vec4f(1.0f, 0.0f, 0.0f, 1.0f);
	}
	else
	{
		if (cubeIntersections.y < 0.0f)
		{
			// out = vec4f(0.0, 0.0, 1.0, 1.0);
		}
	}

	let lightIntersect = rayCubeIntersect(cameraPos, viewRay, lightSource.pos, vec3f(0.005f));

	if (lightIntersect.x <= lightIntersect.y && lightIntersect.y >= 0.0f)
	{
		if (all(out.xyz == vec3f(0.0f)))
		{
			out = vec4f(1.0f);
		}
	}

	// Gamma correction with 2.2f.
	out = vec4f(pow(out.xyz, vec3f(1 / 2.2f)), out.w);

	// Common buffer allignment tests.
	// out = vec4f(uCommonBuffer.data.f1, 1.0f);
	// out = vec4f(vec3f(uCommonBuffer.data.f0, 0, 0), 1.0f);

	// Temporal reprojection.
	let mixed = mixWithReprojectedPixel(out, rayMarchOut.finalSamplePoint, rayMarchOut.farthestMarchPoint, cubeEnterPoint);

	// TODO: this is due to sampling inside mixWithReprojectedPixel() has to be in uniform control flow.
	// Better ideas?
	if (cubeIntersections.x <= cubeIntersections.y && cubeIntersections.y >= 0.0f)
	{
		if (mixed.w < length(cubeExitPoint - cubeEnterPoint) - .1)
		{
			out = calculateLigtingAndOcclusionAt(cubeEnterPoint + viewRay * mixed.w, fragData.vUv);
		}
		out = vec4f(out.xyz, 1.0f);
		out = vec4f(pow(out.xyz, vec3f(1 / 2.2f)), out.w);
	}

	// let tex = textureSample(prevFrame, prevFrameSampler, fragData.vUv * 2.0f);

	if (fragData.vUv.x < 0.5f && fragData.vUv.y < 0.5f)
	{
		let uv = vec2<i32>(floor(vec2f(fragData.vUv.x * 2, 1 - fragData.vUv.y * 2) * uWindowSize));
		out = vec4f(vec3f(textureLoad(prevFrame, uv, 0).w), 1);
	}

	// let uv = vec2<i32>(floor(vec2f(fragData.vUv.x, 1 - fragData.vUv.y) * uWindowSize));
	// var d = textureLoad(prevFrame, uv, 0).w;
	// if (d == 0)
	// {
	// 	d = 1;
	// }

	shaderOut.presentation = out;
	shaderOut.lightAndDepth = vec4f(out.xyz, mixed.w);
	// shaderOut.lightAndDepth = vec4f(out.xyz, d);

	return shaderOut;
}
