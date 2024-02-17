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

fn getClusterIdxFromInvId(invId: vec3u) -> u32
{
	// Dividing by 32u because we use u32 clusters (cells) in the array.
	let u32Cols = u32(uGridSize.x) / 32u;
	let u32Rows = u32(uGridSize.y);
	let u32Depth = u32(uGridSize.z);
	let layerSize = u32Cols * u32(uGridSize.y);

	// In case of power of 2 grid size having u32 cellCoorinates automatically takes care of overflow.
	// If the value casted to u32 was -1, it becomes max u32, being power of 2 itself it perfectly cycles with modulo.

	return (invId.x % u32Cols) + (invId.y % u32Rows) * u32Cols + (invId.z % u32Depth) * layerSize;
}

fn getCellState(cellCoords: vec3u) -> u32
{
	let clusterIdx = getClusterIdxFromGridCoordinates(cellCoords);
	let u32Storage: u32 = cellStateIn[clusterIdx];
	let x: u32 = cellCoords.x % 32u;

	return u32((u32Storage & masks[x]) > 0);
}

fn calcActiveNeighbours(cellCoords: vec3u) -> u32
{
	var i: u32 = 0;
	var activeNeighboursAmount: u32 = 0;
	var neighbourhoodOffset: vec3i;
	let cellCoords_v3i = vec3i(cellCoords);
	let arrSize = arrayLength(&sNeighbourhoodOffsets);

	for (i = 0; i < arrSize; i += 3)
	{
		neighbourhoodOffset = vec3i(sNeighbourhoodOffsets[i], sNeighbourhoodOffsets[i + 1], sNeighbourhoodOffsets[i + 2]);
		activeNeighboursAmount += getCellState(vec3u(cellCoords_v3i + neighbourhoodOffset));
	}

	return activeNeighboursAmount;
}

fn getNextCellState(currentCellState: u32, activeNeighboursAmount: u32) -> u32
{
	var newCellState: u32 = 0;

	// TODO: this should be possible to write as one-liner. Figure out how.
	if(currentCellState == 1 && sSurviveRules[activeNeighboursAmount] > 0)
	{
		// Survives.
		newCellState = 1;
	}
	else if (currentCellState == 0 && sBornRules[activeNeighboursAmount] > 0)
	{
		// Born.
		newCellState = 1;
	}
	else
	{
		// Dead.
		newCellState = 0;
	}

	return newCellState;
}

// fn setNewCellState(cellCoords: vec3u, newState: u32)
// {
// 	let clusterIdx = getClusterIdx(cellCoords);
// 	let newValue: u32 = newState << (cellCoords.x % 32u);

// 	// TODO: how to do it without if.
// 	if (newState > 0)
// 	{
// 		cellStateOut[clusterIdx] = cellStateIn[clusterIdx] | newValue;
// 	}
// 	else
// 	{
// 		cellStateOut[clusterIdx] = cellStateIn[clusterIdx] & ~newValue;
// 	}

// 	// cellStateOut[clusterIdx] = (cellStateIn[clusterIdx] & !newValue) | newValue;
// }

fn updateU32Cluster(invId: vec3u)
{
	let clusterIdx = getClusterIdxFromInvId(invId);
	var i: u32;
	var cellCoords = vec3u(0, invId.y, invId.z);
	var currentCellState: u32;
	var newCellState: u32;
	var newValue: u32;
	var neighbours: u32;
	var u32Cluster = cellStateIn[clusterIdx];
	let colOffset: u32 = invId.x * 32u;

	for (i = 0; i < 32; i++)
	{
		cellCoords.x = i + colOffset;
		currentCellState = getCellState(cellCoords);
		neighbours = calcActiveNeighbours(cellCoords);
		newCellState = getNextCellState(currentCellState, neighbours);

		newValue = newCellState << i;

		// TODO: how to do it without if?
		if (newCellState > 0)
		{
			u32Cluster = u32Cluster | newValue;
		}
		else
		{
			u32Cluster = u32Cluster & ~newValue;
		}
	}

	cellStateOut[clusterIdx] = u32Cluster;

	// var tc0 = getClusterIdxFromInvId(vec3u(0, 31, 31));
	// var tc1 = getClusterIdxFromInvId(vec3u(1, 31, 31));
	// // cellStateOut[tc] = 65535;
	// // cellStateOut[tc2] = 4294901760;
	// cellStateOut[tc0] = 1 << 31;
	// let cs = getCellState(vec3u(31, 31, 31));
	// if (cs > 0)
	// {
	// 	cellStateOut[0] = 4294901760;
	// }
	// if (cellStateIn[tc] > 0)
	// {
	// 	// let v = cellStateIn[tc];
	// 	let v = 65535u;
	// 	cellStateOut[tc] = v | (1 << 17);
	// }
}

@compute
@workgroup_size(1, 4, 4)
fn compute_main (@builtin(global_invocation_id) invId: vec3u)
{
	updateU32Cluster(invId);
}
