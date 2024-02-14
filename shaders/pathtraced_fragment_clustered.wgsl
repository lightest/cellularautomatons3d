@group(0) @binding(0) var<uniform> uGridSize: vec3f;
@group(0) @binding(11) var<uniform> uCommonUniformsBuffer: CommonBufferLayout;

@group(1) @binding(0) var prevFrame: texture_2d<f32>;
@group(1) @binding(1) var depthBuffer: texture_2d<f32>;
@group(1) @binding(2) var prevFrameSampler: sampler;

@group(2) @binding(0) var<storage> cellStates: array<u32>;

struct LightSource {
	pos: vec3f,
	magnitude: f32
};

// Alignment 16 bytes, order of elements matters.
// See https://www.w3.org/TR/WGSL/#alignment-and-size
struct CommonBufferLayout {
	lightSource: LightSource,
	viewMat: mat4x4f,
	projViewMatInv: mat4x4f,
	prevViewMat: mat4x4f,
	prevProjViewMatInv: mat4x4f,
	windowSize: vec2f,
	elapsedTime: f32,
	depthSamples: f32,
	shadowSamples: f32,
	cellSize: f32,
	showDepthBuffer: f32
};

struct VertexOut {
	@builtin(position) position: vec4f,
	// @location(0) color: vec4f,
	@location(1) worldPosition: vec4f,
	@location(2) cell: vec3f,
	@location(4) @interpolate(flat) instance: u32,
	@location(5) normal: vec3f,
	@location(6) worldNormal: vec3f,
	@location(7) vUv: vec2f
}

struct RayMarchOut {
	color: vec4f,
	finalSamplePoint: vec3f,
	farthestMarchPoint: vec3f
}

struct CellData {
	cellOrigin: vec3f,
	idx: u32,
	cellCoords: vec3u
}

struct ShaderOut {
	@location(0) presentation: vec4f,
	@location(1) light: vec4f,
	@location(2) depth: vec2f
}

const PI: f32 = 3.14159265359;
const PI2: f32 = PI * 2.0f;
const inv4PI: f32 = 1.0f / (4.0f * PI);
const PI_OVER_180: f32 = PI / 180.0f;
const COT_HALF_FOV: f32 = 1. / tan((37.5f) * PI_OVER_180);
const HALF_CUBE_SIZE = 0.5f;
const FULL_CUBE_SIZE = HALF_CUBE_SIZE * 2.0f;
const OCCLUSION_FACTOR: f32 = 0.095f;

// TODO: replace with uniforms.
const uCubeOrigin = vec3f(0.0f, 0.0f, 0.0f);

// Extracting bit wise data from u32.
const masks = array<u32, 32>(
	1u,
	2u,
	4u,
	8u,
	16u,
	32u,
	64u,
	128u,
	256u,
	512u,
	1024u,
	2048u,
	4096u,
	8192u,
	16384u,
	32768u,
	65536u,
	131072u,
	262144u,
	524288u,
	1048576u,
	2097152u,
	4194304u,
	8388608u,
	16777216u,
	33554432u,
	67108864u,
	134217728u,
	268435456u,
	536870912u,
	1073741824u,
	2147483648u
);

//note: uniformly distributed, normalized rand, [0;1[
fn nrand(n: vec2f) -> f32
{
  return fract(sin(dot(n.xy, vec2f(12.9898, 78.233)))* 43758.5453);
}

fn n1rand(n: vec2f) -> f32
{
  return nrand(0.07 * fract(uCommonUniformsBuffer.elapsedTime) + n);
}

fn sdBox(p: vec3f, b: vec3f) -> f32
{
	let q: vec3f = abs(p) - b;
	return length(max(q, vec3f(0.0f))) + min(max(q.x, max(q.y, q.z)), 0.0f);
}

