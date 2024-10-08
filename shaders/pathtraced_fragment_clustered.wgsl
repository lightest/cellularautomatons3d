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
	showDepthBuffer: f32,
	temporalAlpha: f32,
	baseSurfaceReflectivity: vec3f,
	roughness: f32,
	materialColor: vec3f,
	gamma: f32,
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
const OCCLUSION_FACTOR: f32 = 0.0095f;

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

// Offsets for neighbour's lighting contribution calculations.
// const leftLayer = array<vec3i, 9>(
// 	vec3i(-1, -1, -1), vec3i(-1, -1, 0), vec3i(-1, -1, 1),
// 	vec3i(-1, 1, -1), vec3i(-1, 1, 0), vec3i(-1, 1, 1),
// 	vec3i(-1, 0, -1), vec3i(-1, 0, 1), vec3i(-1, 0, 0)
// );

const leftLayer = array<vec3i, 4>(
	vec3i(-1, 1, 0), vec3i(-1, -1, 0), vec3i(-1, 0, 1),  vec3i(-1, 0, -1)
);

// const rightLayer = array<vec3i, 9>(
// 	vec3i(1, -1, -1), vec3i(1, -1, 0), vec3i(1, -1, 1),
// 	vec3i(1, 1, -1), vec3i(1, 1, 0), vec3i(1, 1, 1),
// 	vec3i(1, 0, -1), vec3i(1, 0, 1), vec3i(1, 0, 0)
// );

const rightLayer = array<vec3i, 4>(
	vec3i(1, 1, 0), vec3i(1, -1, 0), vec3i(1, 0, 1),  vec3i(1, 0, -1)
);

// const topLayer = array<vec3i, 9>(
// 	vec3i(-1, 1, 0), vec3i(1, 1, 0), vec3i(0, 1, 0),
// 	vec3i(-1, 1, -1), vec3i(0, 1, -1), vec3i(1, 1, -1),
// 	vec3i(-1, 1, 1), vec3i(0, 1, 1), vec3i(1, 1, 1)
// );

const topLayer = array<vec3i, 4>(
	vec3i(-1, 1, 0), vec3i(1, 1, 0), vec3i(0, 1, 1), vec3i(0, 1, -1)
);

// const bottomLayer = array<vec3i, 9>(
// 	vec3i(-1, -1, 0), vec3i(1, -1, 0), vec3i(0, -1, 0),
// 	vec3i(-1, -1, -1), vec3i(0, -1, -1), vec3i(1, -1, -1),
// 	vec3i(-1, -1, 1), vec3i(0, -1, 1), vec3i(1, -1, 1)
// );

const bottomLayer = array<vec3i, 4>(
	vec3i(-1, -1, 0), vec3i(1, -1, 0), vec3i(0, -1, 1), vec3i(0, -1, -1)
);

// const frontLayer = array<vec3i, 9>(
// 	vec3i(-1, 1, 1), vec3i(0, 1, 1), vec3i(1, 1, 1),
// 	vec3i(-1, 0, 1), vec3i(1, 0, 1), vec3i(0, 0, 1),
// 	vec3i(-1, -1, 1), vec3i(0, -1, 1), vec3i(1, -1, 1),
// );

const frontLayer = array<vec3i, 4>(
	vec3i(0, 1, 1), vec3i(0, -1, 1), vec3i(-1, 0, 1), vec3i(1, 0, 1)
);

// const backLayer = array<vec3i, 9>(
// 	vec3i(-1, 1, -1), vec3i(0, 1, -1), vec3i(1, 1, -1),
// 	vec3i(-1, 0, -1), vec3i(1, 0, -1), vec3i(0, 0, -1),
// 	vec3i(-1, -1, -1), vec3i(0, -1, -1), vec3i(1, -1, -1),
// );

const backLayer = array<vec3i, 4>(
	vec3i(0, 1, -1), vec3i(0, -1, -1), vec3i(-1, 0, -1), vec3i(1, 0, -1)
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

	// Finding maximum allows to get direction of the normal pointing at one of the 3 faces.
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

// NOTE: cellIdx can not be used to access cell value in the cellStates array,
// but it can be used as a cell identifier for fast comparisons!
fn getCellIdx(cellCoords: vec3u) -> u32
{
	let u32Cols = u32(uGridSize.x);
	let u32Rows = u32(uGridSize.y);
	let u32Depth = u32(uGridSize.z);
	let layerSize = u32(uGridSize.x * uGridSize.y);

	return cellCoords.x + cellCoords.y * u32Cols + cellCoords.z * layerSize;
}

fn getClusterIdxFromGridCoordinates(cellCoords: vec3u) -> u32
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
	let clusterIdx = getClusterIdxFromGridCoordinates(cellCoords);
	let u32Storage = cellStates[clusterIdx];
	let x = cellCoords.x % 32u;

	return u32((u32Storage & masks[x]) > 0);
}

