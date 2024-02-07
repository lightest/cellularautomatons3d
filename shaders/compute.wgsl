@group(0) @binding(0) var<uniform> uGridSize: vec3f;

@group(1) @binding(0) var<storage> cellStateIn: array<u32>;
@group(1) @binding(1) var<storage, read_write> cellStateOut: array<u32>;

// In order to pass arrays of <vec3i> you have to account for data type alignment.
// In case of <vec3i> it's going to be 16 bytes, not 12.
// So underlying buffer should have 4 elements per vector instead of 3 to be read correctly...
// Obvuously this is bullshit, so we're passing flat array of <i32>
// and iterate over it keeping in mind it's <vec3i> is what we packed there.
@group(2) @binding(0) var<storage> sNeighbourhoodOffsets: array<i32>;

// Using array as a hash map for fast lookup and cell survival / birth checks.
@group(2) @binding(1) var<storage> sSurviveRules: array<u32>;
@group(2) @binding(2) var<storage> sBornRules: array<u32>;


fn getCellIdx(cellCoords: vec3u) -> u32
{
	let u32Cols = u32(uGridSize.x);
	let u32Rows = u32(uGridSize.y);
	let u32Depth = u32(uGridSize.z);
	let layerSize = u32(uGridSize.x * uGridSize.y);

	// In case of power of 2 grid size having u32 cellCoorinates automatically takes care of overflow.
	// If the value casted to u32 was -1, it becomes max u32, being power of 2 itself it perfectly cycles with modulo.

	return (cellCoords.x % u32Cols) + (cellCoords.y % u32Rows) * u32Cols + (cellCoords.z % u32Depth) * layerSize;
}

fn calcActiveNeighbours(curCell: vec3u) -> u32
{
	var i: u32 = 0;
	var activeNeighboursAmount: u32 = 0;
	var neighbourCellIdx: u32 = 0;
	var neighbourhoodOffset: vec3i;
	let curCell_v3i = vec3i(curCell);
	let arrSize = arrayLength(&sNeighbourhoodOffsets);

	for (i = 0; i < arrSize; i += 3)
	{
		neighbourhoodOffset = vec3i(sNeighbourhoodOffsets[i], sNeighbourhoodOffsets[i + 1], sNeighbourhoodOffsets[i + 2]);
		neighbourCellIdx = getCellIdx(vec3u(curCell_v3i + neighbourhoodOffset));
		activeNeighboursAmount += cellStateIn[ neighbourCellIdx ];
	}

	return activeNeighboursAmount;
}