fn getRay(uv: vec2f) -> vec4f
{
	let uWindowSize = uCommonUniformsBuffer.windowSize;
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

fn getClusterIdx(cellCoords: vec3u) -> u32
{
	// Dividing by 32u because we use u32 clusters (cells) in the array.
	let u32Cols = u32(uGridSize.x) / 32u;
	let u32Rows = u32(uGridSize.y);
	let u32Depth = u32(uGridSize.z);
	let layerSize = u32Cols * u32(uGridSize.y);
	let x = cellCoords.x / 32u;

	// In case of power of 2 grid size having u32 cellCoorinates automatically takes care of overflow.
	// If the value casted to u32 was -1, it becomes max u32, being power of 2 itself it perfectly cycles with modulo.

	return (x % u32Cols) + (cellCoords.y % u32Rows) * u32Cols + (cellCoords.z % u32Depth) * layerSize;
}

fn getCellState(cellCoords: vec3u) -> u32
{
	let clusterIdx = getClusterIdx(cellCoords);
	let u32Storage = cellStates[clusterIdx];
	// return u32(u32Storage > 0);
	let x = cellCoords.x % 32u;

	return u32((u32Storage & masks[x]) > 0);
}

fn getCellFromSamplePoint(samplePoint: vec3f) -> CellData
{
	let cellSize = FULL_CUBE_SIZE / uGridSize;
	let cellCoords = floor((samplePoint + HALF_CUBE_SIZE) / cellSize);
	let cellOrigin = cellCoords * cellSize + cellSize * 0.5f - HALF_CUBE_SIZE;
	// let i = getCellIdx(cellCoords);
	// let i = getClusterIdx(vec3u(cellCoords));

	var cellData: CellData;
	cellData.cellOrigin = cellOrigin;
	cellData.cellCoords = vec3u(cellCoords);
	// cellData.idx = i;

	return cellData;
}

fn calculateLigtingAndOcclusionAt(samplePoint: vec3f, vUv: vec2f) -> vec4f
{
	var out = vec4f(0, 0, 0, 1);
	var occlusionFactor = 1.0f;
	let cellSize = FULL_CUBE_SIZE / uGridSize;
	let cellCoords = floor((samplePoint + HALF_CUBE_SIZE) / cellSize);
	let cellOrigin = cellCoords * cellSize + cellSize * 0.5f - HALF_CUBE_SIZE;
	let i = getCellIdx(cellCoords);
	let lightSource = uCommonUniformsBuffer.lightSource;
	let uCellSize = uCommonUniformsBuffer.cellSize;

	// Actual visible cell size might be smaller than the volume cell it is occupying.
	let actualVisibleCubeSize = cellSize * uCellSize * 0.5f;
	let distToActualCell = sdBox(samplePoint - cellOrigin, vec3f(actualVisibleCubeSize));

	// TODO: other ideas?
	// This also allows to see bounding volume.
	if (cellStates[i] != 1 || distToActualCell > 0.001f)
	{
		return out;
	}

	let lightDir = normalize(lightSource.pos - samplePoint);
	let rndOffset = n1rand(vUv);

	// If sample point is occluded from light source by cube itself.
	// If light is at the angle larger 90deg with face normal, that face is not hit by direct light at all.
	let faceNormal = getCubeFaceNormal(samplePoint, cellOrigin);
	// if (dot(faceNormal, lightDir) < 0.0f)
	if (false)
	{
		occlusionFactor = OCCLUSION_FACTOR;
	}
	else
	{
		let volumeIntersect = rayCubeIntersect(samplePoint, lightDir, vec3f(0.0f), vec3f(HALF_CUBE_SIZE));
		let volumeExit = samplePoint + lightDir * volumeIntersect.y;
		occlusionFactor = rayMarchShadow(samplePoint, volumeExit, i, rndOffset, uCommonUniformsBuffer.shadowSamples);
	}

	let c = cellCoords / uGridSize;
	let cellColor = vec4f(c.xy, 1f - c.x, 1f);
	out = calculateLigtingAt(samplePoint, cellOrigin, cellColor) * occlusionFactor;

	return out;
}

fn mixWithReprojectedColor(currentSampleColor: vec4f, prevSampleColor: vec4f, samplePos: vec3f, farthestMarchPos: vec3f, uvReprojected: vec2f, prevDepthReprojected: f32) -> vec4f
{
	var temporalAlpha = 0.1f;
	var prevColor = prevSampleColor;
	let viewMat = uCommonUniformsBuffer.viewMat;
	let uPrevViewMat = uCommonUniformsBuffer.prevViewMat;
	let cameraPos = viewMat[3].xyz;
	let prevCameraPos = uPrevViewMat[3].xyz;
	let currentDepth = length(cameraPos - samplePos);
	// temporalAlpha = 1.f;

	let reprojectedDir = normalize(samplePos - prevCameraPos);
	let reprojectedSamplePoint = prevCameraPos + reprojectedDir * prevDepthReprojected;
	let reprojectedCell = getCellFromSamplePoint(reprojectedSamplePoint);
	let curCell = getCellFromSamplePoint(samplePos);

	// Only apply reprojection within the range of positive uvs.
	// Clamping does not matter here, since it's the pixels we care about not the values.
	// In pixel positions where uvs are negative we don't need reprojection.
	// Applying it there would cause ghosting, rather just leave the current sample as is.
	if (uvReprojected.x < 0.0f || uvReprojected.x > 1.0f || uvReprojected.y < 0.0f || uvReprojected.y > 1.0f)
	{
		// prevColor = currentSampleColor;
		return currentSampleColor;
	}

	// if (curCell.idx != reprojectedCell.idx)
	// {
	// 	return currentSampleColor;
	// }

	if (all(curCell.cellCoords != reprojectedCell.cellCoords))
	{
		return currentSampleColor;
	}

	// if (all(samplePos == farthestMarchPos))
	// {
	// 	let prevCameraPos = uPrevViewMat[3].xyz;
	// 	let MAX_NO_GHOST_V: f32 = .0025;
	// 	let v: f32 = clamp(length(cameraPos - prevCameraPos), 0.0f, MAX_NO_GHOST_V) / MAX_NO_GHOST_V;
	// 	temporalAlpha = mix(temporalAlpha, 1.0f, v);
	// }

	var mixedColor = clamp(mix(prevColor, currentSampleColor, temporalAlpha), vec4f(0.0f), vec4f(1.0f));

	return mixedColor;
}

fn getReprojectedUV(samplePos: vec3f) -> vec2f
{
	let uPrevProjViewMatInv = uCommonUniformsBuffer.prevProjViewMatInv;
	let sampleProjectedToPrevViewpoint: vec4f = uPrevProjViewMatInv * vec4f(samplePos, 1.0f);

	// Converting to clipspace ranged [-1, 1].
	let reprojectedSampleClipSpace = sampleProjectedToPrevViewpoint / sampleProjectedToPrevViewpoint.w;

	// Converting to [0, 1] range.
	// Note the .y component has to be flipped.
	// This is due to it going from top to bottom, rather than bottom to top, which we want.
	let uv: vec2f = vec2f(reprojectedSampleClipSpace.x, -reprojectedSampleClipSpace.y) * 0.5f + 0.5f;

	return uv;
}

fn mixWithReprojectedDepth(current: vec2f, prev: vec2f, samplePoint: vec3f, farthestMarchPos: vec3f, uvReprojected: vec2f) -> vec4f
{
	var temporalAlpha = 0.1f;
	var prevDepth = prev.r;
	let viewMat = uCommonUniformsBuffer.viewMat;
	let uPrevViewMat = uCommonUniformsBuffer.prevViewMat;
	let uProjViewMatInv = uCommonUniformsBuffer.projViewMatInv;
	let uPrevProjViewMatInv = uCommonUniformsBuffer.prevProjViewMatInv;

	if (all(samplePoint == farthestMarchPos))
	{
		let cameraPos = viewMat[3].xyz;
		let prevCameraPos = uPrevViewMat[3].xyz;
		let MAX_NO_GHOST_V: f32 = .0025;
		let v: f32 = clamp(length(cameraPos - prevCameraPos), 0.0f, MAX_NO_GHOST_V) / MAX_NO_GHOST_V;
		temporalAlpha = mix(temporalAlpha, 1.0f, v);
	}

	// Only apply reprojection within the range of positive uvs.
	// Clamping does not matter here, since it's the pixels we care about not the values.
	// In pixel positions where uvs are negative we don't need reprojection.
	// Applying it there would cause ghosting, rather just leave the current sample as is.
	if (uvReprojected.x < 0.0f || uvReprojected.x > 1.0f || uvReprojected.y < 0.0f || uvReprojected.y > 1.0f)
	{
		prevDepth = current.r;
	}

	// Discard previous depth if reprojected position changed. This means observer / camera moved.
	if (any(uPrevProjViewMatInv[0] != uProjViewMatInv[0]) ||
		any(uPrevProjViewMatInv[1] != uProjViewMatInv[1]) ||
		any(uPrevProjViewMatInv[2] != uProjViewMatInv[2]) ||
		any(uPrevProjViewMatInv[3] != uProjViewMatInv[3]))
	{
		// let mixedDepth = current.r;
		// let mixedDepth = clamp(mix(prevDepth, current.r, 0.5f), 0.0f, 1.0f);
		// let mixedDepth = min(prevDepth.r, current.r);
		// return vec4f(mixedDepth, 0.0f, 0.0f, 1.0f);
	}

	let minDepth = min(prevDepth, current.r);

	// Using constant 1.0f temporalAlpha here, to converge faster on minDepth.
	let mixedDepth = clamp(mix(prevDepth, minDepth, 1.0f), 0.0f, 1.0f);

	return vec4f(mixedDepth, 0.0f, 0.0f, 1.0f);
}

fn calculateLigtingAt(samplePoint: vec3f, cellOrigin: vec3f, initialMaterialColor: vec4f) -> vec4f
{
	let viewMat = uCommonUniformsBuffer.viewMat;
	let faceNormal = getCubeFaceNormal(samplePoint, cellOrigin);
	let cameraPos = viewMat[3].xyz;
	let viewDir = normalize(samplePoint - cameraPos);
	let lightSource = uCommonUniformsBuffer.lightSource;

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
	let uCellSize = uCommonUniformsBuffer.cellSize;

	// Actual visible cell size might be smaller than the volume cell it is occupying.
	let actualVisibleCubeSize = cellSize * uCellSize * 0.5f;

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
			let intersectData = rayCubeIntersect(start, dir, cellOrigin, actualVisibleCubeSize);
			if (intersectData.x <= intersectData.y && intersectData.x >= 0)
			{
				occlusionFactor = OCCLUSION_FACTOR;
				break;
			}
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
	let uCellSize = uCommonUniformsBuffer.cellSize;

	// Actual visible cell size might be smaller than the volume cell it is occupying.
	let actualVisibleCubeSize = cellSize * uCellSize * 0.5f;
	var cellCoords = vec3f(0.0f);
	var cellOrigin = vec3f(0.0f);
	var cellColor = vec4f(0.0f);
	var occlusionFactor: f32 = 1.0f;
	let lightSource = uCommonUniformsBuffer.lightSource;

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
					out.finalSamplePoint = samplePoint;

					return out;
				}
			}

			// If we didn't hit anything it means visible cube is actually smaller than the cell it's occupying.
			// Just continue marching along the ray until we hit something.
		}

		depth += stepSize;
	}

	out.finalSamplePoint = end;

	return out;
}

