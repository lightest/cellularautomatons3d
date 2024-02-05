@group(0) @binding(0) var<uniform> uGridSize: vec3f;

@group(1) @binding(0) var<storage> cellStateIn: array<u32>;
@group(1) @binding(1) var<storage, read_write> cellStateOut: array<u32>;


const vnNeighbourhood = array<vec3i, 6>(vec3i(0, 0, 1), vec3i(0, 0, -1), vec3i(1, 0, 0), vec3i(-1, 0, 0), vec3i(0, 1, 0), vec3i(0, -1, 0));

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
	var i: i32 = 0;
	var activeNeighboursAmount: u32 = 0;
	var neighbourCellIdx: u32 = 0;
	// let arrSize = arrayLength(&cellStateIn);

	for (i = 0; i < 6; i++)
	{
		neighbourCellIdx = getCellIdx(vec3u(vec3i(curCell) + vnNeighbourhood[i]));
		activeNeighboursAmount = activeNeighboursAmount + cellStateIn[ neighbourCellIdx ];
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
	if(cellStateIn[cellIdx] == 1 && activeNeighboursAmount <= 6)
	{
		// Survives.
		cellStateOut[cellIdx] = 1;
	}
	else if (cellStateIn[cellIdx] == 0 && (activeNeighboursAmount == 1 || activeNeighboursAmount == 3))
	{
		// Born.
		cellStateOut[cellIdx] = 1;
	}
	else if (cellStateIn[cellIdx] == 1)
	{
		// Dead.
		cellStateOut[cellIdx] = 0;
	}
	else
	{
		// Carry on.
		cellStateOut[cellIdx] = cellStateIn[cellIdx];
	}
}