fn getCellFromSamplePoint(samplePoint: vec3f) -> CellData
{
	let cellSize = FULL_CUBE_SIZE / uGridSize;
	let cellCoords = floor((samplePoint + HALF_CUBE_SIZE) / cellSize);
	let cellOrigin = cellCoords * cellSize + cellSize * 0.5f - HALF_CUBE_SIZE;

	var cellData: CellData;
	cellData.cellOrigin = cellOrigin;
	cellData.cellCoords = vec3u(cellCoords);
	cellData.idx = getCellIdx(cellData.cellCoords);

	return cellData;
}

// Calculates lighting contribution from neighbouring cells.
fn calculateIndirectLighting(samplePoint: vec3f, surfaceNormal: vec3f, cellOrigin:vec3f, cellCoords: vec3u, rndOffset: f32) -> vec3f
{
	var i: u32;
	let uCellSize = uCommonUniformsBuffer.cellSize;
	let lightSource = uCommonUniformsBuffer.lightSource;
	let viewMat = uCommonUniformsBuffer.viewMat;
	let cellCoords_i32 = vec3i(cellCoords);
	var indirectLighting = vec3f(0);
	var neighbourOffsets: array<vec3i, 4>;
	var neighbourCoords: vec3u;
	var cellState: u32;
	var neighbourCellOrigin: vec3f;
	var neighbourDir: vec3f;
	let cellSize = FULL_CUBE_SIZE / uGridSize;
	let visibleCellHalfSize = cellSize * uCellSize * 0.5f;
	var neighbourIntersection: vec2f;
	var neighbourSamplePoint: vec3f;

	if (surfaceNormal.x < 0)
	{
		neighbourOffsets = leftLayer;
	}
	else if (surfaceNormal.x > 0)
	{
		neighbourOffsets = rightLayer;
	}
	else if (surfaceNormal.y < 0)
	{
		neighbourOffsets = bottomLayer;
	}
	else if (surfaceNormal.y > 0)
	{
		neighbourOffsets = topLayer;
	}
	else if (surfaceNormal.z < 0)
	{
		neighbourOffsets = backLayer;
	}
	else if (surfaceNormal.z > 0)
	{
		neighbourOffsets = frontLayer;
	}

	for (i = 0; i < 4; i++)
	{
		neighbourCoords = vec3u(cellCoords_i32 + neighbourOffsets[i]);
		cellState = getCellState(neighbourCoords);
		if (cellState > 0)
		{
			neighbourCellOrigin = vec3f(neighbourCoords) * cellSize + cellSize * 0.5f - HALF_CUBE_SIZE;
			neighbourDir = vec3f(neighbourOffsets[i]);
			// neighbourDir = neighbourCellOrigin - samplePoint;
			neighbourIntersection = rayCubeIntersect(samplePoint, neighbourDir, neighbourCellOrigin, visibleCellHalfSize);

			if (neighbourIntersection.x <= neighbourIntersection.y && neighbourIntersection.y >= 0.0f)
			{
				neighbourSamplePoint = samplePoint + neighbourDir * neighbourIntersection.x;
				let lightDir = normalize(lightSource.pos - neighbourSamplePoint);
				let volumeIntersect = rayCubeIntersect(neighbourSamplePoint, lightDir, vec3f(0.0f), vec3f(HALF_CUBE_SIZE));
				let volumeExit = neighbourSamplePoint + lightDir * volumeIntersect.y;
				let occlusionFactor = rayMarchShadow(neighbourSamplePoint, volumeExit, neighbourCoords, rndOffset, uCommonUniformsBuffer.shadowSamples);

				let reflectedLight: vec3f = calculateLightingAt(neighbourSamplePoint, neighbourCellOrigin, neighbourCoords, samplePoint, vec3f(lightSource.magnitude), lightSource.pos) * occlusionFactor;

				indirectLighting += calculateLightingAt(samplePoint, cellOrigin, cellCoords, viewMat[3].xyz, reflectedLight, neighbourSamplePoint);
			}
		}
	}

	return indirectLighting;
}