fn rayMarchDepth(start: vec3f, end: vec3f, vUv: vec2f, steps: f32) -> RayMarchOut
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
	let uCellSize = uCommonUniformsBuffer.cellSize;

	// Actual visible cell size might be smaller than the volume cell it is occupying.
	let actualVisibleCubeSize = cellSize * uCellSize * 0.5f;
	var cellCoords = vec3f(0.0f);
	var cellOrigin = vec3f(0.0f);
	var cellState: u32 = 0;

	while(depth < marchDepth)
	{
		samplePoint = start + dir * depth;
		out.finalSamplePoint = samplePoint;

		// Shifting inside the volume to calculate cells in [0, ... uGridSize] range.
		// As if the volume is completely in the positive domain.
		// TODO: improve this such that it takes into account volume's position.
		cellCoords = floor((samplePoint + HALF_CUBE_SIZE) / cellSize);
		cellOrigin = cellCoords * cellSize + cellSize * 0.5f - HALF_CUBE_SIZE;
		cellState = getCellState(vec3u(cellCoords));

		if (cellState != 0)
		{
			// If we know we're in the cell that is active, the sample point might be anywhere relatively to the visible cube within it.
			// So we find an intersection point on the view ray and snap sample point to the cube.
			// This allows to get lighting calculations at correct point in space and thus reduce noise by making "hits" more accurate.
			let cellIntersectForward = rayCubeIntersect(start, dir, cellOrigin, actualVisibleCubeSize);

			if (cellIntersectForward.y >= 0.0f)
			{
				if (cellIntersectForward.x <= cellIntersectForward.y)
				{
					out.finalSamplePoint = start + dir * cellIntersectForward.x;
					return out;
				}
			}

			// If we didn't hit anything it means visible cube is actually smaller than the cell it's occupying.
			// Just continue marching along the ray until we hit something.
		}

		depth += stepSize;
	}

	out.finalSamplePoint = end;

	return out;
}

