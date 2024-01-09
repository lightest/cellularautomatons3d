@group(0) @binding(0) var<uniform> colsRows: vec3f;
@group(0) @binding(1) var<uniform> controlData: ControlData;
@group(0) @binding(2) var<storage> cellStates: array<u32>;
@group(0) @binding(4) var<uniform> viewMat: mat4x4f;
@group(0) @binding(5) var<uniform> projViewMatInv: mat4x4f;
@group(0) @binding(6) var<uniform> lightSource: LightSource;

struct ControlData {
	pressedMouseButtons: vec3u,
	simIsRunning: u32,
	mouseGridPos: vec2u,
	_unused: vec2u // Padding to multiples of 16 bytes.
};

struct LightSource {
	pos: vec3f,
	magnitude: f32
};

struct VertexIn {
	@location(0) position: vec4f,
	// @location(1) color: vec4f,
	@location(1) normal: vec3f,
	@builtin(instance_index) instance: u32
}

// TODO: read more about @builtin and @location.
struct VertexOut {
	@builtin(position) position: vec4f,
	// @location(0) color: vec4f,
	@location(1) worldPosition: vec4f,
	@location(2) cell: vec3f,
	@location(3) @interpolate(flat) pointerIdx: u32,
	@location(4) @interpolate(flat) instance: u32,
	@location(5) normal: vec3f,
	@location(6) worldNormal: vec3f
}

@vertex
fn vertex_main(input: VertexIn) -> VertexOut
{
	let i = f32(input.instance);
	// let cell = vec2f(i % colsRows.x, floor(i / colsRows.y));
	let layerSize = colsRows.x * colsRows.y;
	let cell = vec3f(i % colsRows.x, floor(i / colsRows.y) % colsRows.y, floor(i / layerSize));
	let pointerIdx = controlData.mouseGridPos.y * u32(colsRows.x) + controlData.mouseGridPos.x;
	var state = f32(cellStates[input.instance]);
	if (pointerIdx == input.instance)
	{
		state = 1;
	}
	// let positioningShift = vec3f(cell / colsRows.xy * 2, 0.);
	let positioningShift = vec3f(cell / colsRows * 2);
	var output: VertexOut;
	// output.position = vec4((input.position.xy * state + 1f) / colsRows - 1f + positioningShift, (input.position.z * state + 1f) / colsRows.x - 1f, input.position.w);
	output.worldPosition = vec4((input.position.xyz * state + 1f) / colsRows - 1f + positioningShift, input.position.w);
	output.position = projViewMatInv * output.worldPosition;
	// output.color = input.color;
	output.cell = cell;
	output.pointerIdx = pointerIdx;
	output.instance = input.instance;
	output.normal = input.normal;
	output.worldNormal = (projViewMatInv * vec4(input.normal, 1.0f)).xyz;

	return output;
}