@compute
@workgroup_size(4, 4, 4)
fn compute_main (@builtin(global_invocation_id) invId: vec3u)
{
	let cellIdx = getCellIdx(invId);

	// Moore
	// let activeNeighboursAmount =
	// cellStateIn[ getCellIdx(invId.x - 1, invId.y, invId.z) ] +
	// cellStateIn[ getCellIdx(invId.x + 1, invId.y, invId.z) ] +
	// cellStateIn[ getCellIdx(invId.x, invId.y - 1, invId.z) ] +
	// cellStateIn[ getCellIdx(invId.x, invId.y + 1, invId.z) ] +
	// cellStateIn[ getCellIdx(invId.x - 1, invId.y - 1, invId.z) ] +
	// cellStateIn[ getCellIdx(invId.x + 1, invId.y - 1, invId.z) ] +
	// cellStateIn[ getCellIdx(invId.x - 1, invId.y + 1, invId.z) ] +
	// cellStateIn[ getCellIdx(invId.x + 1, invId.y + 1, invId.z) ] +

	// // Back
	// cellStateIn[ getCellIdx(invId.x, invId.y, invId.z - 1) ] +
	// cellStateIn[ getCellIdx(invId.x - 1, invId.y, invId.z - 1) ] +
	// cellStateIn[ getCellIdx(invId.x + 1, invId.y, invId.z - 1) ] +
	// cellStateIn[ getCellIdx(invId.x, invId.y - 1, invId.z - 1) ] +
	// cellStateIn[ getCellIdx(invId.x, invId.y + 1, invId.z - 1) ] +
	// cellStateIn[ getCellIdx(invId.x - 1, invId.y - 1, invId.z - 1) ] +
	// cellStateIn[ getCellIdx(invId.x + 1, invId.y - 1, invId.z - 1) ] +
	// cellStateIn[ getCellIdx(invId.x - 1, invId.y + 1, invId.z - 1) ] +
	// cellStateIn[ getCellIdx(invId.x + 1, invId.y + 1, invId.z - 1) ] +

	// // Front
	// cellStateIn[ getCellIdx(invId.x, invId.y, invId.z + 1) ] +
	// cellStateIn[ getCellIdx(invId.x - 1, invId.y, invId.z + 1) ] +
	// cellStateIn[ getCellIdx(invId.x + 1, invId.y, invId.z + 1) ] +
	// cellStateIn[ getCellIdx(invId.x, invId.y - 1, invId.z + 1) ] +
	// cellStateIn[ getCellIdx(invId.x, invId.y + 1, invId.z + 1) ] +
	// cellStateIn[ getCellIdx(invId.x - 1, invId.y - 1, invId.z + 1) ] +
	// cellStateIn[ getCellIdx(invId.x + 1, invId.y - 1, invId.z + 1) ] +
	// cellStateIn[ getCellIdx(invId.x - 1, invId.y + 1, invId.z + 1) ] +
	// cellStateIn[ getCellIdx(invId.x + 1, invId.y + 1, invId.z + 1) ];

	// Von Neiman
	// let activeNeighboursAmount =
	// cellStateIn[ getCellIdx(invId.x - 1, invId.y, invId.z) ] +
	// cellStateIn[ getCellIdx(invId.x + 1, invId.y, invId.z) ] +
	// cellStateIn[ getCellIdx(invId.x, invId.y - 1, invId.z) ] +
	// cellStateIn[ getCellIdx(invId.x, invId.y + 1, invId.z) ] +

	// // Back
	// cellStateIn[ getCellIdx(invId.x, invId.y, invId.z - 1) ] +

	// // Front
	// cellStateIn[ getCellIdx(invId.x, invId.y, invId.z + 1) ];

	let activeNeighboursAmount = calcActiveNeighbours(invId);

	// Conway's game of life rules:
	// if (cellStateIn[cellIdx] == 1 && (activeNeighboursAmount < 2 || activeNeighboursAmount > 3))
	// {
	// 	cellStateOut[cellIdx] = 0;
	// }
	// else if (cellStateIn[cellIdx] == 1 && (activeNeighboursAmount == 2 || activeNeighboursAmount == 3))
	// {
	// 	cellStateOut[cellIdx] = 1;
	// }
	// else if (cellStateIn[cellIdx] == 0 && activeNeighboursAmount == 3)
	// {
	// 	cellStateOut[cellIdx] = 1;
	// }
	// else {
	// 	cellStateOut[cellIdx] = cellStateIn[cellIdx];
	// }

	// 4/4/4/M
	// if (activeNeighboursAmount == 4)
	// {
	// 	cellStateOut[cellIdx] = 1;
	// }
	// else if (cellStateOut[cellIdx] == 1 && (activeNeighboursAmount < 4 || activeNeighboursAmount > 4))
	// {
	// 	cellStateOut[cellIdx] = 0;
	// }
	// else
	// {
	// 	cellStateOut[cellIdx] = cellStateIn[cellIdx];
	// }

	// 0-6/1,3/2/VN
	// if(cellStateIn[cellIdx] == 1 && activeNeighboursAmount <= 6)
	// {
	// 	// Survives.
	// 	cellStateOut[cellIdx] = 1;
	// }
	// else if (cellStateIn[cellIdx] == 0 && (activeNeighboursAmount == 1 || activeNeighboursAmount == 3))
	// {
	// 	// Born.
	// 	cellStateOut[cellIdx] = 1;
	// }
	// else if (cellStateIn[cellIdx] == 1)
	// {
	// 	// Dead.
	// 	cellStateOut[cellIdx] = 0;
	// }
	// else
	// {
	// 	// Carry on.
	// 	cellStateOut[cellIdx] = cellStateIn[cellIdx];
	// }

	// Preliminary carry over previous state.
	cellStateOut[cellIdx] = cellStateIn[cellIdx];

	// TODO: this should be possible to write as one-liner. Figure out how.
	if(cellStateIn[cellIdx] == 1 && sSurviveRules[activeNeighboursAmount] > 0)
	{
		// Survives.
		cellStateOut[cellIdx] = 1;
	}
	else if (cellStateIn[cellIdx] == 0 && sBornRules[activeNeighboursAmount] > 0)
	{
		// Born.
		cellStateOut[cellIdx] = 1;
	}
	else
	{
		// Dead.
		cellStateOut[cellIdx] = 0;
	}
}