fn calculateLightingAndOcclusionAt(samplePoint: vec3f, vUv: vec2f) -> vec4f
{
	var out = vec3f(0, 0, 0);
	let viewMat = uCommonUniformsBuffer.viewMat;
	var occlusionFactor = 1.0f;
	let cellSize = FULL_CUBE_SIZE / uGridSize;
	let cellData = getCellFromSamplePoint(samplePoint);
	let cellOrigin = cellData.cellOrigin;
	let cellCoords = cellData.cellCoords;
	let cellState = getCellState(cellCoords);
	let lightSource = uCommonUniformsBuffer.lightSource;
	let uCellSize = uCommonUniformsBuffer.cellSize;

	// Actual visible cell size might be smaller than the volume cell it is occupying.
	let actualVisibleCubeSize = cellSize * uCellSize * 0.5f;
	let distToActualCell = sdBox(samplePoint - cellOrigin, vec3f(actualVisibleCubeSize));

	// TODO: other ideas?
	// This also allows to see bounding volume.
	if (cellState != 1 || distToActualCell > 0.001f)
	{
		return vec4f(out, 1.0f);
	}

	let lightDir = normalize(lightSource.pos - samplePoint);
	let viewDir = normalize(samplePoint - viewMat[3].xyz);

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
		occlusionFactor = rayMarchShadow(samplePoint, volumeExit, cellData.cellCoords, rndOffset, uCommonUniformsBuffer.shadowSamples);
	}

	out = occlusionFactor * calculateLightingAt(samplePoint, cellOrigin, cellCoords, viewMat[3].xyz, vec3f(lightSource.magnitude), lightSource.pos);
	// + calculateIndirectLighting(samplePoint, faceNormal, cellOrigin, cellCoords, rndOffset);

	return vec4f(out, 1.0f);
}

