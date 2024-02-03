@group(0) @binding(0) var<uniform> colsRows: vec3f;

@group(1) @binding(0) var<storage> cellStateIn: array<u32>;
@group(1) @binding(1) var<storage, read_write> cellStateOut: array<u32>;


// fn getCellIdx (xIn: u32, yIn: u32) -> u32
// {
// 	var x = xIn;
// 	var y = yIn;
// 	let u32Cols = u32(colsRows.x);
// 	let u32Rows = u32(colsRows.y);

// 	// TODO: how to have this without if statements?
// 	if (x < 0)
// 	{
// 		x = u32Cols + x;
// 	}
// 	if (y < 0)
// 	{
// 		y = u32Rows + y;
// 	}
// 	return (x % u32Cols) + (y % u32Rows) * u32Cols;
// }

fn getCellIdx(xIn: u32, yIn: u32, zIn: u32) -> u32
{
	var x = xIn;
	var y = yIn;
	var z = zIn;
	let u32Cols = u32(colsRows.x);
	let u32Rows = u32(colsRows.y);
	let u32Depth = u32(colsRows.z);
	let layerSize = u32(colsRows.x * colsRows.y);

	// TODO: how to have this without if statements?
	if (x < 0)
	{
		x = u32Cols + x;
	}
	if (y < 0)
	{
		y = u32Rows + y;
	}
	if (z < 0)
	{
		z = u32Depth + z;
	}
	return (x % u32Cols) + (y % u32Rows) * u32Cols + (z % u32Depth) * layerSize;
}

@compute
@workgroup_size(4, 4, 4)
fn compute_main (@builtin(global_invocation_id) invId: vec3u)
{
	let cellIdx = getCellIdx(invId.x, invId.y, invId.z);

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
	let activeNeighboursAmount =
	cellStateIn[ getCellIdx(invId.x - 1, invId.y, invId.z) ] +
	cellStateIn[ getCellIdx(invId.x + 1, invId.y, invId.z) ] +
	cellStateIn[ getCellIdx(invId.x, invId.y - 1, invId.z) ] +
	cellStateIn[ getCellIdx(invId.x, invId.y + 1, invId.z) ] +

	// Back
	cellStateIn[ getCellIdx(invId.x, invId.y, invId.z - 1) ] +

	// Front
	cellStateIn[ getCellIdx(invId.x, invId.y, invId.z + 1) ];

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