fn estimateLikelyDepth(samplePoint: vec3f, prevDepth: vec2f, prevDepthReprojected: vec2f, vUv: vec2f, uvReprojected: vec2f) -> vec2f
{
	let viewMat = uCommonUniformsBuffer.viewMat;
	let uPrevViewMat = uCommonUniformsBuffer.prevViewMat;
	let cameraPos = viewMat[3].xyz;
	let prevCameraPos = uPrevViewMat[3].xyz;
	let currentDepth = length(samplePoint - cameraPos);
	var prevDepthRe = prevDepthReprojected.r;
	let ray = getRay(vUv);
	let viewRay = normalize(viewMat * ray).xyz;
	let prevViewRay = normalize(uPrevViewMat * ray).xyz;
	let viewRay2 = normalize(samplePoint - prevCameraPos);
	let prevSamplePoint = prevCameraPos + prevViewRay * prevDepth.r;
	let reprojectedSamplePoint = prevCameraPos + viewRay2 * prevDepthReprojected.r;
	let uCellSize = uCommonUniformsBuffer.cellSize;

	// By default taking current sample.
	var likelyDepth = vec2f(currentDepth, 0.0f);

	let cellSize = FULL_CUBE_SIZE / uGridSize;

	// Actual visible cell size might be smaller than the volume cell it is occupying.
	let actualVisibleCubeSize = cellSize * uCellSize * 0.5f;

	let prevCell = getCellFromSamplePoint(prevSamplePoint);
	let reprojectedCell = getCellFromSamplePoint(reprojectedSamplePoint);
	let curCell = getCellFromSamplePoint(samplePoint);
	let reprojectedCellState = getCellState(reprojectedCell.cellCoords);

	// Compare current sample of depth with what we had on the previous frame, reprojected to new samplePoint.
	// Using reprojected depth, we obtain a cell and check if it's alive.
	// If what we hit on this frame is not the same cell, we overstepped the cell either on this frame or on previous.
	// If reprojected depth from previous frame is closer, we likely overstepped this frame.
	// Thus we run cube intersection check for the cell derrived using reprojected depth to get an accurate result.
	if (reprojectedCellState == 1 && all(curCell.cellCoords != reprojectedCell.cellCoords) && prevDepthRe < currentDepth)
	{
		let intersectData = rayCubeIntersect(cameraPos, viewRay, reprojectedCell.cellOrigin, actualVisibleCubeSize);
		if (intersectData.x <= intersectData.y && intersectData.x >= 0)
		{
			likelyDepth.r = intersectData.x;
		}
	}

	// else if (cellStates[prevCell.idx] == 1 && curCell.idx != prevCell.idx && prevDepth.r < currentDepth)
	// {
	// 	let intersectData = rayCubeIntersect(cameraPos, viewRay, prevCell.cellOrigin, actualVisibleCubeSize);
	// 	if (intersectData.x <= intersectData.y && intersectData.x >= 0)
	// 	{
	// 		likelyDepth.r = intersectData.x;
	// 	}
	// }

	// Otherwise, current sample gives closest depth, so we use it.

	return likelyDepth;
}

