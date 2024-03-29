@group(0) @binding(0) var<uniform> uGridSize: vec3f;
@group(0) @binding(11) var<uniform> uCommonBuffer: CommonBufferLayout;

@group(2) @binding(0) var<storage> cellStates: array<u32>;

struct LightSource {
	pos: vec3f,
	magnitude: f32
};

struct CommonBufferLayout {
	lightSource: LightSource,
	viewMat: mat4x4f,
	projViewMatInv: mat4x4f,
	prevViewMat: mat4x4f,
	prevProjViewMatInv: mat4x4f
};

struct VertexIn {
	@location(0) position: vec4f,
	// @location(1) color: vec4f,
	@location(1) normal: vec3f,
	@location(2) vUv: vec2f,
	@builtin(instance_index) instance: u32
}

// TODO: read more about @builtin and @location.
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

@vertex
fn vertex_main(input: VertexIn) -> VertexOut
{
	let i = f32(input.instance);
	let uProjViewMatInv = uCommonBuffer.projViewMatInv;
	// let cell = vec2f(i % uGridSize.x, floor(i / uGridSize.y));
	let layerSize = uGridSize.x * uGridSize.y;
	let cell = vec3f(i % uGridSize.x, floor(i / uGridSize.y) % uGridSize.y, floor(i / layerSize));
	var state = f32(cellStates[input.instance]);

	// let positioningShift = vec3f(cell / uGridSize.xy * 2, 0.);
	let positioningShift = vec3f(cell / uGridSize * 2);
	var output: VertexOut;
	// output.position = vec4((input.position.xy * state + 1f) / uGridSize - 1f + positioningShift, (input.position.z * state + 1f) / uGridSize.x - 1f, input.position.w);
	output.worldPosition = vec4((input.position.xyz * state + 1f) / uGridSize - 1f + positioningShift, input.position.w);
	// output.position = uProjViewMatInv * output.worldPosition;
	output.position = input.position;
	// output.color = input.color;
	output.cell = cell;
	output.instance = input.instance;
	output.normal = input.normal;
	output.worldNormal = (uProjViewMatInv * vec4(input.normal, 1.0f)).xyz;
	output.vUv = input.vUv;

	return output;
}