fn mixWithReprojectedColor(currentSampleColor: vec4f, prevSampleColor: vec4f, samplePos: vec3f, farthestMarchPos: vec3f, uvReprojected: vec2f, prevDepthReprojected: f32) -> vec4f
{
	var temporalAlpha = uCommonUniformsBuffer.temporalAlpha;
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

	if (curCell.idx != reprojectedCell.idx)
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

	let mixedColor = clamp(mix(prevColor, currentSampleColor, temporalAlpha), vec4f(0.0f), vec4f(1.0f));

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
	var temporalAlpha = uCommonUniformsBuffer.temporalAlpha;
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

// Trowbridge-Reitz GGX:
fn throwbridgeReitzGGX(surfaceNormal: vec3f, halfWayVector: vec3f, roughness: f32) -> f32
{
	let a2: f32 = roughness * roughness;
	let NoH = dot(surfaceNormal, halfWayVector);
	let NoH2 = NoH * NoH;
	let f = NoH2 * (a2 - 1.0f) + 1.0f;

	return a2 / (PI * f * f);
}

// Schlick-GGX:
fn shlickGGX(surfaceNormal: vec3f, dir: vec3f, roughness: f32) -> f32
{
	let n = roughness + 1.0f;

	// TODO: learn more about roughness remapping and whent it's relevant.
	// roughness remapping.
	let kDirect = (n * n) / 8.0f;

	let NoV = max(0.0f, dot(surfaceNormal, dir));
	let denom = NoV * (1.0f - kDirect) + kDirect;

	return NoV / denom;
}

// Fresnel-Schlick approximation:
fn fresnelSchlick(halfWayVector: vec3f, viewDir: vec3f, baseSurfaceReflectivity: vec3f) -> vec3f
{
	let p = pow(1.0f - dot(halfWayVector, viewDir), 5.0f);

	return baseSurfaceReflectivity + (1.0f - baseSurfaceReflectivity) * p;
}

fn surfaceBRDF(lightDir: vec3f, viewDir: vec3f, surfaceNormal: vec3f, roughness: f32, albedo: vec3f, baseSurfaceReflectivity: vec3f) -> vec3f
{
	let halfWayVector: vec3f = normalize(lightDir + viewDir);

	// Lambertian diffuse:
	let fL: vec3f = albedo / PI;

	// Normal distribution function:
	let D: f32 = throwbridgeReitzGGX(surfaceNormal, halfWayVector, roughness);

	// Geometry function:
	let G = shlickGGX(surfaceNormal, viewDir, roughness) * shlickGGX(surfaceNormal, lightDir, roughness);

	// Fresnel equation:
	let F = fresnelSchlick(halfWayVector, viewDir, baseSurfaceReflectivity);

	// TODO: ensure division by zero in this case is ok.
	// Cook-Torrance specular:
	let denom = 4.0f * dot(viewDir, surfaceNormal) * dot(lightDir, surfaceNormal);
	let fCT = (D * G * F) / denom;

	return fL + fCT;
}

fn calculateLightingAt(samplePoint: vec3f, cellOrigin: vec3f, cellCoords: vec3u, eyePos: vec3f, incidentLight: vec3f, incidentLightPos: vec3f) -> vec3f
{
	let surfaceNormal = getCubeFaceNormal(samplePoint, cellOrigin);
	let roughness = uCommonUniformsBuffer.roughness;
	let c = vec3f(cellCoords) / uGridSize;
	var initialMaterialColor = vec3f(c.xy, 1f - c.x);
	if (any(uCommonUniformsBuffer.materialColor != vec3f(0.0)))
	{
		initialMaterialColor = uCommonUniformsBuffer.materialColor;
	}
	let viewDir = normalize(eyePos - samplePoint);
	let incidentLightDir = normalize(incidentLightPos - samplePoint);
	let baseSurfaceReflectivity: vec3f = uCommonUniformsBuffer.baseSurfaceReflectivity;

	// TODO: should dependant parameters be passed as arguments?
	// let distanceToLight:f32 = distance(incidentLightPos, samplePoint);
	// let distanceToLightFactor = max(1.0f, pow(distanceToLight, 2.0f));
	// let distanceToEye = distance(eyePos, samplePoint);

	// Limiting denominator to 1, otherwise light is going to increase with closer distance.
	// let distanceToEyeFactor = max(1.0f, pow(distanceToEye, 2.0f));

	// let incidentLightAttenuated = incidentLight / distanceToLightFactor;
	// let reflectedLightDir = reflect(incidentLightDir, surfaceNormal);
	// let reflectedLight = incidentLightAttenuated * dot(reflectedLightDir, -viewDir);
	// let refractedLight = incidentLightAttenuated - reflectedLight;
	let brdf = surfaceBRDF(incidentLightDir, viewDir, surfaceNormal, roughness, initialMaterialColor, baseSurfaceReflectivity);

	// Rendering equation.
	let Lr = brdf * incidentLight * dot(incidentLightDir, surfaceNormal);
	let totalObservedSpectrum: vec3f = (Lr);

	// Second term here (incidentLight * out.xyz) simulates diffuse light.
	// let totalObservedSpectrum = (initialMaterialColor.xyz * reflectedLight + refractedLight * initialMaterialColor.xyz) / distanceToCameraFactor;

	// let out = vec4(out.xyz * incidentLight, out.w);
	let out = max(vec3f(0.0), totalObservedSpectrum);

	return out;
}

fn rayMarchShadow(start: vec3f, end: vec3f, startCellCoords: vec3u, rndOffset: f32, steps: f32)-> f32
{
	var occlusionFactor: f32 = 1.0f;
	let dir = normalize(end - start);
	let marchDepth = length(end - start);
	let cellSize = FULL_CUBE_SIZE / uGridSize;
	let uCellSize = uCommonUniformsBuffer.cellSize;
	// Actual visible cell size might be smaller than the volume cell it is occupying.
	let actualVisibleCubeSize = cellSize * uCellSize * 0.5f;
	var stepSize = max((cellSize * uCellSize).x, marchDepth / steps);
	// var stepSize = marchDepth / steps;

	// TODO: to think how to optimize starting point for shadow marching.
	var depth = stepSize * rndOffset + 0.0025f;
	var samplePoint = vec3f(0.0f);
	var cellCoords = vec3f(0.0f);
	var cellOrigin = vec3f(0.0f);
	var s = steps;


	// while(depth < marchDepth && s >= 0.0f)
	while(depth < marchDepth)
	{
		// stepSize = pow(rndOffset, -s) * marchDepth - depth;
		// s = s - 1.0f;
		samplePoint = start + dir * depth;
		cellCoords = floor((samplePoint + HALF_CUBE_SIZE) / cellSize);
		let cellState = getCellState(vec3u(cellCoords));
		cellOrigin = cellCoords * cellSize + cellSize * 0.5f - HALF_CUBE_SIZE;

		if (any(vec3u(cellCoords) != startCellCoords) && cellState == 1)
		// if (cellState == 1)
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

	// let prevCell = getCellFromSamplePoint(prevSamplePoint);
	let reprojectedCell = getCellFromSamplePoint(reprojectedSamplePoint);
	let curCell = getCellFromSamplePoint(samplePoint);
	let reprojectedCellState = getCellState(reprojectedCell.cellCoords);

	// Compare current sample of depth with what we had on the previous frame, reprojected to new samplePoint.
	// Using reprojected depth, we obtain a cell and check if it's alive.
	// If what we hit on this frame is not the same cell, we overstepped the cell either on this frame or on previous.
	// If reprojected depth from previous frame is closer, we likely overstepped this frame.
	// Thus we run cube intersection check for the cell derrived using reprojected depth to get an accurate result.
	if (reprojectedCellState == 1 && curCell.idx != reprojectedCell.idx && prevDepthRe < currentDepth)
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
	let viewRay = (viewMat * getRay(fragData.vUv)).xyz;

	let cubeIntersections = rayCubeIntersect(cameraPos, viewRay, vec3f(0.0f), vec3f(HALF_CUBE_SIZE));
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

		out = calculateLightingAndOcclusionAt(moreAccurateSamplePoint, fragData.vUv);

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

	shaderOut.light = vec4f(out.xyz, 1.0f);
	shaderOut.depth = vec2f(mixedDepth.r, 1.0f);
	shaderOut.presentation = vec4f(pow(out.xyz, vec3f(1 / uCommonUniformsBuffer.gamma)), out.w);

	return shaderOut;
}