@fragment
fn fragment_main(fragData: VertexOut) -> ShaderOut
{
	var out = vec4f(0.0f, 0.0f, 0.0f, 1.0f);
	var shaderOut: ShaderOut;
	var rayMarchOut: RayMarchOut;
	var mixedColor = vec4f(0, 0, 0, 1);
	var mixedDepth = vec4f(0);
	let lightSource = uCommonUniformsBuffer.lightSource;
	let viewMat = uCommonUniformsBuffer.viewMat;
	let uWindowSize = uCommonUniformsBuffer.windowSize;

	let cameraPos = viewMat[3].xyz;
	// let viewDir = normalize(fragData.worldPosition.xyz - cameraPos);
	let viewRay = (viewMat * getRay(fragData.vUv)).xyz;

	let cubeIntersections = rayCubeIntersect(cameraPos, viewRay, vec3f(0.0f), vec3f(HALF_CUBE_SIZE));
	// let cubeIntersections = intersectCube(cameraPos, viewRay, vec3f(-0.5f), vec3f(0.5f));

	let cameraDistToBox = sdBox(cameraPos, vec3f(HALF_CUBE_SIZE));

	var cubeEnterPoint = cameraPos;
	var cubeExitPoint = cameraPos + viewRay * cubeIntersections.y;
	var s = 0.0f;

	if (cubeIntersections.x <= cubeIntersections.y && cubeIntersections.y >= 0.0f)
	{
		if (cameraDistToBox >= 0.0f)
		{
			// Snap ray march starting point to first intersection with the cube.
			cubeEnterPoint = cameraPos + viewRay * cubeIntersections.x;
			// cubeExitPoint = cameraPos + viewRay * cubeIntersections.y;
		}

		// rayMarchOut = rayMarch(cubeEnterPoint, cubeExitPoint, fragData.vUv, 25.0f);
		rayMarchOut = rayMarchDepth(cubeEnterPoint, cubeExitPoint, fragData.vUv, uCommonUniformsBuffer.depthSamples);
		out = rayMarchOut.color;
		let uv = vec2f(fragData.vUv.x, 1.0 - fragData.vUv.y);
		var uvReprojected = getReprojectedUV(rayMarchOut.finalSamplePoint);
		// var currentDepth = vec2f(length(cameraPos - rayMarchOut.finalSamplePoint), 0.0f);
		let prevDepth = textureLoad(depthBuffer, vec2i(uv * uWindowSize), 0).xy;
		let prevDepthReprojected = textureLoad(depthBuffer, vec2i(uvReprojected * uWindowSize), 0).xy;
		let currentDepth = estimateLikelyDepth(rayMarchOut.finalSamplePoint, prevDepth, prevDepthReprojected, fragData.vUv, uvReprojected);

		mixedDepth = vec4f(currentDepth, 0, 1);
		let moreAccurateSamplePoint = cameraPos + viewRay * mixedDepth.r;

		// Update reprojected uv since by now we have more accurate depth for geometry.
		uvReprojected = getReprojectedUV(moreAccurateSamplePoint);

		// mixedDepth = mixWithReprojectedDepth(
		// 	currentDepth,
		// 	prevDepthReprojected,
		// 	rayMarchOut.finalSamplePoint,
		// 	rayMarchOut.farthestMarchPoint,
		// 	uvReprojected
		// );

		// mixedDepth.r = currentDepth.r;

		out = calculateLigtingAndOcclusionAt(moreAccurateSamplePoint, fragData.vUv);

		let prevColor = textureLoad(prevFrame, vec2i(uvReprojected * uWindowSize), 0);
		mixedColor = mixWithReprojectedColor(out, prevColor, moreAccurateSamplePoint, rayMarchOut.farthestMarchPoint, uvReprojected, prevDepthReprojected.r);
		out = mixedColor;
		s = prevDepthReprojected.r;
		// out = vec4f(1.0f, 0.0f, 0.0f, 1.0f);
	}

	let lightIntersect = rayCubeIntersect(cameraPos, viewRay, lightSource.pos, vec3f(0.005f));

	if (lightIntersect.x <= lightIntersect.y && lightIntersect.y >= 0.0f)
	{
		if (all(out.xyz == vec3f(0.0f)))
		{
			out = vec4f(1.0f);
		}
	}

	// Common buffer allignment tests.
	// out = vec4f(uCommonUniformsBuffer.data.f1, 1.0f);
	// out = vec4f(vec3f(uCommonUniformsBuffer.data.f0, 0, 0), 1.0f);


	if (uCommonUniformsBuffer.showDepthBuffer == 1.0f && fragData.vUv.x < 0.5f)
	{
		out = vec4f(mixedDepth.r, 0, 0, 1);
	}

	// Gamma correction with 2.2f.
	shaderOut.presentation = vec4f(pow(out.xyz, vec3f(1 / 2.2f)), out.w);
	shaderOut.light = vec4f(out.xyz, 1.0f);
	shaderOut.depth = vec2f(mixedDepth.r, 1.0f);

	return shaderOut;
}
